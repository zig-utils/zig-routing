//! Sparse mode masks for movements that need more than a turn-table bit.
const std = @import("std");

pub const Entry = extern struct {
    incoming: u32,
    outgoing: u32,
    attr: packed struct(u32) {
        modes: u16,
        reserved: u16 = 0,
    },

    pub fn key(self: Entry) u64 {
        return movementKey(self.incoming, self.outgoing);
    }
};

fn movementKey(incoming: u32, outgoing: u32) u64 {
    return (@as(u64, incoming) << 32) | outgoing;
}

pub fn modes(entries: []const Entry, incoming: u32, outgoing: u32) u16 {
    const target = movementKey(incoming, outgoing);
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = entries[mid];
        const key = entry.key();
        if (key == target) return entry.attr.modes;
        if (key < target) low = mid + 1 else high = mid;
    }
    return 0;
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Entry) == 12 and @offsetOf(Entry, "incoming") == 0 and
        @offsetOf(Entry, "outgoing") == 4 and @offsetOf(Entry, "attr") == 8);
}
