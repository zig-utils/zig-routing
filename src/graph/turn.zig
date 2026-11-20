// Ported from src/baldr/turn.cc and src/midgard/util.cc (Valhalla 3.9.3).

pub const Type = enum(u3) {
    straight,
    slight_right,
    right,
    sharp_right,
    reverse,
    sharp_left,
    left,
    slight_left,
};

pub fn classify(degrees: u32) Type {
    return switch (degrees % 360) {
        0...10, 350...359 => .straight,
        11...44 => .slight_right,
        45...135 => .right,
        136...159 => .sharp_right,
        160...200 => .reverse,
        201...224 => .sharp_left,
        225...315 => .left,
        316...349 => .slight_left,
        else => unreachable,
    };
}

pub fn degree(from: u32, to: u32) u32 {
    return (to % 360 + 360 - from % 360) % 360;
}

pub fn delta(from: u32, to: u32) u32 {
    const clockwise = degree(from, to);
    return @min(clockwise, 360 - clockwise);
}
