//! Time a warm traffic record load and stress shared mappings with eight readers.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const live = routing.traffic.live;
const EdgeId = routing.graph.format.EdgeId;

const Probe = struct {
    edge: EdgeId,
    slot: live.Slot,
    variants: [2]live.Record,
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    const seconds = if (args.next()) |arg| try std.fmt.parseInt(u32, arg, 10) else 60;
    if (seconds == 0 or args.next() != null) return error.InvalidArguments;

    var bundle = try routing.graph.reader.Bundle.open(path);
    defer bundle.close();
    const parent = try io.Directory.open(".");
    defer parent.close();
    const temp = try parent.temporaryChild();
    defer {
        temp.dir.deleteFile(live.filename) catch {};
        temp.dir.close();
        parent.deleteDir(&temp.name) catch {};
    }
    const graph = try bundle.view.liveTrafficGraph();
    const prepare = io.Deadline.fromNowMs(30_000);
    var writer = try live.Writer.create(temp.dir, graph, prepare);
    defer writer.close();
    const reader = (try live.Reader.open(temp.dir, graph.uuid, graph.edges.len, prepare)).?;
    defer reader.close();
    if (reader.mapping.bytes.ptr == writer.mapping.bytes.ptr) return error.ExpectedSeparateMappings;

    var storage: [2048]Probe = undefined;
    var n: usize = 0;
    for (graph.edges, 0..) |_, i| {
        if (i % 1024 == 0 and prepare.expired()) return error.DeadlineExceeded;
        const edge: EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
        const slot = reader.view.slot(edge) orelse continue;
        const encoded: u7 = @intCast(1 + i % 125);
        storage[n] = .{
            .edge = edge,
            .slot = slot,
            .variants = .{
                .{ .overall = encoded, .speed1 = encoded, .breakpoint1 = 255, .congestion1 = 1, .has_incidents = true },
                .{ .overall = 127 - encoded, .speed1 = 0, .speed2 = encoded, .speed3 = 2, .breakpoint1 = 53, .breakpoint2 = 179, .congestion1 = 63, .congestion2 = 16, .congestion3 = 42 },
            },
        };
        n += 1;
        if (n == storage.len) break;
    }
    if (n == 0) return error.NoDrivableEdges;
    const probes = storage[0..n];
    var rng = std.Random.DefaultPrng.init(197);
    rng.random().shuffle(Probe, probes);

    const timestamp: u64 = @intCast(io.wallSeconds());
    var updates: [2][2048]live.Update = undefined;
    for (probes, updates[0][0..n], 0..) |probe, *entry, i| {
        const next = @backingInt(probes[(i + 1) % n].slot);
        if (next > 4095) return error.TrafficProbeOutOfRange;
        var record = probe.variants[0];
        record.congestion2 = @truncate(next);
        record.congestion3 = @truncate(next >> 6);
        entry.* = .{ .edge = probe.edge, .record = record };
    }
    const warm_epoch = try writer.update(updates[0][0..n], timestamp, prepare);
    const slot_ns = try timeSlotReads(reader.view, probes[0].slot);
    const edge_ns = try timeEdgeReads(reader.view, probes);

    for (&updates, 0..) |*batch, phase| {
        for (probes, batch[0..n]) |probe, *entry| entry.* = .{ .edge = probe.edge, .record = probe.variants[phase] };
    }
    const initial_epoch = try writer.update(updates[0][0..n], timestamp, prepare);
    if (initial_epoch.epoch != warm_epoch.epoch + 1) return error.TrafficEpochMismatch;

    var buffer: [1024]u8 = undefined;
    var output = io.stdoutWriter(init.io, &buffer);
    try output.interface.print("warm_samples {d}\nslot_latency_ns {d:.3}\nedge_batch_ns_per_read {d:.3}\n", .{ n, slot_ns, edge_ns });
    try output.interface.flush();
    if (slot_ns >= 5 or edge_ns >= 5) return error.LiveTrafficReadBudgetExceeded;

    // Exercise rapid overlapping writes on the same addresses in both maps.
    // Small batches keep the writer publishing while all eight threads read.
    const batch_size = @min(64, n);
    const result = try stress(&writer, reader.view, probes[0..batch_size], .{ updates[0][0..batch_size], updates[1][0..batch_size] }, initial_epoch, seconds);
    try output.interface.print("reader_threads 8\nstress_seconds {d:.3}\nreader_loads {d}\nwriter_batches {d}\nfinal_epoch {d}\ntorn_reads 0\n", .{
        @as(f64, @floatFromInt(result.elapsed_ns)) / std.time.ns_per_s, result.reads, result.batches, result.epoch,
    });
    try output.interface.flush();
}

fn timeSlotReads(view: live.View, start: live.Slot) !f64 {
    const iterations = 500_000;
    var measurements: [11]u64 = undefined;
    for (&measurements) |*measurement| {
        var next = start;
        const stopwatch = io.Timer.start();
        for (0..iterations) |_| {
            // The two adjacent congestion fields carry the next slot.
            // Each dependent step loads only the traffic word.
            const record = view.load(next) orelse return error.MissingTrafficRecord;
            next = @fromBackingInt(@as(u32, record.congestion2) | (@as(u32, record.congestion3) << 6));
        }
        std.mem.doNotOptimizeAway(next);
        measurement.* = stopwatch.read();
    }
    std.mem.sort(u64, &measurements, {}, comptime std.sort.asc(u64));
    return @as(f64, @floatFromInt(measurements[measurements.len / 2])) / iterations;
}

fn timeEdgeReads(view: live.View, probes: []const Probe) !f64 {
    const repeats = std.math.divCeil(usize, 500_000, probes.len) catch unreachable;
    var measurements: [11]u64 = undefined;
    for (&measurements) |*measurement| {
        const stopwatch = io.Timer.start();
        for (0..repeats) |_| {
            for (probes) |probe| {
                const record = view.record(probe.edge) orelse return error.MissingTrafficRecord;
                std.mem.doNotOptimizeAway(@as(u64, @bitCast(record)));
            }
        }
        measurement.* = stopwatch.read();
    }
    std.mem.sort(u64, &measurements, {}, comptime std.sort.asc(u64));
    return @as(f64, @floatFromInt(measurements[measurements.len / 2])) / @as(f64, @floatFromInt(repeats * probes.len));
}

const ReadState = struct {
    stop: std.atomic.Value(bool) = .init(false),
    torn: std.atomic.Value(bool) = .init(false),
};

const StressResult = struct { elapsed_ns: u64, reads: u64, batches: u64, epoch: u64 };

fn stress(writer: *live.Writer, view: live.View, probes: []const Probe, updates: [2][]const live.Update, initial: live.Metadata, seconds: u32) !StressResult {
    var state: ReadState = .{};
    var threads: [8]std.Thread = undefined;
    var reads: [8]u64 = @splat(0);
    var spawned: usize = 0;
    errdefer {
        state.stop.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads, &reads, 0..) |*thread, *count, i| {
        thread.* = try std.Thread.spawn(.{}, readRepeatedly, .{ view, probes, &state, count, i });
        spawned += 1;
    }

    const stopwatch = io.Timer.start();
    const deadline = io.Deadline.fromNow(@as(u64, seconds) * std.time.ns_per_s);
    var batches: u64 = 0;
    while (!deadline.expired() and !state.torn.load(.acquire)) : (batches += 1)
        _ = try writer.update(updates[@intCast((batches + 1) & 1)], initial.last_update, .none);

    state.stop.store(true, .release);
    for (threads) |thread| thread.join();
    spawned = 0;
    if (state.torn.load(.acquire)) return error.TornTrafficRecord;
    var reader_loads: u64 = 0;
    for (reads) |count| {
        if (count == 0) return error.IdleReader;
        reader_loads += count;
    }
    const metadata = view.metadata() orelse return error.UnpublishedTrafficMetadata;
    if (metadata.epoch != batches + initial.epoch) return error.TrafficEpochMismatch;
    return .{ .elapsed_ns = stopwatch.read(), .reads = reader_loads, .batches = batches, .epoch = metadata.epoch };
}

fn readRepeatedly(view: live.View, probes: []const Probe, state: *ReadState, count: *u64, start: usize) void {
    var offset = start % probes.len;
    while (!state.stop.load(.acquire)) {
        for (0..1024) |_| {
            const probe = probes[offset];
            const record = view.record(probe.edge) orelse {
                state.torn.store(true, .release);
                return;
            };
            const word: u64 = @bitCast(record);
            if (word != @as(u64, @bitCast(probe.variants[0])) and word != @as(u64, @bitCast(probe.variants[1]))) {
                state.torn.store(true, .release);
                return;
            }
            offset += 1;
            if (offset == probes.len) offset = 0;
        }
        count.* += 1024;
    }
}
