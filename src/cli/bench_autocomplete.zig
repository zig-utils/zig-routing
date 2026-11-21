//! Closed-loop keystroke load on one shared regional geocoder.
const std = @import("std");
const perf = @import("perf_counters");
const io = @import("../infra/io.zig");
const arena_mod = @import("../infra/arena.zig");
const autocomplete = @import("../geocode/autocomplete.zig");
const bundle = @import("../geocode/bundle.zig");
const model = @import("../geocode/model.zig");
const query = @import("../geocode/query.zig");
const bench = @import("bench.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    threads: usize = 8,
    duration_ns: u64 = 10 * std.time.ns_per_s,
    warmup_ns: u64 = 2 * std.time.ns_per_s,
    timeout_ns: u64 = std.time.ns_per_s,
    requests: ?u64 = null,
    measure_counters: bool = false,
    dataset: []const u8 = "",
    commit: []const u8 = "",
    label: []const u8 = "",
};

const Stroke = struct {
    request: autocomplete.Request,
    short_width: u2,
};

const Shared = struct {
    ready: std.atomic.Value(u32) = .init(0),
    run: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    start: u64 = 0,
};

const Worker = struct {
    shared: *Shared,
    engine: *const autocomplete.Engine,
    strokes: []const Stroke,
    options: Options,
    ordinal: usize,
    all: bench.Histogram = .{},
    short: [2]bench.Histogram = @splat(.{}),
    end: u64 = 0,
    heap_calls: usize = 0,
    counters: ?perf.Counts = null,
    failure: ?anyerror = null,

    fn run(self: *Worker) void {
        self.runWorker() catch |err| {
            self.failure = err;
            self.shared.cancelled.store(true, .release);
        };
    }

    fn runWorker(self: *Worker) !void {
        var backing = arena_mod.CountingAllocator.init(std.heap.page_allocator);
        var arena = arena_mod.Arena.init(backing.allocator(), .{ .cap_bytes = 8 * 1024 * 1024 });
        defer arena.deinit();
        var cursor = (self.ordinal * 811) % self.strokes.len;
        {
            defer {
                _ = self.shared.ready.fetchAdd(1, .release);
                io.wakeAtomic(&self.shared.ready);
            }
            const warm_until = io.Deadline.fromNow(self.options.warmup_ns);
            var seen: usize = 0;
            while (seen < self.strokes.len or !warm_until.expired()) : (seen += 1) {
                if (self.shared.cancelled.load(.acquire)) return;
                try self.lookup(&arena, self.strokes[cursor], io.monotonicNs());
                cursor = (cursor + 1) % self.strokes.len;
            }
        }
        backing.resetCounts();
        while (self.shared.run.load(.acquire) == 0) io.waitAtomic(&self.shared.run, 0, .none);
        const cap = if (self.options.requests) |total|
            total / self.options.threads + @intFromBool(self.ordinal < total % self.options.threads)
        else
            std.math.maxInt(u64);
        const end = self.shared.start +| self.options.duration_ns;
        var counters = if (self.options.measure_counters and cap != 0) perf.Counters.start() else null;
        defer if (counters) |*active| {
            self.counters = active.finish();
        };
        while (self.all.total < cap and !self.shared.cancelled.load(.acquire)) {
            const start = io.monotonicNs();
            if (start >= end) break;
            const stroke = self.strokes[cursor];
            try self.lookup(&arena, stroke, start);
            const elapsed = io.monotonicNs() - start;
            self.all.record(elapsed);
            if (stroke.short_width != 0) self.short[stroke.short_width - 1].record(elapsed);
            cursor = (cursor + 1) % self.strokes.len;
        }
        self.end = io.monotonicNs();
        self.heap_calls = backing.calls();
    }

    fn lookup(self: *const Worker, arena: *arena_mod.Arena, stroke: Stroke, start: u64) !void {
        arena.reset();
        const found = self.engine.suggest(arena.allocator(), stroke.request, .{ .at_ns = start +| self.options.timeout_ns }) catch |err| {
            try arena.check();
            return err;
        };
        std.mem.doNotOptimizeAway(found);
    }
};

const Workload = struct {
    queries: usize = 0,
    strokes: std.ArrayList(Stroke) = .empty,
};

pub fn run(a: Allocator, path: []const u8, corpus_path: ?[]const u8, opts: Options, out: ?[]const u8) !void {
    if (opts.threads == 0 or opts.threads > 64 or opts.duration_ns == 0 or opts.timeout_ns == 0 or opts.requests == 0)
        return error.InvalidAutocompleteBenchmarkOptions;
    const startup = io.Timer.start();
    var engine = try autocomplete.Engine.open(std.heap.page_allocator, path, .none);
    defer engine.close();
    const startup_ns = startup.read();
    const corpus: io.Mapping = if (corpus_path) |file| try io.Mapping.mapFile(file, .read_only) else .{ .bytes = &.{} };
    defer corpus.unmap();
    var workload: Workload = .{};
    if (corpus_path != null) {
        var lines = std.mem.splitScalar(u8, corpus.bytes, '\n');
        while (lines.next()) |line| try addQuery(a, &workload, std.mem.trim(u8, line, " \t\r"), .{});
    } else try sample(a, engine.search.bundle.data, &workload);
    if (workload.strokes.items.len == 0) return error.EmptyAutocompleteCorpus;

    var shared: Shared = .{};
    const workers = try a.alloc(Worker, opts.threads);
    const threads = try a.alloc(std.Thread, opts.threads);
    var active: usize = 0;
    errdefer {
        shared.cancelled.store(true, .release);
        shared.run.store(1, .release);
        io.wakeAtomic(&shared.run);
        for (threads[0..active]) |thread| thread.join();
    }
    for (workers, threads, 0..) |*worker, *thread, i| {
        worker.* = .{ .shared = &shared, .engine = &engine, .strokes = workload.strokes.items, .options = opts, .ordinal = i };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
        active += 1;
    }
    var ready = shared.ready.load(.acquire);
    while (ready != opts.threads) {
        io.waitAtomic(&shared.ready, ready, .none);
        ready = shared.ready.load(.acquire);
    }
    shared.start = io.monotonicNs();
    shared.run.store(1, .release);
    io.wakeAtomic(&shared.run);
    for (threads) |thread| thread.join();
    active = 0;

    var all: bench.Histogram = .{};
    var short_by_width: [2]bench.Histogram = @splat(.{});
    var end = shared.start;
    var heap_calls: usize = 0;
    var counters: ?perf.Counts = if (opts.measure_counters) .{} else null;
    for (workers) |*worker| {
        if (worker.failure) |err| return err;
        all.merge(&worker.all);
        for (&short_by_width, &worker.short) |*width, *part| width.merge(part);
        end = @max(end, worker.end);
        heap_calls += worker.heap_calls;
        if (worker.all.total != 0) if (counters) |*combined| {
            if (worker.counters) |counts| combined.add(counts) else counters = null;
        };
    }
    if (all.total == 0 or end == shared.start) return error.EmptyAutocompleteMeasurement;
    var short = short_by_width[0];
    short.merge(&short_by_width[1]);
    const elapsed = end - shared.start;
    var cpu: [128]u8 = undefined;
    const result = try std.json.Stringify.valueAlloc(a, .{
        .mode = "autocomplete",
        .cpu = bench.cpuModel(&cpu),
        .dataset = opts.dataset,
        .commit = opts.commit,
        .label = opts.label,
        .dataset_uuid = engine.search.bundle.uuid,
        .threads = opts.threads,
        .source_queries = workload.queries,
        .keystrokes = workload.strokes.items.len,
        .startup_ns = startup_ns,
        .elapsed_ns = elapsed,
        .requests = all.total,
        .requests_per_second = @as(f64, @floatFromInt(all.total)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed)),
        .p50_ns = all.percentile(50),
        .p99_ns = all.percentile(99),
        .short_requests = short.total,
        .short_p50_ns = short.percentile(50),
        .short_p99_ns = short.percentile(99),
        .one_character_requests = short_by_width[0].total,
        .one_character_p99_ns = short_by_width[0].percentile(99),
        .two_character_requests = short_by_width[1].total,
        .two_character_p99_ns = short_by_width[1].percentile(99),
        .steady_state_heap_calls = heap_calls,
        .hardware_counters = counters,
        .counters_per_request = if (counters) |counts| counts.perUnit(all.total) else null,
    }, .{ .whitespace = .indent_2 });
    if (out) |result_path| try io.writeFile(result_path, result);
    try io.writeStdout(result);
    try io.writeStdout("\n");
    if (heap_calls != 0) return error.AutocompleteAllocatedAfterWarmup;
}

fn addQuery(a: Allocator, workload: *Workload, text: []const u8, filters: query.Filters) !void {
    if (text.len == 0) return;
    if (text.len > query.max_input_bytes) return error.GeocodeQueryTooLong;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var end: usize = 0;
    var count: usize = 0;
    while (end < text.len) {
        end += try std.unicode.utf8ByteSequenceLength(text[end]);
        count += 1;
        try workload.strokes.append(a, .{
            .request = .{ .text = text[0..end], .filters = filters },
            .short_width = if (count <= 2) @intCast(count) else 0,
        });
    }
    workload.queries += 1;
}

fn sample(a: Allocator, data: bundle.Data, workload: *Workload) !void {
    var rng = std.Random.DefaultPrng.init(223);
    const random = rng.random();
    inline for (.{ data.places, data.streets, data.addresses, data.pois }) |items| {
        var selected: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer selected.deinit(a);
        const stop = workload.queries + 48;
        for (0..items.len * 2) |_| {
            const row = random.uintLessThan(usize, items.len);
            if (selected.contains(row)) continue;
            try selected.put(a, row, {});
            const record = items[row].record;
            const text = if (@TypeOf(items[row]) == model.Address) sampleAddress(a, data, items[row]) else sampleName(data, record.names);
            const value = try text;
            if (value.len < 3 or value.len > 160) continue;
            const near = if (workload.queries % 4 == 0) record.coordinate.toPoint() else null;
            try addQuery(a, workload, value, .{ .near = near });
            if (workload.queries == stop) break;
        }
    }
    random.shuffle(Stroke, workload.strokes.items);
}

fn sampleName(data: bundle.Data, span: model.Span) ![]const u8 {
    const names = try span.get(data.names);
    for (names) |name| if (name.language.len == 0) return name.text.get(data.text);
    return if (names.len == 0) "" else names[0].text.get(data.text);
}

fn sampleAddress(a: Allocator, data: bundle.Data, record: model.Address) ![]const u8 {
    const number = try record.number.get(data.text);
    const street = try record.street.get(data.text);
    const admin = try data.admin(record.record.hierarchy.city) orelse return "";
    const city = try sampleName(data, admin.names);
    if (number.len == 0 or street.len == 0 or city.len == 0) return "";
    return std.mem.join(a, " ", &.{ number, street, city });
}
