//! Batch map matching and time attribution before historical aggregation.
const std = @import("std");
const request = @import("../api/request.zig");
const costing = @import("../costing/root.zig");
const graph = @import("../graph/root.zig");
const Arena = @import("../infra/arena.zig").Arena;
const Deadline = @import("../infra/io.zig").Deadline;
const match = @import("../match/root.zig");
const Motor = @import("../match/kernel.zig").Motor;
const search = @import("../search/search.zig");
const Recost = @import("../search/legs.zig").Recost;
const endpoints = @import("../search/endpoints.zig");
const codec = @import("predicted_codec.zig");
const history = @import("history.zig");

const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;
const Kernel = Motor(costing.auto);
const Router = match.routing.Router(Kernel);

pub const Report = struct {
    traces: u64 = 0,
    points: u64 = 0,
    malformed_traces: u64 = 0,
    unmatched_traces: u64 = 0,
    contributing_traces: u64 = 0,
    samples: u64 = 0,
};

pub const Batch = struct {
    samples: []history.Sample,
    report: Report,

    pub fn deinit(self: Batch, a: Allocator) void {
        a.free(self.samples);
    }
};

const TimeSpan = struct {
    start: f64,
    end: f64,
};

const Position = struct {
    segment: usize,
    weight: f64,
    epoch: f64,
};

const Key = struct {
    edge: EdgeId,
    bucket: u11,
};

const Totals = struct {
    distance: f64 = 0,
    seconds: f64 = 0,
};

const TraceSamples = std.AutoHashMapUnmanaged(Key, Totals);

fn addAcrossBuckets(view: *const View, edge: EdgeId, span: TimeSpan, speed_mps: f64, a: Allocator, samples: *TraceSamples, control: search.Control) !void {
    const hot = try view.edge(edge);
    const zone = try view.nodeTimezone(@fromBackingInt(hot.head));
    var start = span.start;
    while (start < span.end) {
        try control.check();
        const epoch: i64 = @intFromFloat(@floor(start));
        const offset = if (view.tz_rules) |rules|
            if (try rules.offsetAt(zone, epoch)) |entry| entry.seconds else 0
        else
            0;
        const local = graph.datetime.secondOfWeek(epoch, offset);
        const slot: u11 = @intCast(local / codec.bucket_seconds);
        const next: f64 = @floatFromInt(epoch + codec.bucket_seconds - local % codec.bucket_seconds);
        const end = @min(span.end, next);
        const elapsed = end - start;
        const stored = try samples.getOrPut(a, .{ .edge = edge, .bucket = slot });
        if (!stored.found_existing) stored.value_ptr.* = .{};
        stored.value_ptr.distance += elapsed * speed_mps;
        stored.value_ptr.seconds += elapsed;
        start = end;
    }
}

fn attributePair(view: *const View, edges: []const endpoints.Segment, spans: []const TimeSpan, steps: []const Recost.Step, first: Position, next: Position, offset: usize, total_edges: usize, a: Allocator, samples: *TraceSamples, control: search.Control) !void {
    const seconds_per_weight = (next.epoch - first.epoch) / (next.weight - first.weight);
    for (first.segment..next.segment + 1) |index| {
        try control.check();
        // Keep only interior segments. Compute their times against the full
        // matched leg so removing the boundary edges does not shift clocks.
        if (offset + index == 0 or offset + index + 1 == total_edges) continue;
        const weight = spans[index];
        const begin = @max(weight.start, first.weight);
        const end = @min(weight.end, next.weight);
        if (end <= begin or steps[index].length_m <= 0) continue;
        const metres_per_weight = @as(f64, steps[index].length_m) / (weight.end - weight.start);
        const speed_mps = metres_per_weight / seconds_per_weight;
        const kph = speed_mps * 3.6;
        if (!(kph >= 1 and kph <= graph.constants.max_assumed_speed)) continue;
        try addAcrossBuckets(view, edges[index].edge, .{
            .start = first.epoch + (begin - first.weight) * seconds_per_weight,
            .end = first.epoch + (end - first.weight) * seconds_per_weight,
        }, speed_mps, a, samples, control);
    }
}

/// Distribute the observed time between successive matched points using
/// recosted travel times as weights. No raw point leaves the request arena.
fn attribute(view: *const View, found: match.route.Result, a: Allocator, out: *std.ArrayList(history.Sample), output: Allocator, control: search.Control) !usize {
    if (found.segments.len < 3) return 0;
    const indices = try match.route.segmentIndices(a, found, control);
    var samples: TraceSamples = .empty;
    var spans: std.ArrayList(TimeSpan) = .empty;
    var offset: usize = 0;
    for (found.legs) |leg| {
        try control.check();
        if (leg.first_match >= leg.last_match or leg.last_match >= found.matches.len or leg.steps.len != leg.segments.len or
            leg.steps.len > found.segments.len - offset) return error.InvalidTracePath;
        try spans.resize(a, leg.steps.len);
        var weight: f64 = 0;
        for (leg.segments, leg.steps, spans.items) |segment, step, *span| {
            try control.check();
            const duration = @as(f64, step.full_travel_secs) * (@as(f64, segment.end) - segment.begin);
            span.* = .{ .start = weight, .end = weight + duration };
            weight += duration;
        }
        var previous: ?Position = null;
        for (leg.first_match..@as(usize, leg.last_match) + 1) |i| {
            try control.check();
            const index = indices[i];
            if (index < offset or index >= offset + leg.segments.len) continue;
            const segment = index - offset;
            const m = found.matches[i];
            const cut = leg.segments[segment];
            const fraction = std.math.clamp(m.fraction, cut.begin, cut.end);
            const distance = @as(f64, fraction) - cut.begin;
            const position: Position = .{
                .segment = segment,
                .weight = spans.items[segment].start + distance * leg.steps[segment].full_travel_secs,
                .epoch = m.epoch_time,
            };
            if (previous) |prior| {
                if (position.segment < prior.segment or position.weight < prior.weight) continue;
                if (position.weight > prior.weight and position.epoch > prior.epoch)
                    try attributePair(view, leg.segments, spans.items, leg.steps, prior, position, offset, found.segments.len, a, &samples, control);
            }
            previous = position;
        }
        offset += leg.segments.len;
    }
    var iterator = samples.iterator();
    const start = out.items.len;
    while (iterator.next()) |entry| {
        try control.check();
        const counted = entry.value_ptr.*;
        try out.append(output, .{
            .edge = entry.key_ptr.edge,
            .bucket = entry.key_ptr.bucket,
            .kph = @floatCast(std.math.clamp(counted.distance / counted.seconds * 3.6, 1, graph.constants.max_assumed_speed)),
        });
    }
    return out.items.len - start;
}

fn readTrace(a: Allocator, row: []const u8, control: search.Control) ![]const match.candidates.Measurement {
    const parsed = try request.parseHttpWithin(a, "/trace_attributes", &.{}, row, false, control.deadline);
    if (parsed != .ok or parsed.ok.shape.len < 2 or parsed.ok.shape.len > 16_000) return error.InvalidHistoricalTrace;
    const points = try a.alloc(match.candidates.Measurement, parsed.ok.shape.len);
    var last: f64 = -1;
    for (parsed.ok.shape, points, 0..) |location, *out, index| {
        if (index % 256 == 0) try control.check();
        if (!(location.time > last and location.time >= 0 and location.time < 253_402_300_800)) return error.InvalidHistoricalTrace;
        out.* = .{
            .point = .init(location.lng, location.lat),
            .epoch_time = location.time,
            .stop_type = location.type,
            .gps_accuracy = if (location.accuracy) |v| @floatFromInt(v) else 5,
            .search_radius = if (location.radius) |v| @floatFromInt(v) else 50,
        };
        last = location.time;
    }
    return points;
}

const Job = struct {
    a: Allocator,
    view: *const View,
    raw: []const u8,
    profile: *const costing.auto.Profile,
    tables: *const costing.compiled.Compiled,
    untimed_edges: ?[]const Kernel.UntimedEdge,
    control: search.Control,
    samples: std.ArrayList(history.Sample) = .empty,
    report: Report = .{},
    failure: ?anyerror = null,

    fn run(self: *Job) void {
        self.collect() catch |err| {
            self.failure = err;
        };
    }

    fn collect(self: *Job) !void {
        if (self.raw.len == 0) return;
        var arena = Arena.init(self.a, .{});
        defer arena.deinit();
        var finder = match.candidates.Finder.init(self.view, self.a, .{});
        defer finder.deinit();
        var router = try Router.init(self.a, self.view, Router.default_scratch_bytes);
        defer router.deinit();
        const kernel: Kernel = .{
            .profile = self.profile,
            .tables = self.tables,
            .arena = arena.allocator(),
            .control = self.control,
            .untimed_edges = self.untimed_edges,
        };
        const observations = try match.emission.Model.init(match.emission.Model.default_sigma_z);
        const movements = try match.transition.Model.init(.{ .turn_penalty_factor = 0 });
        var rows = std.mem.tokenizeScalar(u8, self.raw, '\n');
        while (rows.next()) |row| {
            try self.control.check();
            const line = std.mem.trim(u8, row, " \r\t");
            if (line.len == 0) continue;
            self.report.traces += 1;
            arena.reset();
            const points = readTrace(arena.allocator(), line, self.control) catch |err| switch (err) {
                error.InvalidHistoricalTrace => {
                    self.report.malformed_traces += 1;
                    continue;
                },
                else => return err,
            };
            self.report.points += points.len;
            const result = match.route.resolve(&arena, &finder, &router, kernel, points, observations, movements, .{}, self.control) catch |err| switch (err) {
                error.InvalidMeasurement, error.NoEdgeWalk, error.DisconnectedPath, error.InvalidTracePath, error.TransitionMemoryLimit => {
                    self.report.unmatched_traces += 1;
                    continue;
                },
                else => return err,
            };
            if (result.len == 0 or result[0].segments.len == 0) {
                self.report.unmatched_traces += 1;
                continue;
            }
            const count = attribute(self.view, result[0], arena.allocator(), &self.samples, self.a, self.control) catch |err| switch (err) {
                error.InvalidTracePath => {
                    self.report.unmatched_traces += 1;
                    continue;
                },
                else => return err,
            };
            if (count != 0) self.report.contributing_traces += 1;
            self.report.samples += count;
        }
    }
};

/// Process newline-delimited traces in parallel. The file contains no
/// persistent working data and the result contains only anonymous samples.
pub fn collect(a: Allocator, view: *const View, raw: []const u8, workers: usize, deadline: Deadline) !Batch {
    if (workers == 0) return error.InvalidHistoricalWorkers;
    const classes = view.classes orelse return error.MissingClassTable;
    const factors = try a.alloc(f32, classes.len);
    defer a.free(factors);
    var warnings: std.ArrayList(costing.base.Warning) = .empty;
    defer warnings.deinit(a);
    const profile = try costing.auto.Model.canonicalize(try costing.auto.parse(a, .auto, .null, &warnings, deadline));
    const tables = try costing.compiled.compileInto(costing.auto.Model, profile, classes, factors, deadline);
    const price_bytes = view.edges.len * @sizeOf(Kernel.UntimedEdge);
    // Amortize a bounded shared table over a batch that is large enough to
    // revisit graph edges. A large graph can still use compiled class costs.
    const prices = if (price_bytes <= @min(raw.len, 4 * 1024 * 1024))
        try (Kernel{ .profile = &profile, .tables = &tables, .arena = a, .control = .{ .deadline = deadline } })
            .prepareUntimed(a, view, .{ .deadline = deadline })
    else
        null;
    defer if (prices) |entries| a.free(entries);
    const count = @min(workers, @max(1, raw.len));
    const jobs = try a.alloc(Job, count);
    defer a.free(jobs);
    var jobs_initialized: usize = 0;
    defer for (jobs[0..jobs_initialized]) |*job| job.samples.deinit(a);
    const threads = try a.alloc(std.Thread, count - 1);
    defer a.free(threads);
    var spawned: usize = 0;
    var cancel: std.atomic.Value(bool) = .init(false);
    errdefer {
        cancel.store(true, .monotonic);
        for (threads[0..spawned]) |thread| thread.join();
    }
    const control: search.Control = .{ .deadline = deadline, .cancel = &cancel };
    var begin: usize = 0;
    for (jobs, 0..) |*job, i| {
        try control.check();
        var end = if (i + 1 == jobs.len) raw.len else @max(begin, raw.len / count * (i + 1));
        while (end < raw.len and end > 0 and raw[end - 1] != '\n') : (end += 1) {
            if (end % 256 == 0) try control.check();
        }
        job.* = .{
            .a = a,
            .view = view,
            .raw = raw[begin..end],
            .profile = &profile,
            .tables = &tables,
            .untimed_edges = prices,
            .control = control,
        };
        jobs_initialized += 1;
        begin = end;
        if (i < threads.len) {
            threads[i] = try std.Thread.spawn(.{}, Job.run, .{job});
            spawned += 1;
        } else {
            job.run();
        }
    }

    for (threads) |thread| thread.join();
    spawned = 0;
    var report: Report = .{};
    for (jobs) |job| {
        try control.check();
        if (job.failure) |err| return err;
        inline for (comptime std.meta.fieldNames(Report)) |name| {
            @field(report, name) += @field(job.report, name);
        }
    }
    const combined = try a.alloc(history.Sample, std.math.cast(usize, report.samples) orelse return error.HistoricalBatchTooLarge);
    var written: usize = 0;
    for (jobs) |job| {
        @memcpy(combined[written..][0..job.samples.items.len], job.samples.items);
        written += job.samples.items.len;
    }
    return .{ .samples = combined, .report = report };
}
