//! The seed quality set draws its expected OSM records from the source bundle.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const geocode = routing.geocode;
const query = geocode.query;
const Allocator = std.mem.Allocator;

const Group = enum { place, street, free_address, structured_address, poi, typo };
const groups = [_]struct { group: Group, count: usize }{
    .{ .group = .place, .count = 100 },
    .{ .group = .street, .count = 100 },
    .{ .group = .free_address, .count = 100 },
    .{ .group = .structured_address, .count = 100 },
    .{ .group = .poi, .count = 60 },
    .{ .group = .typo, .count = 40 },
};

const Case = struct { request: query.Request, expected: geocode.index.Document, group: Group };
const Tally = struct { queries: usize = 0, hits: usize = 0 };

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingGeocodeBundle;
    if (args.next() != null) return error.UnexpectedArgument;
    const a = init.arena.allocator();
    var engine = try query.Engine.open(std.heap.page_allocator, path, .none);
    defer engine.close();
    const data = engine.bundle.data;
    var rng = std.Random.DefaultPrng.init(222);
    const random = rng.random();
    var cases: std.ArrayList(Case) = .empty;
    for (groups) |group| try sample(a, data, random, &cases, group.group, group.count);
    random.shuffle(Case, cases.items);
    if (cases.items.len != 500) return error.InvalidGeocodeQualitySet;

    var requests: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer requests.deinit();
    const temporary = requests.allocator();
    var tallies: [groups.len]Tally = @splat(.{});
    var misses: std.ArrayList(Case) = .empty;
    var total = Tally{};
    const rounds = 5;
    const timings = try a.alloc(u64, rounds * cases.items.len);
    for (0..rounds + 1) |round| {
        for (cases.items, 0..) |case, i| {
            _ = requests.reset(.retain_capacity);
            const timer = io.Timer.start();
            const found = try engine.search(temporary, case.request, .fromNowMs(250));
            const elapsed = timer.read();
            if (round != 0) {
                timings[(round - 1) * cases.items.len + i] = elapsed;
                continue;
            }
            var hit = false;
            for (found) |result| {
                if (std.meta.eql(case.expected, result.document)) {
                    hit = true;
                    break;
                }
            }
            const tally = &tallies[@backingInt(case.group)];
            tally.queries += 1;
            tally.hits += @intFromBool(hit);
            total.queries += 1;
            total.hits += @intFromBool(hit);
            if (!hit and misses.items.len < 20) try misses.append(a, case);
        }
    }
    std.mem.sortUnstable(u64, timings, {}, std.sort.asc(u64));
    const p99 = timings[(timings.len - 1) * 99 / 100];
    const report = try std.json.Stringify.valueAlloc(a, .{
        .dataset_uuid = engine.bundle.uuid,
        .top_three = total,
        .by_group = .{
            .place = tallies[@backingInt(Group.place)],
            .street = tallies[@backingInt(Group.street)],
            .free_address = tallies[@backingInt(Group.free_address)],
            .structured_address = tallies[@backingInt(Group.structured_address)],
            .poi = tallies[@backingInt(Group.poi)],
            .typo = tallies[@backingInt(Group.typo)],
        },
        .lookups = timings.len,
        .p50_ns = timings[(timings.len - 1) / 2],
        .p95_ns = timings[(timings.len - 1) * 95 / 100],
        .p99_ns = p99,
        .max_ns = timings[timings.len - 1],
        .misses = misses.items,
    }, .{ .whitespace = .indent_2 });
    try io.writeStdout(report);
    try io.writeStdout("\n");
    if (total.hits * 100 < total.queries * 85) return error.GeocodeQualityBudgetExceeded;
    if (p99 >= 10 * std.time.ns_per_ms) return error.GeocodeQueryBudgetExceeded;
}

fn sample(a: Allocator, data: geocode.bundle.Data, random: std.Random, cases: *std.ArrayList(Case), group: Group, count: usize) !void {
    const layer: query.Layer = switch (group) {
        .place => .place,
        .street, .typo => .street,
        .free_address, .structured_address => .address,
        .poi => .poi,
    };
    const size = switch (layer) {
        .place => data.places.len,
        .street => data.streets.len,
        .address => data.addresses.len,
        .poi => data.pois.len,
    };
    if (size < count) return error.InsufficientGeocodeQualityRecords;
    var used: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer used.deinit(a);
    var accepted: usize = 0;
    for (0..size * 2) |_| {
        const row = random.uintLessThan(u32, @intCast(size));
        if (used.contains(row)) continue;
        try used.put(a, row, {});
        const doc: geocode.index.Document = .{ .kind = layer, .row = row };
        const text = try makeText(a, data, random, doc, group) orelse continue;
        const filters: query.Filters = if (group == .street or group == .typo) .{ .layers = .initOne(.street) } else .{};
        try cases.append(a, .{ .request = .{ .text = text, .filters = filters, .limit = 3 }, .expected = doc, .group = group });
        accepted += 1;
        if (accepted == count) return;
    }
    return error.InsufficientGeocodeQualityRecords;
}

fn makeText(a: Allocator, data: geocode.bundle.Data, random: std.Random, doc: geocode.index.Document, group: Group) !?query.Text {
    const row = doc.row;
    const record = switch (doc.kind) {
        .place => data.places[row].record,
        .street => data.streets[row].record,
        .address => data.addresses[row].record,
        .poi => data.pois[row].record,
    };
    const name = try primaryName(data, record.names);
    const region = try data.admin(record.hierarchy.city);
    const city = if (region) |place| try primaryName(data, place.names) else "";
    if (doc.kind == .address) {
        const address = data.addresses[row];
        const number = try address.number.get(data.text);
        const street = try address.street.get(data.text);
        const raw_postcode = try record.hierarchy.postcode.get(data.text);
        const postcode = raw_postcode[0 .. std.mem.indexOfScalar(u8, raw_postcode, ';') orelse raw_postcode.len];
        const country = try data.countryIso(record.hierarchy.country);
        if (number.len == 0 or street.len == 0 or postcode.len == 0 or city.len == 0 or country.len == 0) return null;
        return if (group == .structured_address)
            .{ .structured = .{ .street = street, .house_number = number, .postcode = postcode, .city = city, .country = country } }
        else
            .{ .free = try std.fmt.allocPrint(a, "{s} {s}, {s} {s}", .{ number, street, postcode, city }) };
    }
    if (name.len < 3) return null;
    return switch (group) {
        .place => .{ .free = name },
        .street => if (city.len == 0) null else .{ .structured = .{ .street = name, .city = city } },
        .poi => if (city.len == 0) null else .{ .free = try std.fmt.allocPrint(a, "{s}, {s}", .{ name, city }) },
        .typo => if (city.len == 0) null else .{ .structured = .{
            .street = try transpose(a, random, name) orelse return null,
            .city = city,
        } },
        else => unreachable,
    };
}

fn primaryName(data: geocode.bundle.Data, span: geocode.model.Span) ![]const u8 {
    const names = try span.get(data.names);
    for (names) |name| {
        if (name.language.len == 0) return name.text.get(data.text);
    }
    return if (names.len == 0) "" else names[0].text.get(data.text);
}

fn transpose(a: Allocator, random: std.Random, name: []const u8) !?[]const u8 {
    var tokens = std.mem.tokenizeScalar(u8, name, ' ');
    var offset: usize = 0;
    while (tokens.next()) |token| {
        const start = std.mem.indexOf(u8, name[offset..], token).? + offset;
        offset = start + token.len;
        if (token.len < 5) continue;
        var alphabetic = true;
        for (token) |byte| alphabetic = alphabetic and std.ascii.isAlphabetic(byte);
        if (!alphabetic) continue;
        const pick = random.uintLessThan(usize, token.len - 1);
        for (0..token.len - 1) |i| {
            const at = start + (pick + i) % (token.len - 1);
            if (std.ascii.toLower(name[at]) == std.ascii.toLower(name[at + 1])) continue;
            const changed = try a.dupe(u8, name);
            std.mem.swap(u8, &changed[at], &changed[at + 1]);
            return changed;
        }
    }
    return null;
}
