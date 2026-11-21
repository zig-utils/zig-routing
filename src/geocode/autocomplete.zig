//! Per-keystroke geocoding over full tokens and one unfinished suffix.
const std = @import("std");
const io = @import("../infra/io.zig");
const analysis = @import("analyze.zig");
const format = @import("index_model.zig");
const parse = @import("query_parse.zig");
const query = @import("query.zig");
const rank = @import("query_rank.zig");
const retrieve = @import("query_retrieve.zig");
const short = @import("short_prefix.zig");
const Allocator = std.mem.Allocator;

pub const Request = struct {
    text: []const u8,
    filters: query.Filters = .{},
    limit: usize = 10,
};

pub const Engine = struct {
    search: query.Engine,
    prefixes: short.Cache,

    pub fn open(a: Allocator, path: []const u8, deadline: io.Deadline) !Engine {
        var search = try query.Engine.open(a, path, deadline);
        errdefer search.close();
        const prefixes = try short.Cache.init(a, search.bundle.data, search.index.view, query.max_results, deadline);
        return .{ .search = search, .prefixes = prefixes };
    }

    pub fn close(self: *Engine) void {
        self.prefixes.deinit();
        self.search.close();
        self.* = undefined;
    }

    pub fn suggest(self: *const Engine, arena: Allocator, request: Request, deadline: io.Deadline) ![]query.Result {
        try query.validate(request.filters, request.limit, deadline);
        const text: query.Text = .{ .free = request.text };
        try parse.checkText(text);
        if (request.filters.layers.count() == 0) return &.{};
        const iso = self.search.defaultIso();
        var locale = query.options(request.filters.language, iso);
        locale.prefix_last = true;
        var analyzer: analysis.Scratch = .{};
        defer analyzer.deinit(arena);
        const terms = try parse.parse(arena, text, locale, iso, &analyzer, deadline);
        if (terms.len == 0) return &.{};
        var top: rank.Top = .{ .entries = try arena.alloc(rank.Ranked, request.limit) };
        const last = terms[terms.len - 1];
        const data = self.search.bundle.data;
        const view = self.search.index.view;
        if (terms.len == 1 and last.prefix and short.isShort(last.text) and
            (last.latin.len == 0 or short.isShort(last.latin)) and numberPrefix(last).len == last.text.len)
        {
            if (self.prefixes.rows.get(last.text)) |row|
                try short.collect(arena, row, data, view.header.records, request.filters, 0, &top, deadline);
            if (last.latin.len != 0) if (self.prefixes.rows.get(last.latin)) |row| {
                try short.collect(arena, row, data, view.header.records, request.filters, retrieve.weights.transliteration, &top, deadline);
            };
        } else {
            const buffer = try arena.alloc(u8, view.scratchBytes());
            const clauses = try arena.alloc(retrieve.Clause, terms.len);
            for (terms, clauses) |term, *clause| {
                if (!term.prefix) {
                    clause.* = try retrieve.exact(arena, view, term, buffer, deadline);
                    continue;
                }
                clause.* = .{};
                for (format.fields) |field| {
                    const strength = retrieve.fieldWeight(term, field) orelse continue;
                    const key = if (field == .house_number) numberPrefix(term) else term.text;
                    try self.addFieldPrefix(arena, clause, field, key, strength, buffer, deadline);
                    if (term.latin.len != 0)
                        try self.addFieldPrefix(arena, clause, field, term.latin, strength - retrieve.weights.transliteration, buffer, deadline);
                }
            }
            std.mem.sortUnstable(retrieve.Clause, clauses, {}, retrieve.Clause.smaller);
            try self.search.collect(.{}, clauses, request.filters, &top, deadline);
        }
        return rank.assembleAll(arena, data, top, request.filters.language, deadline);
    }

    fn addFieldPrefix(
        self: *const Engine,
        a: Allocator,
        clause: *retrieve.Clause,
        field: format.Field,
        key: []const u8,
        strength: u16,
        buffer: []u8,
        deadline: io.Deadline,
    ) !void {
        if (short.isShort(key)) {
            if (self.prefixes.rows.get(key)) |row| {
                if (row.lists[@backingInt(field)]) |list| try clause.add(a, list, strength);
            }
            return;
        }
        try retrieve.addPrefix(a, clause, self.search.index.view, field, key, strength, buffer, deadline);
    }
};

fn numberPrefix(term: parse.Term) []const u8 {
    if (term.kind != .house_number) return term.text;
    const key = std.mem.trimStart(u8, term.text, "0");
    return if (key.len == 0) "0" else key;
}
