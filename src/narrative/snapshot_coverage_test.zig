const std = @import("std");
const fixtures = @import("instruction_fixtures.zig");
const junctions = @import("junction_fixtures.zig");

test "snapshot inventory accounts for every pinned narrative TEST" {
    const t = std.testing;
    try t.expectEqual(201, fixtures.pinned_narrative_count);
    try t.expectEqual(26, fixtures.deferred_transit.len);
    try t.expectEqual(fixtures.pinned_narrative_build_count, fixtures.visual.len);
    try t.expectEqual(66, fixtures.post.len);
    try t.expectEqual(10, fixtures.approach.len);
    try t.expectEqual(3, fixtures.multi_cue.len);
    try t.expectEqual(102, countSignedTrials());
    const direct_tests = fixtures.signed_ramps_and_exits.len + 3;
    try t.expectEqual(fixtures.pinned_narrative_count, fixtures.visual.len + direct_tests + fixtures.deferred_transit.len);

    var disabled: usize = 0;
    var unique: std.StringHashMap(void) = .init(t.allocator);
    defer unique.deinit();
    for (fixtures.visual) |fixture| {
        try unique.putNoClobber(fixture.name, {});
        if (fixture.upstream_disabled) disabled += 1;
    }
    for (fixtures.signed_ramps_and_exits) |fixture| try unique.putNoClobber(fixture.name, {});
    for (fixtures.deferred_transit) |name| try unique.putNoClobber(name, {});
    try t.expectEqual(1, disabled);
}

fn countSignedTrials() usize {
    var count: usize = 0;
    for (fixtures.signed_ramps_and_exits) |fixture| count += fixture.steps.len;
    return count;
}

test "snapshot inventory accounts for every pinned maneuver TEST" {
    const other = [_][]const u8{
        "TestSetSimpleDirectionalManeuverType",
        "TestDetermineCardinalDirection",
        "TestDetermineRelativeDirection_Maneuver",
        "TestDetermineRelativeDirection",
        "TestSimpleRightTurnChannelCombine",
        "TestCountAndSortExitSigns",
        "TestPathRightXStraightIsIntersectingForwardEdge",
        "TestPathLeftXStraightIsIntersectingForwardEdge",
        "TestPathSlightRightXSlightLeftIsIntersectingForwardEdge",
        "TestCombineRoundaboutManeuvers",
        "TestUnCollapseRoundaboutManeuvers",
    };
    const t = std.testing;
    try t.expectEqual(19, fixtures.pinned_maneuver_cases.len);
    var covered: std.StringHashMap(void) = .init(t.allocator);
    defer covered.deinit();
    for (other) |name| try covered.putNoClobber(name, {});
    for (junctions.combine_cases) |fixture| try covered.putNoClobber(fixture.name, {});
    try t.expectEqual(fixtures.pinned_maneuver_cases.len, covered.count());
    for (fixtures.pinned_maneuver_cases) |name| try t.expect(covered.remove(name));
    try t.expectEqual(0, covered.count());
}
