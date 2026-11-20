// Ported from test/narrativebuilder.cc (Valhalla 3.9.3).
const trip = @import("../api/trip.zig");
const Maneuver = @import("maneuver.zig").Maneuver;

pub const Step = struct { maneuver: Maneuver, text: []const u8 };
pub const Case = struct {
    name: []const u8,
    language: []const u8 = "en-US",
    destination: trip.Location = .{},
    steps: []const Step,
};

pub const visual = [_]Case{
    .{
        .name = "TestBuildStartInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kTransit }, .text = "Head east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kTransit }, .text = "Head east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kTransit }, .text = "Head south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kDrive }, .text = "Drive east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kDrive }, .text = "Drive east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_9_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kDrive }, .text = "Drive south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kPedestrian }, .text = "Walk east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_11_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kPedestrian }, .text = "Walk east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_13_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_13_unnamed_walkway_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kSouthWest, .trail_type = .unnamed_walkway, .travel_mode = .kPedestrian }, .text = "Walk southwest on the walkway." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_13_pedestrian_crossing_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kSouthWest, .trail_type = .unnamed_walkway, .travel_mode = .kPedestrian, .pedestrian_crossing = true }, .text = "Walk southwest on the crosswalk." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kPedestrian }, .text = "Walk south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_15_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kBicycle }, .text = "Bike east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_16_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kBicycle }, .text = "Bike east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_17_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_18_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_18_unnamed_cycleway_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .trail_type = .unnamed_cycleway, .travel_mode = .kBicycle }, .text = "Bike east on the cycleway." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_18_unnamed_mountain_bike_trail_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kWest, .trail_type = .unnamed_mtb_trail, .travel_mode = .kBicycle }, .text = "Bike west on the mountain bike trail." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_19_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kBicycle }, .text = "Bike south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_0_kilometers_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kTransit }, .text = "Head east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_1_kilometers_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .begin_cardinal_direction = .kEast, .travel_mode = .kTransit }, .text = "Head east." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_2_kilometers_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_3_kilometers_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 5th Avenue." },
        },
    },
    .{
        .name = "TestBuildStartInstructions_4_kilometers_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kTransit }, .text = "Head south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272." },
        },
    },
    .{
        .name = "TestBuildDestinationInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kDestination }, .text = "You have arrived at your destination." },
        },
    },
    .{
        .name = "TestBuildDestinationInstructions_1_miles_en_US",
        .destination = .{ .street = "3206 Powelton Avenue" },
        .steps = &.{
            .{ .maneuver = .{ .type = .kDestination }, .text = "You have arrived at 3206 Powelton Avenue." },
        },
    },
    .{
        .name = "TestBuildDestinationInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kDestinationRight }, .text = "Your destination is on the right." },
        },
    },
    .{
        .name = "TestBuildDestinationInstructions_3_miles_en_US",
        .destination = .{ .name = "Lancaster Brewing Company" },
        .steps = &.{
            .{ .maneuver = .{ .type = .kDestinationLeft }, .text = "Lancaster Brewing Company is on the left." },
        },
    },
    .{
        .name = "TestBuildBecomesInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSlightRight, .street_names = &.{.{ .value = "Vine Street", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Bear right onto Vine Street." },
            .{ .maneuver = .{ .type = .kBecomes, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Vine Street becomes Middletown Road." },
        },
    },
    .{
        .name = "TestBuildContinueInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kContinue, .begin_relative_direction = .keep_straight }, .text = "Continue." },
        },
    },
    .{
        .name = "TestBuildContinueInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kContinue, .begin_relative_direction = .keep_straight }, .text = "Continue." },
        },
    },
    .{
        .name = "TestBuildContinueInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kContinue, .street_names = &.{.{ .value = "10th Avenue", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Continue on 10th Avenue." },
        },
    },
    .{
        .name = "TestBuildContinueInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kContinue, .street_names = &.{.{ .value = "10th Avenue", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Continue on 10th Avenue." },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .begin_relative_direction = .left }, .text = "Turn left." },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Turn left onto Middletown Road." },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_1_miles_cs_CZ",
        .language = "cs-CZ",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Odbočte vlevo na Middletown Road." },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_1_miles_de_DE",
        .language = "de-DE",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Links auf Middletown Road abbiegen." },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_1_miles_it_IT",
        .language = "it-IT",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Svolta a sinistra su Middletown Road." },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .street_names = &.{.{ .value = "MD 924", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "North Bond Street", .is_route_number = false }, .{ .value = "US 1 Business", .is_route_number = true }, .{ .value = "MD 924", .is_route_number = true } }, .begin_relative_direction = .left }, .text = "Turn left onto North Bond Street/US 1 Business/MD 924. Continue on MD 924." },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRight, .street_names = &.{.{ .value = "Sunstone Drive", .is_route_number = false }}, .begin_relative_direction = .right }, .text = "Turn right onto Sunstone Drive." },
            .{ .maneuver = .{ .type = .kRight, .street_names = &.{.{ .value = "Sunstone Drive", .is_route_number = false }}, .begin_relative_direction = .right, .to_stay_on = true }, .text = "Turn right to stay on Sunstone Drive." },
        },
    },
    .{
        .name = "TestBuildSharpInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSharpLeft, .begin_relative_direction = .left }, .text = "Make a sharp left." },
        },
    },
    .{
        .name = "TestBuildSharpInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSharpRight, .street_names = &.{.{ .value = "Flatbush Avenue", .is_route_number = false }}, .begin_relative_direction = .right }, .text = "Make a sharp right onto Flatbush Avenue." },
        },
    },
    .{
        .name = "TestBuildSharpInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSharpLeft, .street_names = &.{.{ .value = "MD 924", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "North Bond Street", .is_route_number = false }, .{ .value = "US 1 Business", .is_route_number = true }, .{ .value = "MD 924", .is_route_number = true } }, .begin_relative_direction = .left }, .text = "Make a sharp left onto North Bond Street/US 1 Business/MD 924. Continue on MD 924." },
        },
    },
    .{
        .name = "TestBuildBearInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSlightRight, .begin_relative_direction = .right }, .text = "Bear right." },
        },
    },
    .{
        .name = "TestBuildBearInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSlightLeft, .street_names = &.{.{ .value = "Arlen Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Bear left onto Arlen Road." },
        },
    },
    .{
        .name = "TestBuildBearInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSlightRight, .street_names = &.{.{ .value = "US 1 Business", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Belair Road", .is_route_number = false }, .{ .value = "US 1 Business", .is_route_number = true } }, .begin_relative_direction = .keep_right }, .text = "Bear right onto Belair Road/US 1 Business. Continue on US 1 Business." },
        },
    },
    .{
        .name = "TestBuildBearInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutExit, .street_names = &.{.{ .value = "US 15", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Catoctin Mountain Highway", .is_route_number = false }, .{ .value = "US 15", .is_route_number = true } }, .begin_relative_direction = .right }, .text = "Exit the roundabout onto Catoctin Mountain Highway/US 15. Continue on US 15." },
            .{ .maneuver = .{ .type = .kSlightLeft, .street_names = &.{.{ .value = "US 15 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .to_stay_on = true }, .text = "Bear left to stay on US 15 South." },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kUturnLeft, .begin_relative_direction = .reverse }, .text = "Make a left U-turn." },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kUturnRight, .street_names = &.{.{ .value = "Bunker Hill Road", .is_route_number = false }}, .begin_relative_direction = .reverse }, .text = "Make a right U-turn onto Bunker Hill Road." },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRight, .street_names = &.{.{ .value = "Bunker Hill Road", .is_route_number = false }}, .begin_relative_direction = .right }, .text = "Turn right onto Bunker Hill Road." },
            .{ .maneuver = .{ .type = .kUturnLeft, .street_names = &.{.{ .value = "Bunker Hill Road", .is_route_number = false }}, .begin_relative_direction = .reverse, .to_stay_on = true }, .text = "Make a left U-turn to stay on Bunker Hill Road." },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kUturnLeft, .cross_street_names = &.{.{ .value = "Devonshire Road", .is_route_number = false }}, .begin_relative_direction = .reverse }, .text = "Make a left U-turn at Devonshire Road." },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kUturnLeft, .street_names = &.{ .{ .value = "Jonestown Road", .is_route_number = false }, .{ .value = "US 22", .is_route_number = true } }, .cross_street_names = &.{.{ .value = "Devonshire Road", .is_route_number = false }}, .begin_relative_direction = .reverse }, .text = "Make a left U-turn at Devonshire Road onto Jonestown Road/US 22." },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .street_names = &.{ .{ .value = "Jonestown Road", .is_route_number = false }, .{ .value = "US 22", .is_route_number = true } }, .begin_cardinal_direction = .kNorthEast }, .text = "Drive northeast on Jonestown Road/US 22." },
            .{ .maneuver = .{ .type = .kUturnLeft, .street_names = &.{ .{ .value = "Jonestown Road", .is_route_number = false }, .{ .value = "US 22", .is_route_number = true } }, .cross_street_names = &.{.{ .value = "Devonshire Road", .is_route_number = false }}, .begin_relative_direction = .reverse, .to_stay_on = true }, .text = "Make a left U-turn at Devonshire Road to stay on Jonestown Road/US 22." },
        },
    },
    .{
        .name = "TestBuildRampStraight_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .ramp = true }, .text = "Stay straight to take the ramp." },
        },
    },
    .{
        .name = "TestBuildRampStraight_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 East", .is_route_number = true, .consecutive_count = 1 }} } }, .text = "Stay straight to take the US 322 East ramp." },
        },
    },
    .{
        .name = "TestBuildRampStraight_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "Hershey" }} } }, .text = "Stay straight to take the ramp toward Hershey." },
        },
    },
    .{
        .name = "TestBuildRampStraight_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .ramp = true, .signs = .{ .exit_onto_streets = &.{ .{ .text = "US 322 East", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 422 East", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 522 East", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 622 East", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 722 East", .is_route_number = true, .consecutive_count = 1 } }, .exit_toward_locations = &.{ .{ .text = "Hershey", .consecutive_count = 1 }, .{ .text = "Palmdale", .consecutive_count = 1 }, .{ .text = "Palmyra", .consecutive_count = 1 }, .{ .text = "Campbelltown", .consecutive_count = 1 }, .{ .text = "Eprata", .consecutive_count = 1 } } } }, .text = "Stay straight to take the US 322 East/US 422 East/US 522 East/US 622 East ramp toward Hershey/Palmdale/Palmyra/Campbelltown." },
        },
    },
    .{
        .name = "TestBuildRampStraight_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Stay straight to take the Gettysburg Pike ramp." },
        },
    },
    .{
        .name = "TestBuildRamp_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .ramp = true, .drive_on_right = false }, .text = "Take the ramp on the right." },
        },
    },
    .{
        .name = "TestBuildRamp_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95", .is_route_number = true }} }, .drive_on_right = false }, .text = "Take the I 95 ramp on the right." },
        },
    },
    .{
        .name = "TestBuildRamp_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .street_names = &.{ .{ .value = "NY 27 East", .is_route_number = true }, .{ .value = "South Conduit Avenue", .is_route_number = false } }, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "JFK" }} } }, .text = "Take the ramp on the left toward JFK." },
        },
    },
    .{
        .name = "TestBuildRamp_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .street_names = &.{ .{ .value = "NY 27 East", .is_route_number = true }, .{ .value = "South Conduit Avenue", .is_route_number = false } }, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "South Conduit Avenue" }}, .exit_toward_locations = &.{.{ .text = "JFK" }} } }, .text = "Take the South Conduit Avenue ramp on the left toward JFK." },
        },
    },
    .{
        .name = "TestBuildRamp_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} }, .drive_on_right = false }, .text = "Take the Gettysburg Pike ramp on the right." },
        },
    },
    .{
        .name = "TestBuildRamp_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .right, .ramp = true }, .text = "Turn right to take the ramp." },
        },
    },
    .{
        .name = "TestBuildRamp_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "PA 283 West", .is_route_number = true, .consecutive_count = 1 }} } }, .text = "Turn left to take the PA 283 West ramp." },
        },
    },
    .{
        .name = "TestBuildRamp_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .left, .ramp = true, .signs = .{ .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Harrisburg International Airport" } } } }, .text = "Turn left to take the ramp toward Harrisburg/Harrisburg International Airport." },
        },
    },
    .{
        .name = "TestBuildRamp_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "PA 283 West", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Harrisburg International Airport" } } } }, .text = "Turn left to take the PA 283 West ramp toward Harrisburg/Harrisburg International Airport." },
        },
    },
    .{
        .name = "TestBuildRamp_9_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .right, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Turn right to take the Gettysburg Pike ramp." },
        },
    },
    .{
        .name = "TestBuildRamp_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .ramp = true }, .text = "Take the ramp." },
        },
    },
    .{
        .name = "TestBuildRamp_11_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95", .is_route_number = true }} } }, .text = "Take the I 95 ramp." },
        },
    },
    .{
        .name = "TestBuildRamp_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .street_names = &.{ .{ .value = "NY 27 East", .is_route_number = true }, .{ .value = "South Conduit Avenue", .is_route_number = false } }, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "JFK" }} } }, .text = "Take the ramp toward JFK." },
        },
    },
    .{
        .name = "TestBuildRamp_13_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .street_names = &.{ .{ .value = "NY 27 East", .is_route_number = true }, .{ .value = "South Conduit Avenue", .is_route_number = false } }, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "South Conduit Avenue" }}, .exit_toward_locations = &.{.{ .text = "JFK" }} } }, .text = "Take the South Conduit Avenue ramp on the left toward JFK." },
        },
    },
    .{
        .name = "TestBuildRamp_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike ramp." },
        },
    },
    .{
        .name = "TestBuildExit_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .drive_on_right = false }, .text = "Take the exit on the right." },
        },
    },
    .{
        .name = "TestBuildExit_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }} }, .drive_on_right = false }, .text = "Take exit 67 B-A on the right." },
        },
    },
    .{
        .name = "TestBuildExit_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }} }, .drive_on_right = false }, .text = "Take the US 322 West exit on the right." },
        },
    },
    .{
        .name = "TestBuildExit_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }} }, .drive_on_right = false }, .text = "Take exit 67 B-A on the right onto US 322 West." },
        },
    },
    .{
        .name = "TestBuildExit_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} }, .drive_on_right = false }, .text = "Take the exit on the right toward Lewistown." },
        },
    },
    .{
        .name = "TestBuildExit_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} }, .drive_on_right = false }, .text = "Take exit 67 B-A on the right toward Lewistown." },
        },
    },
    .{
        .name = "TestBuildExit_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }}, .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} }, .drive_on_right = false }, .text = "Take the US 322 West exit on the right toward Lewistown." },
        },
    },
    .{
        .name = "TestBuildExit_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_onto_streets = &.{ .{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }, .{ .text = "US 22 West", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 22 East", .is_route_number = true }, .{ .text = "PA 230 East", .is_route_number = true }, .{ .text = "Cameron Street" } }, .exit_toward_locations = &.{ .{ .text = "Lewistown", .consecutive_count = 1 }, .{ .text = "State College", .consecutive_count = 1 }, .{ .text = "Harrisburg" } } }, .drive_on_right = false }, .text = "Take exit 67 B-A on the right onto US 322 West toward Lewistown/State College." },
        },
    },
    .{
        .name = "TestBuildExit_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "White Marsh Boulevard" }} } }, .text = "Take the White Marsh Boulevard exit on the left." },
        },
    },
    .{
        .name = "TestBuildExit_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "MD 43 East", .is_route_number = true, .consecutive_count = 1 }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} } }, .text = "Take the White Marsh Boulevard exit on the left onto MD 43 East." },
        },
    },
    .{
        .name = "TestBuildExit_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "White Marsh" }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} } }, .text = "Take the White Marsh Boulevard exit on the left toward White Marsh." },
        },
    },
    .{
        .name = "TestBuildExit_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "MD 43 East", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "White Marsh" }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} } }, .text = "Take the White Marsh Boulevard exit on the left onto MD 43 East toward White Marsh." },
        },
    },
    .{
        .name = "TestBuildExit_15_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true }, .text = "Take the exit." },
        },
    },
    .{
        .name = "TestBuildExit_16_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }} } }, .text = "Take exit 67 B-A." },
        },
    },
    .{
        .name = "TestBuildExit_17_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }} } }, .text = "Take the US 322 West exit." },
        },
    },
    .{
        .name = "TestBuildExit_18_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }} } }, .text = "Take exit 67 B-A onto US 322 West." },
        },
    },
    .{
        .name = "TestBuildExit_19_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} } }, .text = "Take the exit toward Lewistown." },
        },
    },
    .{
        .name = "TestBuildExit_20_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} } }, .text = "Take exit 67 B-A toward Lewistown." },
        },
    },
    .{
        .name = "TestBuildExit_21_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }}, .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} } }, .text = "Take the US 322 West exit toward Lewistown." },
        },
    },
    .{
        .name = "TestBuildExit_22_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_onto_streets = &.{ .{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }, .{ .text = "US 22 West", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 22 East", .is_route_number = true }, .{ .text = "PA 230 East", .is_route_number = true }, .{ .text = "Cameron Street" } }, .exit_toward_locations = &.{ .{ .text = "Lewistown", .consecutive_count = 1 }, .{ .text = "State College", .consecutive_count = 1 }, .{ .text = "Harrisburg" } } } }, .text = "Take exit 67 B-A onto US 322 West toward Lewistown/State College." },
        },
    },
    .{
        .name = "TestBuildExit_23_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "White Marsh Boulevard" }} }, .drive_on_right = false }, .text = "Take the White Marsh Boulevard exit." },
        },
    },
    .{
        .name = "TestBuildExit_25_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "MD 43 East", .is_route_number = true, .consecutive_count = 1 }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} }, .drive_on_right = false }, .text = "Take the White Marsh Boulevard exit onto MD 43 East." },
        },
    },
    .{
        .name = "TestBuildExit_27_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "White Marsh" }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} }, .drive_on_right = false }, .text = "Take the White Marsh Boulevard exit toward White Marsh." },
        },
    },
    .{
        .name = "TestBuildExit_29_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "MD 43 East", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "White Marsh" }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} }, .drive_on_right = false }, .text = "Take the White Marsh Boulevard exit onto MD 43 East toward White Marsh." },
        },
    },
    .{
        .name = "TestBuildKeep_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayStraight, .begin_relative_direction = .keep_straight, .ramp = true }, .text = "Keep straight at the fork." },
        },
    },
    .{
        .name = "TestBuildKeep_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "62" }} } }, .text = "Keep right to take exit 62." },
        },
    },
    .{
        .name = "TestBuildKeep_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .street_names = &.{.{ .value = "I 895 South", .is_route_number = true }}, .begin_relative_direction = .keep_right }, .text = "Keep right to take I 895 South." },
        },
    },
    .{
        .name = "TestBuildKeep_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .street_names = &.{.{ .value = "I 895 South", .is_route_number = true }}, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "62" }} } }, .text = "Keep right to take exit 62 onto I 895 South." },
        },
    },
    .{
        .name = "TestBuildKeep_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_toward_locations = &.{.{ .text = "Annapolis" }} } }, .text = "Keep right toward Annapolis." },
        },
    },
    .{
        .name = "TestBuildKeep_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "62" }}, .exit_toward_locations = &.{.{ .text = "Annapolis" }} } }, .text = "Keep right to take exit 62 toward Annapolis." },
        },
    },
    .{
        .name = "TestBuildKeep_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{ .{ .text = "I 895 South", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "Baltimore Harbor Tunnel Thruway" } }, .exit_toward_locations = &.{.{ .text = "Annapolis" }} } }, .text = "Keep right to take I 895 South toward Annapolis." },
        },
    },
    .{
        .name = "TestBuildKeep_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .street_names = &.{.{ .value = "I 895 South", .is_route_number = true }}, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "62" }}, .exit_onto_streets = &.{ .{ .text = "I 895 South", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "Baltimore Harbor Tunnel Thruway" } }, .exit_toward_locations = &.{.{ .text = "Annapolis" }} } }, .text = "Keep right to take exit 62 onto I 895 South toward Annapolis." },
        },
    },
    .{
        .name = "TestBuildKeepToStayOn_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kMerge, .street_names = &.{ .{ .value = "I 95 South", .is_route_number = true }, .{ .value = "John F. Kennedy Memorial Highway", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 95 South/John F. Kennedy Memorial Highway." },
            .{ .maneuver = .{ .type = .kStayLeft, .street_names = &.{.{ .value = "I 95 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} }, .to_stay_on = true }, .text = "Keep left to stay on I 95 South." },
        },
    },
    .{
        .name = "TestBuildKeepToStayOn_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kMerge, .street_names = &.{ .{ .value = "I 95 South", .is_route_number = true }, .{ .value = "John F. Kennedy Memorial Highway", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 95 South/John F. Kennedy Memorial Highway." },
            .{ .maneuver = .{ .type = .kStayLeft, .street_names = &.{.{ .value = "I 95 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "62" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} }, .to_stay_on = true }, .text = "Keep left to take exit 62 to stay on I 95 South." },
        },
    },
    .{
        .name = "TestBuildKeepToStayOn_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kMerge, .street_names = &.{ .{ .value = "I 95 South", .is_route_number = true }, .{ .value = "John F. Kennedy Memorial Highway", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 95 South/John F. Kennedy Memorial Highway." },
            .{ .maneuver = .{ .type = .kStayLeft, .street_names = &.{.{ .value = "I 95 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} }, .to_stay_on = true }, .text = "Keep left to stay on I 95 South toward Baltimore." },
        },
    },
    .{
        .name = "TestBuildKeepToStayOn_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kMerge, .street_names = &.{ .{ .value = "I 95 South", .is_route_number = true }, .{ .value = "John F. Kennedy Memorial Highway", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 95 South/John F. Kennedy Memorial Highway." },
            .{ .maneuver = .{ .type = .kStayLeft, .street_names = &.{.{ .value = "I 95 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "62" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} }, .to_stay_on = true }, .text = "Keep left to take exit 62 to stay on I 95 South toward Baltimore." },
        },
    },
    .{
        .name = "TestBuildMerge_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 76 West", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "Pittsburgh" }} } }, .text = "Take the I 76 West exit toward Pittsburgh." },
            .{ .maneuver = .{ .type = .kMerge, .begin_relative_direction = .keep_straight }, .text = "Merge." },
        },
    },
    .{
        .name = "TestBuildMerge_1_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 76 West", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "Pittsburgh" }} } }, .text = "Take the I 76 West exit toward Pittsburgh." },
            .{ .maneuver = .{ .type = .kMerge, .street_names = &.{ .{ .value = "I 76 West", .is_route_number = true }, .{ .value = "Pennsylvania Turnpike", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 76 West/Pennsylvania Turnpike." },
        },
    },
    .{
        .name = "TestBuildMerge_1_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 76 West", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "Pittsburgh" }} } }, .text = "Take the I 76 West exit toward Pittsburgh." },
            .{ .maneuver = .{ .type = .kMerge, .street_names = &.{ .{ .value = "I 76 West", .is_route_number = true }, .{ .value = "Pennsylvania Turnpike", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 76 West/Pennsylvania Turnpike." },
        },
    },
    .{
        .name = "TestBuildEnterRoundabout_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right }, .text = "Enter the roundabout." },
        },
    },
    .{
        .name = "TestBuildEnterRoundabout_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 1 }, .text = "Enter the roundabout and take the 1st exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 2 }, .text = "Enter the roundabout and take the 2nd exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 3 }, .text = "Enter the roundabout and take the 3rd exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 4 }, .text = "Enter the roundabout and take the 4th exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 5 }, .text = "Enter the roundabout and take the 5th exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 6 }, .text = "Enter the roundabout and take the 6th exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 7 }, .text = "Enter the roundabout and take the 7th exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 8 }, .text = "Enter the roundabout and take the 8th exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 9 }, .text = "Enter the roundabout and take the 9th exit." },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .begin_relative_direction = .right, .roundabout_exit_count = 10 }, .text = "Enter the roundabout and take the 10th exit." },
        },
    },
    .{
        .name = "TestBuildExitRoundabout_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutExit, .begin_relative_direction = .keep_straight }, .text = "Exit the roundabout." },
        },
    },
    .{
        .name = "TestBuildExitRoundabout_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutExit, .street_names = &.{ .{ .value = "Philadelphia Road", .is_route_number = false }, .{ .value = "MD 7", .is_route_number = true } }, .begin_relative_direction = .keep_straight }, .text = "Exit the roundabout onto Philadelphia Road/MD 7." },
        },
    },
    .{
        .name = "TestBuildExitRoundabout_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutExit, .street_names = &.{.{ .value = "US 15", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Catoctin Mountain Highway", .is_route_number = false }, .{ .value = "US 15", .is_route_number = true } }, .begin_relative_direction = .right }, .text = "Exit the roundabout onto Catoctin Mountain Highway/US 15. Continue on US 15." },
        },
    },
    .{
        .name = "TestBuildEnterFerry_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryEnter, .begin_relative_direction = .keep_straight }, .text = "Take the Ferry." },
        },
    },
    .{
        .name = "TestBuildEnterFerry_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryEnter, .street_names = &.{.{ .value = "Millersburg FERRY", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Take the Millersburg FERRY." },
        },
    },
    .{
        .name = "TestBuildEnterFerry_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryEnter, .street_names = &.{.{ .value = "Bridgeport - Port Jefferson", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Take the Bridgeport - Port Jefferson Ferry." },
        },
    },
    .{
        .name = "TestBuildExitFerry_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kTransit }, .text = "Head southeast." },
        },
    },
    .{
        .name = "TestBuildExitFerry_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kTransit }, .text = "Head southeast." },
        },
    },
    .{
        .name = "TestBuildExitFerry_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kTransit }, .text = "Head west on Ferry Lane." },
        },
    },
    .{
        .name = "TestBuildExitFerry_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kTransit }, .text = "Head west on Ferry Lane." },
        },
    },
    .{
        .name = "TestBuildExitFerry_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "US 9", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Cape May-Lewes Ferry Entrance", .is_route_number = false }, .{ .value = "US 9", .is_route_number = true } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kNorthEast, .travel_mode = .kTransit }, .text = "Head northeast on Cape May-Lewes Ferry Entrance/US 9. Continue on US 9." },
        },
    },
    .{
        .name = "TestBuildExitFerry_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kDrive }, .text = "Drive southeast." },
        },
    },
    .{
        .name = "TestBuildExitFerry_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kDrive }, .text = "Drive southeast." },
        },
    },
    .{
        .name = "TestBuildExitFerry_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kDrive }, .text = "Drive west on Ferry Lane." },
        },
    },
    .{
        .name = "TestBuildExitFerry_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kDrive }, .text = "Drive west on Ferry Lane." },
        },
    },
    .{
        .name = "TestBuildExitFerry_9_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "US 9", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Cape May-Lewes Ferry Entrance", .is_route_number = false }, .{ .value = "US 9", .is_route_number = true } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kNorthEast, .travel_mode = .kDrive }, .text = "Drive northeast on Cape May-Lewes Ferry Entrance/US 9. Continue on US 9." },
        },
    },
    .{
        .name = "TestBuildExitFerry_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kPedestrian }, .text = "Walk southeast." },
        },
    },
    .{
        .name = "TestBuildExitFerry_11_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kPedestrian }, .text = "Walk southeast." },
        },
    },
    .{
        .name = "TestBuildExitFerry_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kPedestrian }, .text = "Walk west on Ferry Lane." },
        },
    },
    .{
        .name = "TestBuildExitFerry_13_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kPedestrian }, .text = "Walk west on Ferry Lane." },
        },
    },
    .{
        .name = "TestBuildExitFerry_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "US 9", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Cape May-Lewes Ferry Entrance", .is_route_number = false }, .{ .value = "US 9", .is_route_number = true } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kNorthEast, .travel_mode = .kPedestrian }, .text = "Walk northeast on Cape May-Lewes Ferry Entrance/US 9. Continue on US 9." },
        },
    },
    .{
        .name = "TestBuildExitFerry_15_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kBicycle }, .text = "Bike southeast." },
        },
    },
    .{
        .name = "TestBuildExitFerry_16_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kBicycle }, .text = "Bike southeast." },
        },
    },
    .{
        .name = "TestBuildExitFerry_17_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kBicycle }, .text = "Bike west on Ferry Lane." },
        },
    },
    .{
        .name = "TestBuildExitFerry_18_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kBicycle }, .text = "Bike west on Ferry Lane." },
        },
    },
    .{
        .name = "TestBuildExitFerry_19_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .street_names = &.{.{ .value = "US 9", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Cape May-Lewes Ferry Entrance", .is_route_number = false }, .{ .value = "US 9", .is_route_number = true } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kNorthEast, .travel_mode = .kBicycle }, .text = "Bike northeast on Cape May-Lewes Ferry Entrance/US 9. Continue on US 9." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 6th Avenue/Avenue of the Americas." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 6th Avenue/Avenue of the Americas." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{.{ .value = "6th Avenue", .is_route_number = false }}, .begin_street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 6th Avenue/Avenue of the Americas. Continue on 6th Avenue." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest on 6th Avenue/Avenue of the Americas." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest on 6th Avenue/Avenue of the Americas." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_9_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{.{ .value = "6th Avenue", .is_route_number = false }}, .begin_street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest on 6th Avenue/Avenue of the Americas. Continue on 6th Avenue." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_11_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest on 6th Avenue/Avenue of the Americas." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_13_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest on 6th Avenue/Avenue of the Americas." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{.{ .value = "6th Avenue", .is_route_number = false }}, .begin_street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest on 6th Avenue/Avenue of the Americas. Continue on 6th Avenue." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_15_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_16_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_17_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest on 6th Avenue/Avenue of the Americas." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_18_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest on 6th Avenue/Avenue of the Americas." },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_19_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .street_names = &.{.{ .value = "6th Avenue", .is_route_number = false }}, .begin_street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest on 6th Avenue/Avenue of the Americas. Continue on 6th Avenue." },
        },
    },
    .{
        .name = "TestBuildVerbalMultiCue_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .street_names = &.{.{ .value = "North Plum Street", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Turn left onto North Plum Street." },
            .{ .maneuver = .{ .type = .kLeft, .street_names = &.{.{ .value = "East Fulton Street", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Turn left onto East Fulton Street." },
        },
    },
};

pub const signed_ramps_and_exits = [_]Case{
    .{
        .name = "TestFormRampStraightInstruction",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight }, .text = "Stay straight to take the ramp." },
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Stay straight to take the I 95 South ramp." },
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Stay straight to take the I 95 South ramp." },
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Stay straight to take the ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Stay straight to take the ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Stay straight to take the I 95 South ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Stay straight to take the I 95 South ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampStraight, .begin_relative_direction = .keep_straight, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Stay straight to take the Gettysburg Pike ramp." },
        },
    },
    .{
        .name = "TestFormRampRightInstruction",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .drive_on_right = false }, .text = "Take the ramp on the right." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take the I 95 South ramp on the right." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the I 95 South ramp on the right." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the ramp on the right toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the ramp on the right toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the I 95 South ramp on the right toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the I 95 South ramp on the right toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike ramp on the right." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .right }, .text = "Turn right to take the ramp." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .right, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Turn right to take the I 95 South ramp." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .right, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Turn right to take the ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .right, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Turn right to take the I 95 South ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .right, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Turn right to take the Gettysburg Pike ramp." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right }, .text = "Take the ramp." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take the I 95 South ramp." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the I 95 South ramp." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the I 95 South ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the I 95 South ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike ramp." },
        },
    },
    .{
        .name = "TestFormRampLeftInstruction",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left }, .text = "Take the ramp on the left." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take the I 95 South ramp on the left." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the I 95 South ramp on the left." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the ramp on the left toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the ramp on the left toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the I 95 South ramp on the left toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the I 95 South ramp on the left toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike ramp on the left." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .left }, .text = "Turn left to take the ramp." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Turn left to take the I 95 South ramp." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .left, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Turn left to take the ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Turn left to take the I 95 South ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .left, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Turn left to take the Gettysburg Pike ramp." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .drive_on_right = false }, .text = "Take the ramp." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take the I 95 South ramp." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the I 95 South ramp." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the I 95 South ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the I 95 South ramp toward Baltimore." },
            .{ .maneuver = .{ .type = .kRampLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike ramp." },
        },
    },
    .{
        .name = "TestFormExitRightInstruction",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false }, .text = "Take the exit on the right." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }} } }, .text = "Take exit 67A on the right." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take exit 67A on the right." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take the I 95 South exit on the right." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take exit 67A on the right onto I 95 South." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the exit on the right toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take exit 67A on the right toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the I 95 South exit on the right toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take exit 67A on the right onto I 95 South toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit on the right." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 15", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit on the right onto US 15." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Gettysburg" } }, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit on the right toward Harrisburg/Gettysburg." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 15", .is_route_number = true }}, .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Gettysburg" } }, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit on the right onto US 15 toward Harrisburg/Gettysburg." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right }, .text = "Take the exit." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }} } }, .text = "Take exit 67A." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take exit 67A." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take the I 95 South exit." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take exit 67A onto I 95 South." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the exit toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take exit 67A toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the I 95 South exit toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take exit 67A onto I 95 South toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 15", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit onto US 15." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Gettysburg" } }, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit toward Harrisburg/Gettysburg." },
            .{ .maneuver = .{ .type = .kExitRight, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 15", .is_route_number = true }}, .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Gettysburg" } }, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit onto US 15 toward Harrisburg/Gettysburg." },
        },
    },
    .{
        .name = "TestFormExitLeftInstruction",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left }, .text = "Take the exit on the left." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }} } }, .text = "Take exit 67A on the left." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take exit 67A on the left." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take the I 95 South exit on the left." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take exit 67A on the left onto I 95 South." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the exit on the left toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take exit 67A on the left toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the I 95 South exit on the left toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take exit 67A on the left onto I 95 South toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit on the left." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 15", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit on the left onto US 15." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Gettysburg" } }, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit on the left toward Harrisburg/Gettysburg." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 15", .is_route_number = true }}, .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Gettysburg" } }, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit on the left onto US 15 toward Harrisburg/Gettysburg." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false }, .text = "Take the exit." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }} } }, .text = "Take exit 67A." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take exit 67A." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take the I 95 South exit." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} } }, .text = "Take exit 67A onto I 95 South." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the exit toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take exit 67A toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take the I 95 South exit toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_numbers = &.{.{ .text = "67A" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} } }, .text = "Take exit 67A onto I 95 South toward Baltimore." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 15", .is_route_number = true }}, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit onto US 15." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Gettysburg" } }, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit toward Harrisburg/Gettysburg." },
            .{ .maneuver = .{ .type = .kExitLeft, .begin_relative_direction = .keep_left, .drive_on_right = false, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 15", .is_route_number = true }}, .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Gettysburg" } }, .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike exit onto US 15 toward Harrisburg/Gettysburg." },
        },
    },
};
