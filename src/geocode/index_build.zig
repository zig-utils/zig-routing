//! Parallel analyzer runs with in-memory merging into an atomic index file.
const std = @import("std");
const io = @import("../infra/io.zig");
const bundle = @import("bundle.zig");
const model = @import("model.zig");
const format = @import("index_model.zig");
const analysis = @import("analyze.zig");
const postal = @import("postcode.zig");
const posting = @import("index_postings.zig");
const index_writer = @import("index_writer.zig");
const Allocator = std.mem.Allocator;

pub const Report = struct {
    terms: u64,
    postings: u64,
    analyzed_bytes: u64,
    index_bytes: u64,
    dictionary_bytes: u64,
    postings_bytes: u64,
    workers: usize,
};

pub fn counts(data: bundle.Data) !format.RecordCounts {
    const result: format.RecordCounts = .{
        .place = std.math.cast(u32, data.places.len) orelse return error.GeocodeIndexTooLarge,
        .street = std.math.cast(u32, data.streets.len) orelse return error.GeocodeIndexTooLarge,
        .address = std.math.cast(u32, data.addresses.len) orelse return error.GeocodeIndexTooLarge,
        .poi = std.math.cast(u32, data.pois.len) orelse return error.GeocodeIndexTooLarge,
    };
    if (result.total() > std.math.maxInt(u32)) return error.GeocodeIndexTooLarge;
    return result;
}

pub fn build(a: Allocator, path: []const u8, requested: usize, deadline: io.Deadline) !Report {
    const dir = try io.Directory.open(path);
    defer dir.close();
    var source = try bundle.Bundle.openInDir(dir, deadline);
    defer source.close();
    const records = try counts(source.data);
    const size: usize = @intCast(records.total());
    const preferred = if (requested != 0) requested else std.Thread.getCpuCount() catch 1;
    const worker_count = @max(1, @min(preferred, size));
    const workers = try a.alloc(Worker, worker_count);
    defer a.free(workers);
    var cancel = std.atomic.Value(bool).init(false);
    for (workers, 0..) |*worker, i| {
        worker.* = .{
            .owned = .init(std.heap.page_allocator),
            .data = source.data,
            .records = records,
            .first = @intCast(partition(size, i, worker_count)),
            .end = @intCast(partition(size, i + 1, worker_count)),
            .deadline = deadline,
            .cancel = &cancel,
        };
    }
    defer for (workers) |*worker| worker.owned.deinit();
    const threads = try a.alloc(std.Thread, worker_count - 1);
    defer a.free(threads);
    {
        var active: usize = 0;
        defer for (threads[0..active]) |thread| thread.join();
        errdefer cancel.store(true, .release);
        for (workers[1..], threads) |*worker, *thread| {
            if (deadline.expired()) return error.DeadlineExceeded;
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
            active += 1;
        }
        workers[0].run();
    }
    var analyzed: u64 = 0;
    for (workers) |worker| {
        if (worker.failure) |err| return err;
        analyzed = std.math.add(u64, analyzed, worker.analyzed) catch return error.GeocodeIndexTooLarge;
    }
    const staged = try dir.temporaryFile();
    defer staged.file.close();
    errdefer dir.deleteFile(&staged.name) catch {};
    var writer: index_writer.Writer = .{ .a = a, .file = staged.file, .uuid = source.uuid, .records = records, .deadline = deadline };
    defer writer.deinit();
    try merge(a, workers, &writer, deadline);
    const header = try writer.finish(analyzed);
    if (deadline.expired()) return error.DeadlineExceeded;
    try dir.replaceFile(&staged.name, format.filename);
    try dir.sync();
    return .{
        .terms = header.terms,
        .postings = header.postings,
        .analyzed_bytes = header.analyzed_bytes,
        .index_bytes = writer.offset,
        .dictionary_bytes = header.dictionary_bytes,
        .postings_bytes = header.postings_bytes,
        .workers = worker_count,
    };
}

fn partition(total: usize, worker: usize, count: usize) usize {
    return @intCast(@as(u64, total) * worker / count);
}

const Posting = struct {
    id: format.RecordId,
    importance: u16,

    fn less(_: void, a: Posting, b: Posting) bool {
        if (a.importance != b.importance) return a.importance > b.importance;
        return a.id < b.id;
    }
};

const Entry = struct {
    key: []const u8,
    items: std.ArrayList(Posting) = .empty,

    fn less(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

const Worker = struct {
    owned: std.heap.ArenaAllocator,
    data: bundle.Data,
    records: format.RecordCounts,
    first: format.RecordId,
    end: format.RecordId,
    deadline: io.Deadline,
    cancel: *std.atomic.Value(bool),
    scratch: analysis.Scratch = .{},
    lookup: std.StringHashMapUnmanaged(u32) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    key: std.ArrayList(u8) = .empty,
    analyzed: u64 = 0,
    failure: ?anyerror = null,

    fn run(self: *Worker) void {
        self.collect() catch |err| {
            self.failure = err;
            self.cancel.store(true, .release);
        };
    }

    fn collect(self: *Worker) !void {
        const a = self.owned.allocator();
        var id = self.first;
        while (id < self.end) : (id += 1) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (self.cancel.load(.acquire)) return;
            try self.addDocument(a, self.records.document(id).?, id);
        }
        var entry_scratch: std.ArrayList(Entry) = .empty;
        try sortRuns(Entry, a, self.entries.items, &entry_scratch, Entry.less, self.deadline);
        entry_scratch.deinit(a);
        var posting_scratch: std.ArrayList(Posting) = .empty;
        defer posting_scratch.deinit(a);
        for (self.entries.items) |entry| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (self.cancel.load(.acquire)) return;
            try sortRuns(Posting, a, entry.items.items, &posting_scratch, Posting.less, self.deadline);
        }
    }

    fn addDocument(self: *Worker, a: Allocator, document: format.Document, id: format.RecordId) !void {
        const row = document.row;
        const core = switch (document.kind) {
            .place => self.data.places[row].record,
            .street => self.data.streets[row].record,
            .address => self.data.addresses[row].record,
            .poi => self.data.pois[row].record,
        };
        const entry: Posting = .{ .id = id, .importance = core.attr.importance };
        const iso = try self.data.countryIso(core.hierarchy.country);
        const options = defaultOptions(iso);
        try self.addNames(a, .name, core.names, options, entry);
        if (document.kind == .street) try self.addNames(a, .street, core.names, options, entry);
        if (document.kind == .address) {
            const address = self.data.addresses[row];
            try self.addText(a, .name, try address.house_name.get(self.data.text), options, entry);
            try self.addText(a, .street, try address.street.get(self.data.text), options, entry);
            try self.addText(a, .house_number, try address.number.get(self.data.text), .{}, entry);
        }
        if (try self.data.admin(core.hierarchy.city)) |city| {
            try self.addNames(a, .city, city.names, options, entry);
        }
        try self.addPostcodes(a, try core.hierarchy.postcode.get(self.data.text), iso, options, entry);
    }

    fn addNames(self: *Worker, a: Allocator, field: format.Field, names: model.Span, options: analysis.Options, entry: Posting) !void {
        for (try names.get(self.data.names)) |name| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            var locale = options;
            const lang = try name.language.get(self.data.text);
            if (lang.len != 0) locale.language = analysis.Language.fromTag(lang);
            try self.addText(a, field, try name.text.get(self.data.text), locale, entry);
        }
    }

    fn addText(self: *Worker, a: Allocator, field: format.Field, text: []const u8, options: analysis.Options, entry: Posting) !void {
        if (text.len == 0) return;
        const parsed = try self.scratch.analyze(a, text, options, self.deadline);
        self.analyzed = std.math.add(u64, self.analyzed, parsed.bytes.len) catch return error.GeocodeIndexTooLarge;
        for (parsed.tokens) |token| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            try self.addTerm(a, field, parsed.text(token), entry);
            try self.addTerm(a, field, parsed.latin(token), entry);
        }
    }

    fn addPostcodes(self: *Worker, a: Allocator, text: []const u8, iso: []const u8, options: analysis.Options, entry: Posting) !void {
        if (text.len == 0) return;
        var parts = std.mem.splitScalar(u8, text, ';');
        while (parts.next()) |part| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (postal.Code.normalize(part, iso)) |code| {
                var lower: [32]u8 = undefined;
                const term = std.ascii.lowerString(&lower, code.bytes());
                self.analyzed = std.math.add(u64, self.analyzed, term.len) catch return error.GeocodeIndexTooLarge;
                try self.addTerm(a, .postcode, term, entry);
            } else {
                try self.addText(a, .postcode, part, options, entry);
            }
        }
    }

    fn addTerm(self: *Worker, a: Allocator, field: format.Field, term: []const u8, entry: Posting) !void {
        if (term.len == 0) return;
        if (term.len > format.max_term_bytes) return error.InvalidGeocodeTerm;
        self.key.clearRetainingCapacity();
        try self.key.append(a, @backingInt(field));
        try self.key.appendSlice(a, term);
        const present = try self.lookup.getOrPut(a, self.key.items);
        if (!present.found_existing) {
            const saved = try a.dupe(u8, self.key.items);
            present.key_ptr.* = saved;
            present.value_ptr.* = std.math.cast(u32, self.entries.items.len) orelse return error.GeocodeIndexTooLarge;
            try self.entries.append(a, .{ .key = saved });
        }
        const items = &self.entries.items[present.value_ptr.*].items;
        if (items.items.len == 0 or items.items[items.items.len - 1].id != entry.id)
            try items.append(a, entry);
    }
};

/// Sort bounded runs, then merge them with deadline checks even for very
/// common terms whose posting lists span most of the input.
fn sortRuns(
    comptime T: type,
    a: Allocator,
    values: []T,
    scratch: *std.ArrayList(T),
    comptime less: fn (void, T, T) bool,
    deadline: io.Deadline,
) !void {
    const run_size = 1024;
    if (values.len < 2) return;
    var start: usize = 0;
    while (start < values.len) : (start += run_size) {
        if (deadline.expired()) return error.DeadlineExceeded;
        std.mem.sortUnstable(T, values[start..@min(start + run_size, values.len)], {}, less);
    }
    if (values.len <= run_size) return;
    try scratch.resize(a, values.len);
    var source = values;
    var target = scratch.items;
    var width: usize = run_size;
    while (width < values.len) : (width *= 2) {
        start = 0;
        while (start < values.len) : (start += width * 2) {
            const middle = @min(start + width, values.len);
            const end = @min(middle + width, values.len);
            var left = start;
            var right = middle;
            for (start..end) |i| {
                if (i % run_size == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (right == end or (left < middle and less({}, source[left], source[right]))) {
                    target[i] = source[left];
                    left += 1;
                } else {
                    target[i] = source[right];
                    right += 1;
                }
            }
        }
        std.mem.swap([]T, &source, &target);
    }
    if (source.ptr != values.ptr) {
        start = 0;
        while (start < values.len) : (start += run_size) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const end = @min(start + run_size, values.len);
            @memcpy(values[start..end], source[start..end]);
        }
    }
}

fn defaultOptions(iso: []const u8) analysis.Options {
    const country = analysis.Country.fromIso(iso);
    return .{
        .country = country,
        .language = switch (country) {
            .us, .ca, .gb => .en,
            .de, .at, .ch, .li => .de,
            else => .und,
        },
    };
}

fn merge(a: Allocator, runs: []const Worker, writer: *index_writer.Writer, deadline: io.Deadline) !void {
    const cursors = try a.alloc(usize, runs.len);
    defer a.free(cursors);
    @memset(cursors, 0);
    const active = try a.alloc([]const Posting, runs.len);
    defer a.free(active);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    while (true) {
        if (deadline.expired()) return error.DeadlineExceeded;
        var lowest: ?[]const u8 = null;
        for (runs, cursors) |run, current| {
            if (current == run.entries.items.len) continue;
            const key = run.entries.items[current].key;
            if (lowest == null or std.mem.lessThan(u8, key, lowest.?)) lowest = key;
        }
        const key = lowest orelse break;
        var active_count: usize = 0;
        var count: u32 = 0;
        for (runs, cursors) |run, *current| {
            if (current.* == run.entries.items.len) continue;
            const entry = run.entries.items[current.*];
            if (!std.mem.eql(u8, key, entry.key)) continue;
            current.* += 1;
            active[active_count] = entry.items.items;
            active_count += 1;
            count = std.math.add(u32, count, @intCast(entry.items.items.len)) catch return error.GeocodeIndexTooLarge;
        }
        bytes.clearRetainingCapacity();
        var encoded = try posting.Writer.init(a, &bytes, count);
        try mergePostings(active[0..active_count], &encoded, deadline);
        const list = try posting.List.init(try encoded.finish(), count);
        try writer.add(@fromBackingInt(@intCast(key[0])), key[1..], list);
    }
}

fn mergePostings(runs: [][]const Posting, writer: *posting.Writer, deadline: io.Deadline) !void {
    var remaining = runs.len;
    while (remaining != 0) {
        if (deadline.expired()) return error.DeadlineExceeded;
        var best: usize = 0;
        for (runs[1..remaining], 1..) |run, i| {
            if (Posting.less({}, run[0], runs[best][0])) best = i;
        }
        try writer.append(runs[best][0].id);
        runs[best] = runs[best][1..];
        if (runs[best].len == 0) {
            remaining -= 1;
            runs[best] = runs[remaining];
        }
    }
}
