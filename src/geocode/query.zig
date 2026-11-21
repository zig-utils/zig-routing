//! Forward geocoding over a checked bundle and term index.
const std = @import("std");
const io = @import("../infra/io.zig");
const analysis = @import("analyze.zig");
const bundle = @import("bundle.zig");
const index = @import("index.zig");
const index_build = @import("index_build.zig");
const format = @import("index_model.zig");
const model = @import("model.zig");
const parse = @import("query_parse.zig");
const rank = @import("query_rank.zig");
const retrieve = @import("query_retrieve.zig");
const Allocator = std.mem.Allocator;

pub const Bounds = rank.Bounds;
pub const Filters = rank.Filters;
pub const Layer = format.Kind;
pub const Result = rank.Result;
pub const Text = parse.Text;
pub const Structured = parse.Structured;
pub const max_input_bytes = parse.max_input_bytes;
pub const max_results = 100;

pub const Request = struct {
    text: Text,
    filters: Filters = .{},
    limit: usize = 10,
    typos: bool = true,
};

const Region = struct {
    id: model.AdminId,
    iso: []const u8,
};

const CountryAlias = struct {
    region: Region,
    terms: []const parse.Term,
};

pub const Scope = struct {
    country: model.AdminId = .unknown,
    country_score: u32 = 0,
};

const Hypothesis = struct {
    terms: []const parse.Term,
    scope: Scope = .{},
};

pub const Engine = struct {
    bundle: bundle.Bundle,
    index: index.Index,
    country_memory: std.heap.ArenaAllocator,
    regions: []const Region,
    aliases: []const CountryAlias,

    pub fn open(a: Allocator, path: []const u8, deadline: io.Deadline) !Engine {
        const dir = try io.Directory.open(path);
        defer dir.close();
        var source = try bundle.Bundle.openInDir(dir, deadline);
        errdefer source.close();
        var dictionary = try index.Index.open(dir, source.uuid, deadline);
        errdefer dictionary.close();
        if (!std.meta.eql(dictionary.view.header.records, try index_build.counts(source.data)))
            return error.GeocodeIndexRecordCountMismatch;

        var country_memory: std.heap.ArenaAllocator = .init(a);
        errdefer country_memory.deinit();
        const owned = country_memory.allocator();
        var regions: std.ArrayList(Region) = .empty;
        var aliases: std.ArrayList(CountryAlias) = .empty;
        {
            var scratch: analysis.Scratch = .{};
            defer scratch.deinit(owned);
            for (source.data.admins, 0..) |admin, i| {
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (admin.attr.division != .country) continue;
                const id: model.AdminId = @fromBackingInt(@intCast(i + 1));
                const region: Region = .{ .id = id, .iso = try source.data.countryIso(id) };
                try regions.append(owned, region);
                for (try admin.names.get(source.data.names)) |label| {
                    const text = try label.text.get(source.data.text);
                    const terms = parse.parse(owned, .{ .free = text }, .{}, "", &scratch, deadline) catch |err| switch (err) {
                        error.TooManyGeocodeTokens => continue,
                        else => return err,
                    };
                    if (terms.len != 0) try aliases.append(owned, .{ .region = region, .terms = terms });
                }
            }
        }
        return .{
            .bundle = source,
            .index = dictionary,
            .country_memory = country_memory,
            .regions = regions.items,
            .aliases = aliases.items,
        };
    }

    pub fn close(self: *Engine) void {
        self.country_memory.deinit();
        self.index.close();
        self.bundle.close();
        self.* = undefined;
    }

    /// Allocations and formatted display strings live in the request arena.
    /// The other result strings borrow the opened bundle.
    pub fn search(self: *const Engine, arena: Allocator, request: Request, deadline: io.Deadline) ![]Result {
        try validate(request.filters, request.limit, deadline);
        try parse.checkText(request.text);
        if (request.filters.layers.count() == 0) return &.{};
        var analyzer: analysis.Scratch = .{};
        defer analyzer.deinit(arena);
        var variants: [2]Hypothesis = undefined;
        const hypotheses = try self.interpret(arena, request, &analyzer, &variants, deadline);
        if (hypotheses.len == 0) return &.{};

        const scratch = try arena.alloc(u8, self.index.view.scratchBytes());
        var top: rank.Top = .{ .entries = try arena.alloc(rank.Ranked, request.limit) };
        var prepared: [2][]retrieve.Clause = undefined;
        for (hypotheses, prepared[0..hypotheses.len]) |hypothesis, *clauses| {
            clauses.* = try arena.alloc(retrieve.Clause, hypothesis.terms.len);
            for (hypothesis.terms, clauses.*) |term, *clause|
                clause.* = try retrieve.exact(arena, self.index.view, term, scratch, deadline);
            try self.collect(hypothesis.scope, clauses.*, request.filters, &top, deadline);
        }
        if (top.len == 0 and request.typos) {
            for (hypotheses, prepared[0..hypotheses.len]) |hypothesis, clauses| {
                var had_exact: [parse.max_tokens]bool = undefined;
                var all_found = true;
                for (hypothesis.terms, clauses, 0..) |term, *clause, i| {
                    had_exact[i] = clause.streams.items.len != 0;
                    if (!had_exact[i]) {
                        all_found = false;
                        try retrieve.addEdits(arena, clause, self.index.view, term, scratch, deadline);
                    }
                }
                if (!all_found) try self.collect(hypothesis.scope, clauses, request.filters, &top, deadline);
                if (top.len != 0) continue;
                for (hypothesis.terms, clauses, had_exact[0..clauses.len]) |term, *clause, had|
                    if (had) try retrieve.addEdits(arena, clause, self.index.view, term, scratch, deadline);
                try self.collect(hypothesis.scope, clauses, request.filters, &top, deadline);
            }
        }
        return rank.assembleAll(arena, self.bundle.data, top, request.filters.language, deadline);
    }

    pub fn defaultIso(self: *const Engine) []const u8 {
        return if (self.regions.len == 1) self.regions[0].iso else "";
    }

    fn interpret(
        self: *const Engine,
        a: Allocator,
        request: Request,
        scratch: *analysis.Scratch,
        out: *[2]Hypothesis,
        deadline: io.Deadline,
    ) ![]const Hypothesis {
        const default_iso = self.defaultIso();
        switch (request.text) {
            .structured => |fields| {
                const region = if (fields.country.len == 0) Region{ .id = .unknown, .iso = default_iso } else (try self.resolveCountry(a, fields.country, scratch, deadline) orelse return out[0..0]);
                out[0] = .{
                    .terms = try parse.parse(a, request.text, options(request.filters.language, region.iso), region.iso, scratch, deadline),
                    .scope = .{ .country = region.id },
                };
                return out[0..1];
            },
            .free => |value| {
                if (std.mem.lastIndexOfScalar(u8, value, ',')) |comma| {
                    const suffix = std.mem.trim(u8, value[comma + 1 ..], " \r\n\t");
                    if (try self.resolveCountry(a, suffix, scratch, deadline)) |region| {
                        const locale = options(request.filters.language, region.iso);
                        out[0] = .{
                            .terms = try parse.parse(a, .{ .free = value[0..comma] }, locale, region.iso, scratch, deadline),
                            .scope = .{ .country = region.id },
                        };
                        if (std.ascii.eqlIgnoreCase(suffix, region.iso)) return out[0..1];
                        // Country names such as Luxembourg can also be cities.
                        // Keep the city-qualified interpretation inside that country.
                        const full = try parse.parse(a, request.text, locale, region.iso, scratch, deadline);
                        out[0].scope.country_score = @as(u32, @intCast(full.len -| out[0].terms.len)) * retrieve.weights.city;
                        out[1] = .{ .terms = full, .scope = .{ .country = region.id } };
                        return out[0..2];
                    }
                }
                const terms = try parse.parse(a, request.text, options(request.filters.language, default_iso), default_iso, scratch, deadline);
                out[0] = .{ .terms = terms };
                var consumed: usize = 0;
                for (self.aliases) |alias| {
                    if (deadline.expired()) return error.DeadlineExceeded;
                    if (alias.terms.len <= consumed or alias.terms.len > terms.len) continue;
                    const remaining = terms.len - alias.terms.len;
                    if (!parse.sameSequence(terms[remaining..], alias.terms)) continue;
                    consumed = alias.terms.len;
                    out[1] = .{
                        .terms = terms[0..remaining],
                        .scope = .{
                            .country = alias.region.id,
                            .country_score = @as(u32, @intCast(consumed)) * retrieve.weights.city,
                        },
                    };
                }
                return out[0..if (consumed == 0) 1 else 2];
            },
        }
    }

    fn resolveCountry(self: *const Engine, a: Allocator, raw: []const u8, scratch: *analysis.Scratch, deadline: io.Deadline) !?Region {
        const name = std.mem.trim(u8, raw, " \r\n\t");
        if (name.len == 0) return null;
        if (name.len == 2) {
            for (self.regions) |region| if (std.ascii.eqlIgnoreCase(name, region.iso)) return region;
        }
        const parsed = try parse.parse(a, .{ .free = name }, .{}, "", scratch, deadline);
        for (self.aliases) |alias| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (parse.sameSequence(parsed, alias.terms)) return alias.region;
        }
        return null;
    }

    pub fn collect(
        self: *const Engine,
        scope: Scope,
        clauses: []retrieve.Clause,
        filters: Filters,
        top: *rank.Top,
        deadline: io.Deadline,
    ) !void {
        const data = self.bundle.data;
        const counts = self.index.view.header.records;
        if (clauses.len == 0) {
            if (scope.country == .unknown) return;
            for (0..counts.total()) |i| {
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const id: format.RecordId = @intCast(i);
                const document = counts.document(id).?;
                const source = retrieve.record(data, document);
                const hit: retrieve.Hit = .{ .id = id, .importance = source.attr.importance };
                if (try rank.evaluate(data, counts, hit, scope.country_score, scope.country, filters, deadline)) |candidate|
                    top.add(candidate);
            }
            return;
        }
        var upper: u32 = scope.country_score + rank.maxBonus(filters);
        for (clauses) |clause| {
            if (clause.streams.items.len == 0) return;
            upper += clause.max_strength;
        }
        var matches: retrieve.Intersection = .{ .clauses = clauses, .data = data, .counts = counts };
        try matches.start(deadline);
        while (try matches.next(deadline)) |match| {
            if (!top.canImprove(upper + rank.importance(match.hit.importance))) return;
            if (try rank.evaluate(data, counts, match.hit, match.text_score + scope.country_score, scope.country, filters, deadline)) |candidate|
                top.add(candidate);
        }
    }
};

pub fn validate(filters: Filters, limit: usize, deadline: io.Deadline) !void {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (limit == 0 or limit > max_results) return error.InvalidGeocodeResultLimit;
    if (filters.language.len > 63) return error.InvalidGeocodeLanguage;
    if (filters.near) |point| if (!point.inRange()) return error.InvalidGeocodeBiasPoint;
    if (filters.bounds) |bounds| if (!bounds.valid()) return error.InvalidGeocodeBounds;
}

pub fn options(language: []const u8, iso: []const u8) analysis.Options {
    var locale = analysis.Options.forIso(iso);
    const requested = analysis.Language.fromTag(language);
    if (requested != .und) locale.language = requested;
    return locale;
}
