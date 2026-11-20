//! Address-name fixtures and a single-core analyzer throughput check.
const std = @import("std");
const routing = @import("routing");
const analysis = routing.geocode.analyze;
const io = routing.infra.io;
const Allocator = std.mem.Allocator;

const english = @embedFile("fixtures/geocode/analysis-en.tsv");
const german = @embedFile("fixtures/geocode/analysis-de.tsv");
const en: analysis.Options = .{ .language = .en, .country = .us };
const de: analysis.Options = .{ .language = .de, .country = .de };

const Pair = struct {
    name: []const u8,
    query: []const u8,
    expected: []const u8,

    fn parse(line: []const u8) !Pair {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse return error.InvalidAnalysisFixture;
        const query = fields.next() orelse return error.InvalidAnalysisFixture;
        const expected = fields.next() orelse return error.InvalidAnalysisFixture;
        if (name.len == 0 or query.len == 0 or expected.len == 0 or fields.next() != null)
            return error.InvalidAnalysisFixture;
        return .{ .name = name, .query = query, .expected = expected };
    }
};

fn checkTokens(result: analysis.Result, expected: []const u8) !void {
    const t = std.testing;
    var tokens = std.mem.splitScalar(u8, expected, '|');
    for (result.tokens) |token| {
        const row = tokens.next() orelse return error.UnexpectedAnalysisToken;
        const split = std.mem.indexOfScalar(u8, row, ':') orelse return error.InvalidAnalysisFixture;
        const kind = std.meta.stringToEnum(analysis.Kind, row[0..split]) orelse return error.InvalidAnalysisFixture;
        try t.expectEqual(kind, token.attr.kind);
        try t.expectEqualStrings(row[split + 1 ..], result.text(token));
    }
    try t.expectEqual(null, tokens.next());
}

fn checkCorpus(fixture: []const u8, options: analysis.Options) !void {
    const t = std.testing;
    const a = t.allocator;
    var names: analysis.Scratch = .{};
    defer names.deinit(a);
    var queries: analysis.Scratch = .{};
    defer queries.deinit(a);
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        errdefer std.debug.print("analysis fixture {s} row {d}: {s}\n", .{ @tagName(options.language), count + 1, line });
        const pair = try Pair.parse(line);
        const indexed = try names.analyze(a, pair.name, options, .none);
        try checkTokens(indexed, pair.expected);
        const queried = try queries.analyze(a, pair.query, options, .none);
        try checkTokens(queried, pair.expected);
        try t.expectEqualSlices(u8, indexed.bytes, queried.bytes);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(indexed.tokens), std.mem.sliceAsBytes(queried.tokens));
        const same_input = try queries.analyze(a, pair.name, options, .none);
        try t.expectEqualSlices(u8, indexed.bytes, same_input.bytes);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(indexed.tokens), std.mem.sliceAsBytes(same_input.tokens));
    }
    try t.expect(count >= 200);
}

test "English and German names and queries match their expected token streams" {
    try checkCorpus(english, en);
    try checkCorpus(german, de);
}

test "canonical equivalents yield identical bytes on a warmed allocator" {
    const t = std.testing;
    const a = t.allocator;
    var composed: analysis.Scratch = .{};
    defer composed.deinit(a);
    var decomposed: analysis.Scratch = .{};
    defer decomposed.deinit(a);
    const first = "CAFÉ ΑΘΉΝΑ ЁЛКА 東京 ｶﾞﾗｽ 한글 １２";
    const second = "CAFE\u{0301} ΑΘΗ\u{0301}ΝΑ Е\u{0308}ЛКА 東京 ガラス 한글 12";
    const cross_script = analysis.Options{};
    const expected = try composed.analyze(a, first, cross_script, .none);
    _ = try decomposed.analyze(a, second, cross_script, .none);
    var empty: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&empty);
    const actual = try decomposed.analyze(fixed.allocator(), second, cross_script, .none);
    try t.expectEqualSlices(u8, expected.bytes, actual.bytes);
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.tokens), std.mem.sliceAsBytes(actual.tokens));
}

const Sample = struct { input: []const u8, options: analysis.Options };
const Metrics = struct {
    input_bytes: usize,
    elapsed_ns: u64,
    tokens: usize,
    mb_per_second: f64,
};

const multilingual = [_]Sample{
    .{ .input = "Λεωφόρος Αλεξάνδρας 42, Αθήνα 11473", .options = .{} },
    .{ .input = "Невский проспект 28, Санкт-Петербург", .options = .{} },
    .{ .input = "Москва, Тверская улица ١٢", .options = .{} },
    .{ .input = "東京都港区芝公園４丁目 東京タワー", .options = .{} },
    .{ .input = "北京市东城区东长安街１号", .options = .{} },
    .{ .input = "서울특별시 중구 세종대로 110", .options = .{} },
    .{ .input = "Łódź, Østerbrogade, Đà Nẵng", .options = .{} },
    .{ .input = "Rue de l’Église, L-2240 Luxembourg", .options = .{ .country = .lu } },
    .{ .input = "Downing St, London SW1A 2AA", .options = .{ .language = .en, .country = .gb } },
    .{ .input = "Wellington Street, Ottawa K1A 0B1", .options = .{ .language = .en, .country = .ca } },
};

fn samples(allocator: Allocator, fixture: []const u8, options: analysis.Options) ![]Sample {
    var items: std.ArrayList(Sample) = .empty;
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    while (lines.next()) |line| {
        const pair = try Pair.parse(line);
        try items.append(allocator, .{ .input = pair.name, .options = options });
        try items.append(allocator, .{ .input = pair.query, .options = options });
    }
    return items.toOwnedSlice(allocator);
}

fn measure(allocator: Allocator, input: []const Sample) !Metrics {
    var scratch: analysis.Scratch = .{};
    defer scratch.deinit(allocator);
    var total_bytes: usize = 0;
    for (input) |sample| {
        _ = try scratch.analyze(allocator, sample.input, sample.options, .none);
        total_bytes += sample.input.len;
    }
    const rounds = @max(1, (16 * 1024 * 1024) / total_bytes);
    var empty: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&empty);
    const forbid_growth = fixed.allocator();
    const timer = io.Timer.start();
    var total_tokens: usize = 0;
    for (0..rounds) |_| {
        for (input) |sample| {
            const result = try scratch.analyze(forbid_growth, sample.input, sample.options, .none);
            total_tokens += result.tokens.len;
            std.mem.doNotOptimizeAway(result.bytes);
            std.mem.doNotOptimizeAway(result.tokens);
        }
    }
    const elapsed = timer.read();
    const bytes = rounds * total_bytes;
    return .{
        .input_bytes = bytes,
        .elapsed_ns = elapsed,
        .tokens = total_tokens,
        .mb_per_second = 1000 * @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(elapsed)),
    };
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const en_samples = try samples(a, english, en);
    const de_samples = try samples(a, german, de);
    const result = .{
        .english = try measure(init.gpa, en_samples),
        .german = try measure(init.gpa, de_samples),
        .multilingual = try measure(init.gpa, &multilingual),
        .minimum_mb_per_second = 20,
        .worker_threads = 1,
        .warm_allocator_capacity = 0,
    };
    const json = try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2 });
    try io.writeStdout(json);
    try io.writeStdout("\n");
    if (@min(result.english.mb_per_second, result.german.mb_per_second, result.multilingual.mb_per_second) < result.minimum_mb_per_second)
        return error.GeocodeAnalysisTooSlow;
}
