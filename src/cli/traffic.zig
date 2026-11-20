//! Local authenticated traffic feeder command support.
const std = @import("std");
const io = @import("../infra/io.zig");
const graph = @import("../graph/reader.zig");
const http = @import("../server/http.zig");
const feed = @import("../traffic/feed.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const OwnedFeeder = struct {
    bundle: graph.Bundle,
    feeder: feed.Feeder,

    pub fn open(a: std.mem.Allocator, path: []const u8, max_age: u64, deadline: io.Deadline) !OwnedFeeder {
        const dir = try io.Directory.open(path);
        defer dir.close();
        var bundle = try graph.Bundle.openInDir(dir, null);
        errdefer bundle.close();
        const index = bundle.view.edge_key_index orelse return error.MissingEdgeKeys;
        try index.verify(bundle.view.edges.len, deadline);
        return .{
            .feeder = try feed.Feeder.open(a, dir, try bundle.view.liveTrafficGraph(), index, max_age, deadline),
            .bundle = bundle,
        };
    }

    pub fn close(self: *OwnedFeeder) void {
        self.feeder.close();
        self.bundle.close();
    }
};

pub const Admin = struct {
    feeder: *feed.Feeder,
    token_hash: [Sha256.digest_length]u8,
    mutex: io.Mutex = .{},

    pub fn init(feeder: *feed.Feeder, token: []const u8) Admin {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(token, &digest, .{});
        return .{ .feeder = feeder, .token_hash = digest };
    }

    pub fn handler(self: *Admin) http.Handler {
        return .{ .context = self, .handle = handle };
    }

    pub fn expire(self: *Admin, now: u64, deadline: io.Deadline) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.feeder.expire(now, deadline);
    }

    fn authenticate(self: *const Admin, request: *const http.Request) bool {
        var bearer: ?[]const u8 = null;
        for (request.headers) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "Authorization")) continue;
            if (bearer != null) return false;
            const prefix = "Bearer ";
            if (header.value.len <= prefix.len or !std.ascii.eqlIgnoreCase(header.value[0..prefix.len], prefix)) return false;
            bearer = header.value[prefix.len..];
        }
        const token = bearer orelse return false;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(token, &digest, .{});
        return std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest, self.token_hash);
    }

    fn handle(context: *anyopaque, ctx: *http.Ctx, req: *const http.Request, res: *http.Response) void {
        const self: *Admin = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, req.path, "/traffic")) return respond(res, 404, "unknown traffic endpoint");
        if (req.method != .POST) {
            res.addHeader("Allow: POST") catch {};
            return respond(res, 405, "POST is required");
        }
        if (!self.authenticate(req)) {
            res.addHeader("WWW-Authenticate: Bearer") catch {};
            return respond(res, 401, "invalid bearer token");
        }
        const kind = inputFormat(req.header("Content-Type") orelse "") orelse
            return respond(res, 415, "use text/csv or application/x-ndjson");
        const a = ctx.arena.allocator();
        const report = self.apply(ctx, a, req.body, kind) catch |err| {
            if (err == error.DeadlineExceeded) return respond(res, 504, "traffic update deadline exceeded");
            return respond(res, 500, "could not publish traffic batch");
        };
        defer report.deinit(a);
        var output: io.Writer.Allocating = .init(res.gpa);
        defer output.deinit();
        std.json.Stringify.value(report, .{}, &output.writer) catch return respond(res, 500, "could not write traffic report");
        const body = output.toOwnedSlice() catch return respond(res, 500, "could not write traffic report");
        res.body = .fromOwnedSlice(body);
    }

    fn apply(self: *Admin, ctx: *const http.Ctx, a: std.mem.Allocator, body: []const u8, kind: feed.Format) !feed.Report {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (ctx.cancelled()) return error.DeadlineExceeded;
        const now = std.math.cast(u64, io.wallSeconds()) orelse return error.InvalidLiveTrafficTime;
        return self.feeder.apply(a, body, kind, now, ctx.deadline);
    }
};

fn inputFormat(content_type: []const u8) ?feed.Format {
    const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const mime = std.mem.trim(u8, content_type[0..end], " \t");
    if (std.ascii.eqlIgnoreCase(mime, "text/csv")) return .csv;
    if (std.ascii.eqlIgnoreCase(mime, "application/x-ndjson") or
        std.ascii.eqlIgnoreCase(mime, "application/ndjson") or
        std.ascii.eqlIgnoreCase(mime, "application/json")) return .jsonl;
    return null;
}

fn respond(res: *http.Response, status: u16, comptime message: []const u8) void {
    res.status = status;
    res.writeBody("{\"error\":\"" ++ message ++ "\"}") catch {};
}
