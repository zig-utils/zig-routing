// Ported from valhalla/mjolnir/osmway.h and valhalla/mjolnir/osmnode.h
// (Valhalla 3.9.3). Name and sign refs borrow source strings until interning.

const attr = @import("../../graph/constants.zig");

pub const Names = struct {
    name: ?[]const u8 = null,
    alt_name: ?[]const u8 = null,
    official_name: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    int_ref: ?[]const u8 = null,
    direction: ?[]const u8 = null,
    int_direction: ?[]const u8 = null,
    tunnel_name: ?[]const u8 = null,
    bridge_name: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    destination_forward: ?[]const u8 = null,
    destination_backward: ?[]const u8 = null,
    destination_ref: ?[]const u8 = null,
    destination_ref_to: ?[]const u8 = null,
    destination_street: ?[]const u8 = null,
    destination_street_to: ?[]const u8 = null,
    destination_int_ref: ?[]const u8 = null,
    destination_int_ref_to: ?[]const u8 = null,
    junction_ref: ?[]const u8 = null,
    junction_name: ?[]const u8 = null,
};

pub const WayAttrs = struct {
    road_class: attr.RoadClass = .service_other,
    use: attr.Use = .road,
    surface: attr.Surface = .paved,
    forward_access: attr.AccessMask = .{},
    backward_access: attr.AccessMask = .{},
    speed: u8 = 0,
    speed_limit: u8 = 0,
    forward_speed: u8 = 0,
    backward_speed: u8 = 0,
    truck_speed: u8 = 0,
    /// The implicit limit label, such as DE:urban. It borrows the input.
    speed_zone: ?[]const u8 = null,
    lanes: u4 = 0,
    forward_lanes: u4 = 0,
    backward_lanes: u4 = 0,
    flags: Flags = .{},
    names: Names = .{},
    turn_lanes: TurnLanes = .{},

    pub const TurnLanes = struct {
        general: ?[]const u8 = null,
        forward: ?[]const u8 = null,
        backward: ?[]const u8 = null,
    };

    pub fn speedType(self: WayAttrs) attr.SpeedType {
        return if (self.flags.tagged_speed or self.flags.forward_tagged_speed or self.flags.backward_tagged_speed)
            .tagged
        else
            .classified;
    }

    /// Ferry flags override the parsed use when constructing directed edges.
    pub fn edgeUse(self: WayAttrs) attr.Use {
        if (self.use != .construction) {
            if (self.flags.rail) return .rail_ferry;
            if (self.flags.ferry) return .ferry;
        }
        return self.use;
    }

    pub const Flags = packed struct(u32) {
        oneway: bool = false,
        oneway_reverse: bool = false,
        roundabout: bool = false,
        link: bool = false,
        /// Explicit candidate before graph-level turn channel inference.
        turn_channel: bool = false,
        ferry: bool = false,
        rail: bool = false,
        pedestrian_area: bool = false,
        bridge: bool = false,
        tunnel: bool = false,
        lit: bool = false,
        indoor: bool = false,
        destination_only: bool = false,
        no_thru_traffic: bool = false,
        tagged_speed: bool = false,
        forward_tagged_speed: bool = false,
        backward_tagged_speed: bool = false,
        tagged_lanes: bool = false,
        forward_tagged_lanes: bool = false,
        backward_tagged_lanes: bool = false,
        wheelchair: bool = false,
        wheelchair_tag: bool = false,
        sidewalk_left: bool = false,
        sidewalk_right: bool = false,
        shoulder_left: bool = false,
        shoulder_right: bool = false,
        tagged_internal_intersection: bool = false,
        destination_only_hgv: bool = false,
        reserved: u4 = 0,
    };
};

pub const NodeAttrs = struct {
    type: attr.NodeType = .street_intersection,
    access: attr.AccessMask = attr.AccessMask.all_tag_modes,
    flags: Flags = .{},
    name: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    exit_to: ?[]const u8 = null,

    pub const Flags = packed struct(u16) {
        named_intersection: bool = false,
        traffic_signal: bool = false,
        forward_signal: bool = false,
        backward_signal: bool = false,
        stop_sign: bool = false,
        forward_stop: bool = false,
        backward_stop: bool = false,
        yield_sign: bool = false,
        forward_yield: bool = false,
        backward_yield: bool = false,
        minor: bool = false,
        direction: bool = false,
        tagged_access: bool = false,
        private_access: bool = false,
        reserved: u2 = 0,
    };
};
