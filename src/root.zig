//! zig-routing: a faithful, faster Zig port of the Valhalla routing engine.
//!
//! Modules land here as their issues are completed. The module map
//! (upstream Valhalla module in parentheses) is:
//!
//!   geo (midgard), graph (baldr), costing (sif), snap (loki), search (thor),
//!   accel (new), match (meili), narrative (odin), api (tyr), elevation (skadi),
//!   build (mjolnir), server (prime_server), traffic, tiles, geocode, cli.
//!
//! See docs/PLAN.md and AGENTS.md.

const std = @import("std");

pub const version = "0.0.0";

test "version is set" {
    try std.testing.expect(version.len > 0);
}
