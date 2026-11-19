const graph = @import("../graph/root.zig");
const EdgeId = graph.format.EdgeId;

pub const DirectedEdge = struct {
    graph_view: *const graph.reader.View,
    id: EdgeId,
    hot: *const graph.format.EdgeHot,
    class: *const graph.class_table.EdgeClass,
    reverse: bool,

    pub fn read(view: *const graph.reader.View, id: EdgeId) !DirectedEdge {
        const hot = try view.edge(id);
        return .{
            .graph_view = view,
            .id = id,
            .hot = hot,
            .class = try view.class(hot.cls.class_id),
            .reverse = if (view.cold_idx) |index| index[@backingInt(id)] >> 31 != 0 else false,
        };
    }
};
