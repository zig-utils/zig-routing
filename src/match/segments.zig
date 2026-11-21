//! Assign independent trace segments to persistent routing workers.
const std = @import("std");
const io = @import("../infra/io.zig");
const memory = @import("../infra/arena.zig");
const core = @import("../search/search.zig");
const graph = @import("../graph/root.zig");
const routing = @import("routing.zig");
const transition = @import("transition.zig");
const candidates = @import("candidates.zig");
const Allocator = std.mem.Allocator;

pub const Query = struct {
    from: routing.Origin,
    targets: []const candidates.Candidate,
    measurements: routing.Measurements,
};

/// Each segment owns its results and keeps them until the next batch or deinit.
pub const Segment = struct {
    queries: []const Query,
    output: memory.Arena,
    routes: []const []const ?routing.Route = &.{},

    pub fn deinit(self: *Segment) void {
        self.output.deinit();
    }

    fn reset(self: *Segment) void {
        self.routes = &.{};
        self.output.reset();
    }
};

pub fn Pool(comptime K: type) type {
    return struct {
        const Self = @This();
        const Router = routing.Router(K);

        const Batch = struct {
            kernel: K,
            model: *const transition.Model,
            segments: []Segment,
            control: core.Control,
            next: usize = 0,
            remaining: usize,
            failure_index: usize = std.math.maxInt(usize),
            failure: ?anyerror = null,
        };

        const Shared = struct {
            mutex: io.Mutex = .{},
            pending: io.Condition = .{},
            complete: io.Condition = .{},
            closing: bool = false,
            batch: ?*Batch = null,

            fn stop(self: *Shared) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.closing = true;
                self.pending.broadcast();
            }

            fn work(self: *Shared, engine: *Router) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (!self.closing) {
                    const batch = self.batch orelse {
                        self.pending.wait(&self.mutex);
                        continue;
                    };
                    if (batch.next == batch.segments.len) {
                        self.pending.wait(&self.mutex);
                        continue;
                    }
                    const index = batch.next;
                    batch.next += 1;
                    self.mutex.unlock();
                    const result = runSegment(engine, batch.kernel, batch.model, &batch.segments[index], batch.control);
                    self.mutex.lock();
                    result catch |err| {
                        if (index < batch.failure_index) {
                            batch.failure_index = index;
                            batch.failure = err;
                        }
                    };
                    batch.remaining -= 1;
                    if (batch.remaining == 0) self.complete.broadcast();
                }
            }
        };

        allocator: Allocator,
        shared: *Shared,
        routers: []Router,
        threads: []std.Thread,

        /// The backing allocator and segment output allocators support
        /// concurrent allocation by workers.
        pub fn init(a: Allocator, view: *const graph.reader.View, workers: usize, scratch_bytes: usize) !Self {
            if (workers == 0) return error.InvalidWorkerCount;
            const shared = try a.create(Shared);
            errdefer a.destroy(shared);
            shared.* = .{};
            const routers = try a.alloc(Router, workers);
            errdefer a.free(routers);
            const threads = try a.alloc(std.Thread, workers);
            errdefer a.free(threads);
            var initialized: usize = 0;
            var started: usize = 0;
            errdefer {
                shared.stop();
                for (threads[0..started]) |thread| thread.join();
                for (routers[0..initialized]) |*engine| engine.deinit();
            }
            for (routers, threads) |*engine, *thread| {
                engine.* = try Router.init(a, view, scratch_bytes);
                initialized += 1;
                thread.* = try std.Thread.spawn(.{}, Shared.work, .{ shared, engine });
                started += 1;
            }
            return .{ .allocator = a, .shared = shared, .routers = routers, .threads = threads };
        }

        /// Call after the current batch has returned.
        pub fn deinit(self: *Self) void {
            self.shared.stop();
            for (self.threads) |thread| thread.join();
            for (self.routers) |*engine| engine.deinit();
            self.allocator.free(self.threads);
            self.allocator.free(self.routers);
            self.allocator.destroy(self.shared);
        }

        pub fn run(self: *Self, kernel: K, model: *const transition.Model, segments: []Segment, control: core.Control) !void {
            try control.check();
            if (segments.len == 0) return;
            const shared = self.shared;
            shared.mutex.lock();
            defer shared.mutex.unlock();
            if (shared.batch != null) return error.TraceWorkersBusy;
            var batch: Batch = .{
                .kernel = kernel,
                .model = model,
                .segments = segments,
                .control = control,
                .remaining = segments.len,
            };
            shared.batch = &batch;
            shared.pending.broadcast();
            while (batch.remaining != 0) shared.complete.wait(&shared.mutex);
            shared.batch = null;
            if (batch.failure) |err| {
                for (segments) |*segment| segment.reset();
                return err;
            }
        }

        fn runSegment(engine: *Router, kernel: K, model: *const transition.Model, segment: *Segment, control: core.Control) !void {
            segment.reset();
            const rows = try segment.output.allocator().alloc([]const ?routing.Route, segment.queries.len);
            for (segment.queries, rows) |query, *row| {
                row.* = try engine.connect(&segment.output, kernel, model, query.from, query.targets, query.measurements, control);
            }
            segment.routes = rows;
        }
    };
}
