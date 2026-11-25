//! Measure separator size, balance and elapsed time for experiment E4.
const std = @import("std");
const builtin = @import("builtin");
const routing = @import("routing");
const partition = routing.accel.partition;
const io = routing.infra.io;
const adjacent_id_distance = @import("adjacent_id_distance.zig");

const Level = struct {
    cells: u32 = 0,
    splits: u32 = 0,
    separator_nodes: u32 = 0,
    largest_separator: u32 = 0,
    worst_child_percent: f64 = 0,
};

fn measureLevels(cell_index: u32, cells: []const partition.Cell, levels: *std.ArrayList(Level), depth: usize, a: std.mem.Allocator) !void {
    if (depth == levels.items.len) try levels.append(a, .{});
    const cell = cells[cell_index];
    levels.items[depth].cells += 1;
    if (cell.isLeaf()) return;
    const size = cell.end - cell.separator_begin;
    levels.items[depth].splits += 1;
    levels.items[depth].separator_nodes += size;
    levels.items[depth].largest_separator = @max(size, levels.items[depth].largest_separator);
    const total: f64 = @floatFromInt(cell.end - cell.begin);
    for ([_]u32{ cell.left, cell.right }) |index| {
        if (index == partition.no_child) continue;
        const child = cells[index];
        const fraction = @as(f64, @floatFromInt(child.end - child.begin)) * 100.0 / total;
        levels.items[depth].worst_child_percent = @max(fraction, levels.items[depth].worst_child_percent);
        try measureLevels(index, cells, levels, depth + 1, a);
    }
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    var options: partition.Options = .{};
    if (args.next()) |arg| options.threads = try std.fmt.parseUnsigned(usize, arg, 10);
    if (args.next()) |arg| options.leaf_edges = try std.fmt.parseUnsigned(u32, arg, 10);
    if (args.next()) |arg| options.max_side_percent = try std.fmt.parseUnsigned(u8, arg, 10);
    if (args.next()) |arg| options.max_link_gap = try std.fmt.parseUnsigned(u32, arg, 10);
    if (args.next() != null) return error.InvalidPartitionBenchmarkArguments;

    var bundle = try routing.graph.reader.Bundle.open(path);
    defer bundle.close();
    const a = init.arena.allocator();
    const timer = io.Timer.start();
    const order = try partition.dissect(a, &bundle.view, options);
    const elapsed = timer.read();
    defer order.deinit(a);

    const ranks = try init.gpa.alloc(u32, order.nodes.len);
    defer init.gpa.free(ranks);
    const input_distance = try adjacent_id_distance.summary(init.gpa, &bundle.view, null);
    for (order.nodes, 0..) |node, rank| ranks[@backingInt(node)] = @intCast(rank);
    const dissection_distance = try adjacent_id_distance.summary(init.gpa, &bundle.view, ranks);
    const dissection_hash = orderHash(order);
    const leaf_timer = io.Timer.start();
    try partition.orderRanges(&bundle.view, order, options);
    const leaf_elapsed = leaf_timer.read();
    for (order.nodes, 0..) |node, rank| ranks[@backingInt(node)] = @intCast(rank);
    const partition_distance = try adjacent_id_distance.summary(init.gpa, &bundle.view, ranks);

    var levels: std.ArrayList(Level) = .empty;
    defer levels.deinit(a);
    if (order.cells.len != 0) try measureLevels(0, order.cells, &levels, 0, a);
    var buffer: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    try std.json.Stringify.value(.{
        .platform = @tagName(builtin.os.tag),
        .architecture = @tagName(builtin.cpu.arch),
        .dataset_uuid = std.fmt.bytesToHex(bundle.view.dataset_uuid, .lower),
        .nodes = order.nodes.len,
        .directed_edges = bundle.view.edges.len,
        .threads = options.threads,
        .leaf_edges = options.leaf_edges,
        .max_side_percent = options.max_side_percent,
        .max_link_gap = options.max_link_gap,
        .elapsed_ns = elapsed,
        .leaf_order_ns = leaf_elapsed,
        .input_median_adjacent_id_distance = input_distance.median,
        .dissection_median_adjacent_id_distance = dissection_distance.median,
        .partition_median_adjacent_id_distance = partition_distance.median,
        .input_adjacent_id_distance = input_distance,
        .dissection_adjacent_id_distance = dissection_distance,
        .partition_adjacent_id_distance = partition_distance,
        .top_level_separator_nodes = if (levels.items.len == 0) 0 else levels.items[0].separator_nodes,
        .dissection_order_and_tree_xxh3 = std.fmt.hex(dissection_hash),
        .order_and_tree_xxh3 = std.fmt.hex(orderHash(order)),
        .levels = levels.items,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn orderHash(order: partition.Order) u64 {
    var hash = std.hash.XxHash3.init(0);
    hash.update(std.mem.sliceAsBytes(order.nodes));
    hash.update(std.mem.sliceAsBytes(order.cells));
    return hash.final();
}
