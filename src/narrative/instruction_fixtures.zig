// Ported from test/narrativebuilder.cc (Valhalla 3.9.3).
const trip = @import("../api/trip.zig");
const request = @import("../api/request.zig");
const Maneuver = @import("maneuver.zig").Maneuver;

pub const Speech = struct { succinct: []const u8 = "", alert: []const u8 = "", pre: []const u8 = "", post: []const u8 = "" };
pub const Step = struct { maneuver: Maneuver, text: []const u8, speech: Speech = .{} };
pub const Case = struct {
    name: []const u8,
    language: []const u8 = "en-US",
    units: request.Units = .miles,
    destination: trip.Location = .{},
    steps: []const Step,
};

pub const visual = [_]Case{
    .{
        .name = "TestBuildStartInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kTransit }, .text = "Head east.", .speech = .{ .succinct = "Head east.", .pre = "Head east.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kTransit, .include_verbal_pre_transition_length = true }, .text = "Head east.", .speech = .{ .succinct = "Head east for a half mile.", .pre = "Head east for a half mile.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 5th Avenue.", .speech = .{ .succinct = "Head southwest.", .pre = "Head southwest on 5th Avenue.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit, .include_verbal_pre_transition_length = true }, .text = "Head southwest on 5th Avenue.", .speech = .{ .succinct = "Head southwest for 700 feet.", .pre = "Head southwest on 5th Avenue for 700 feet.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 5.098166, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kTransit }, .text = "Head south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272.", .speech = .{ .succinct = "Head south.", .pre = "Head south on North Prince Street, U.S. 2 22.", .post = "Continue on U.S. 2 22, Pennsylvania 2 72 for 3 miles." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kDrive }, .text = "Drive east.", .speech = .{ .succinct = "Drive east.", .pre = "Drive east.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kDrive, .include_verbal_pre_transition_length = true }, .text = "Drive east.", .speech = .{ .succinct = "Drive east for a half mile.", .pre = "Drive east for a half mile.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest on 5th Avenue.", .speech = .{ .succinct = "Drive southwest.", .pre = "Drive southwest on 5th Avenue.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive, .include_verbal_pre_transition_length = true }, .text = "Drive southwest on 5th Avenue.", .speech = .{ .succinct = "Drive southwest for 700 feet.", .pre = "Drive southwest on 5th Avenue for 700 feet.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_9_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 5.098166, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kDrive }, .text = "Drive south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272.", .speech = .{ .succinct = "Drive south.", .pre = "Drive south on North Prince Street, U.S. 2 22.", .post = "Continue on U.S. 2 22, Pennsylvania 2 72 for 3 miles." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kPedestrian }, .text = "Walk east.", .speech = .{ .succinct = "Walk east.", .pre = "Walk east.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_11_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kPedestrian, .include_verbal_pre_transition_length = true }, .text = "Walk east.", .speech = .{ .succinct = "Walk east for a half mile.", .pre = "Walk east for a half mile.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest on 5th Avenue.", .speech = .{ .succinct = "Walk southwest.", .pre = "Walk southwest on 5th Avenue.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_13_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian, .include_verbal_pre_transition_length = true }, .text = "Walk southwest on 5th Avenue.", .speech = .{ .succinct = "Walk southwest for 700 feet.", .pre = "Walk southwest on 5th Avenue for 700 feet.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_13_unnamed_walkway_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.050737, .basic_time = 36, .begin_cardinal_direction = .kSouthWest, .trail_type = .unnamed_walkway, .travel_mode = .kPedestrian, .include_verbal_pre_transition_length = true }, .text = "Walk southwest on the walkway.", .speech = .{ .succinct = "Walk southwest for 200 feet.", .pre = "Walk southwest on the walkway for 200 feet.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_13_pedestrian_crossing_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.050737, .basic_time = 36, .begin_cardinal_direction = .kSouthWest, .trail_type = .unnamed_walkway, .travel_mode = .kPedestrian, .pedestrian_crossing = true, .include_verbal_pre_transition_length = true }, .text = "Walk southwest on the crosswalk.", .speech = .{ .succinct = "Walk southwest for 200 feet.", .pre = "Walk southwest on the crosswalk for 200 feet.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 5.098166, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kPedestrian }, .text = "Walk south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272.", .speech = .{ .succinct = "Walk south.", .pre = "Walk south on North Prince Street, U.S. 2 22.", .post = "Continue on U.S. 2 22, Pennsylvania 2 72 for 3 miles." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_15_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kBicycle }, .text = "Bike east.", .speech = .{ .succinct = "Bike east.", .pre = "Bike east.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_16_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kBicycle, .include_verbal_pre_transition_length = true }, .text = "Bike east.", .speech = .{ .succinct = "Bike east for a half mile.", .pre = "Bike east for a half mile.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_17_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest on 5th Avenue.", .speech = .{ .succinct = "Bike southwest.", .pre = "Bike southwest on 5th Avenue.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_18_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle, .include_verbal_pre_transition_length = true }, .text = "Bike southwest on 5th Avenue.", .speech = .{ .succinct = "Bike southwest for 700 feet.", .pre = "Bike southwest on 5th Avenue for 700 feet.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_18_unnamed_cycleway_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 2.675882, .basic_time = 482, .begin_cardinal_direction = .kEast, .trail_type = .unnamed_cycleway, .travel_mode = .kBicycle, .include_verbal_pre_transition_length = true }, .text = "Bike east on the cycleway.", .speech = .{ .succinct = "Bike east for 1.5 miles.", .pre = "Bike east on the cycleway for 1.5 miles.", .post = "Continue for 1.5 miles." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_18_unnamed_mountain_bike_trail_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.200000, .basic_time = 36, .begin_cardinal_direction = .kWest, .trail_type = .unnamed_mtb_trail, .travel_mode = .kBicycle, .include_verbal_pre_transition_length = true }, .text = "Bike west on the mountain bike trail.", .speech = .{ .succinct = "Bike west for 700 feet.", .pre = "Bike west on the mountain bike trail for 700 feet.", .post = "Continue for 700 feet." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_19_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 5.098166, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kBicycle }, .text = "Bike south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272.", .speech = .{ .succinct = "Bike south.", .pre = "Bike south on North Prince Street, U.S. 2 22.", .post = "Continue on U.S. 2 22, Pennsylvania 2 72 for 3 miles." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_0_kilometers_en_US",
        .units = .kilometers,
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kTransit }, .text = "Head east.", .speech = .{ .succinct = "Head east.", .pre = "Head east.", .post = "Continue for 800 meters." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_1_kilometers_en_US",
        .units = .kilometers,
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.786592, .begin_cardinal_direction = .kEast, .travel_mode = .kTransit, .include_verbal_pre_transition_length = true }, .text = "Head east.", .speech = .{ .succinct = "Head east for 800 meters.", .pre = "Head east for 800 meters.", .post = "Continue for 800 meters." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_2_kilometers_en_US",
        .units = .kilometers,
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 5th Avenue.", .speech = .{ .succinct = "Head southwest.", .pre = "Head southwest on 5th Avenue.", .post = "Continue for 200 meters." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_3_kilometers_en_US",
        .units = .kilometers,
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.224001, .street_names = &.{.{ .value = "5th Avenue", .is_route_number = false }}, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit, .include_verbal_pre_transition_length = true }, .text = "Head southwest on 5th Avenue.", .speech = .{ .succinct = "Head southwest for 200 meters.", .pre = "Head southwest on 5th Avenue for 200 meters.", .post = "Continue for 200 meters." } },
        },
    },
    .{
        .name = "TestBuildStartInstructions_4_kilometers_en_US",
        .units = .kilometers,
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 5.098166, .street_names = &.{ .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_street_names = &.{ .{ .value = "North Prince Street", .is_route_number = false }, .{ .value = "US 222", .is_route_number = true }, .{ .value = "PA 272", .is_route_number = true } }, .begin_cardinal_direction = .kSouth, .travel_mode = .kTransit }, .text = "Head south on North Prince Street/US 222/PA 272. Continue on US 222/PA 272.", .speech = .{ .succinct = "Head south.", .pre = "Head south on North Prince Street, U.S. 2 22.", .post = "Continue on U.S. 2 22, Pennsylvania 2 72 for 5 kilometers." } },
        },
    },
    .{
        .name = "TestBuildDestinationInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kDestination, .verbal_style = .us, .length_km = 0.000000 }, .text = "You have arrived at your destination.", .speech = .{ .alert = "You will arrive at your destination.", .pre = "You have arrived at your destination." } },
        },
    },
    .{
        .name = "TestBuildDestinationInstructions_1_miles_en_US",
        .destination = .{ .street = "3206 Powelton Avenue" },
        .steps = &.{
            .{ .maneuver = .{ .type = .kDestination, .verbal_style = .us, .length_km = 0.000000 }, .text = "You have arrived at 3206 Powelton Avenue.", .speech = .{ .alert = "You will arrive at 32 o6 Powelton Avenue.", .pre = "You have arrived at 32 o6 Powelton Avenue." } },
        },
    },
    .{
        .name = "TestBuildDestinationInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kDestinationRight, .verbal_style = .us, .length_km = 0.000000 }, .text = "Your destination is on the right.", .speech = .{ .alert = "Your destination will be on the right.", .pre = "Your destination is on the right." } },
        },
    },
    .{
        .name = "TestBuildDestinationInstructions_3_miles_en_US",
        .destination = .{ .name = "Lancaster Brewing Company" },
        .steps = &.{
            .{ .maneuver = .{ .type = .kDestinationLeft, .verbal_style = .us, .length_km = 0.000000 }, .text = "Lancaster Brewing Company is on the left.", .speech = .{ .alert = "Lancaster Brewing Company will be on the left.", .pre = "Lancaster Brewing Company is on the left." } },
        },
    },
    .{
        .name = "TestBuildBecomesInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSlightRight, .verbal_style = .us, .length_km = 0.365000, .basic_time = 19, .street_names = &.{.{ .value = "Vine Street", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Bear right onto Vine Street.", .speech = .{ .succinct = "Bear right.", .alert = "Bear right onto Vine Street.", .pre = "Bear right onto Vine Street.", .post = "Continue for a quarter mile." } },
            .{ .maneuver = .{ .type = .kBecomes, .verbal_style = .us, .length_km = 1.489000, .basic_time = 97, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Vine Street becomes Middletown Road.", .speech = .{ .pre = "Vine Street becomes Middletown Road.", .post = "Continue for 1 mile." } },
        },
    },
    .{
        .name = "TestBuildContinueInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kContinue, .verbal_style = .us, .length_km = 0.097000, .begin_relative_direction = .keep_straight }, .text = "Continue.", .speech = .{ .alert = "Continue.", .pre = "Continue.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildContinueInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kContinue, .verbal_style = .us, .length_km = 0.097000, .begin_relative_direction = .keep_straight, .include_verbal_pre_transition_length = true }, .text = "Continue.", .speech = .{ .alert = "Continue.", .pre = "Continue for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildContinueInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kContinue, .verbal_style = .us, .length_km = 0.481000, .street_names = &.{.{ .value = "10th Avenue", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Continue on 10th Avenue.", .speech = .{ .alert = "Continue on 10th Avenue.", .pre = "Continue on 10th Avenue.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildContinueInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kContinue, .verbal_style = .us, .length_km = 0.481000, .street_names = &.{.{ .value = "10th Avenue", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .include_verbal_pre_transition_length = true }, .text = "Continue on 10th Avenue.", .speech = .{ .alert = "Continue on 10th Avenue.", .pre = "Continue on 10th Avenue for a quarter mile.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .verbal_style = .us, .length_km = 0.824000, .begin_relative_direction = .left }, .text = "Turn left.", .speech = .{ .succinct = "Turn left.", .alert = "Turn left.", .pre = "Turn left.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .verbal_style = .us, .length_km = 2.011000, .basic_time = 129, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Turn left onto Middletown Road.", .speech = .{ .succinct = "Turn left.", .alert = "Turn left onto Middletown Road.", .pre = "Turn left onto Middletown Road.", .post = "Continue for 1 mile." } },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_1_miles_cs_CZ",
        .language = "cs-CZ",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .verbal_style = .us, .length_km = 2.011000, .basic_time = 129, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Odbočte vlevo na Middletown Road.", .speech = .{ .succinct = "Odbočte vlevo.", .alert = "Odbočte vlevo na Middletown Road.", .pre = "Odbočte vlevo na Middletown Road.", .post = "Pokračujte 1 míli." } },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_1_miles_de_DE",
        .language = "de-DE",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .verbal_style = .us, .length_km = 2.011000, .basic_time = 129, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Links auf Middletown Road abbiegen.", .speech = .{ .succinct = "Links abbiegen.", .alert = "Links auf Middletown Road abbiegen.", .pre = "Links auf Middletown Road abbiegen.", .post = "eine Meile weiter der Route folgen." } },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_1_miles_it_IT",
        .language = "it-IT",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .verbal_style = .us, .length_km = 2.011000, .basic_time = 129, .street_names = &.{.{ .value = "Middletown Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Svolta a sinistra su Middletown Road.", .speech = .{ .succinct = "Svolta a sinistra.", .alert = "Svolta a sinistra su Middletown Road.", .pre = "Svolta a sinistra su Middletown Road.", .post = "Continua per 1 miglio." } },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .verbal_style = .us, .length_km = 0.840369, .street_names = &.{.{ .value = "MD 924", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "North Bond Street", .is_route_number = false }, .{ .value = "US 1 Business", .is_route_number = true }, .{ .value = "MD 924", .is_route_number = true } }, .begin_relative_direction = .left }, .text = "Turn left onto North Bond Street/US 1 Business/MD 924. Continue on MD 924.", .speech = .{ .succinct = "Turn left.", .alert = "Turn left onto North Bond Street.", .pre = "Turn left onto North Bond Street, U.S. 1 Business.", .post = "Continue on Maryland 9 24 for a half mile." } },
        },
    },
    .{
        .name = "TestBuildTurnInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRight, .verbal_style = .us, .length_km = 0.077000, .street_names = &.{.{ .value = "Sunstone Drive", .is_route_number = false }}, .begin_relative_direction = .right }, .text = "Turn right onto Sunstone Drive.", .speech = .{ .succinct = "Turn right. Then Turn right to stay on Sunstone Drive.", .alert = "Turn right onto Sunstone Drive.", .pre = "Turn right onto Sunstone Drive. Then Turn right to stay on Sunstone Drive.", .post = "Continue for 300 feet." } },
            .{ .maneuver = .{ .type = .kRight, .verbal_style = .us, .length_km = 0.038000, .street_names = &.{.{ .value = "Sunstone Drive", .is_route_number = false }}, .begin_relative_direction = .right, .to_stay_on = true }, .text = "Turn right to stay on Sunstone Drive.", .speech = .{ .succinct = "Turn right.", .alert = "Turn right to stay on Sunstone Drive.", .pre = "Turn right to stay on Sunstone Drive.", .post = "Continue for 100 feet." } },
        },
    },
    .{
        .name = "TestBuildSharpInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSharpLeft, .verbal_style = .us, .length_km = 0.824000, .begin_relative_direction = .left }, .text = "Make a sharp left.", .speech = .{ .succinct = "Make a sharp left.", .alert = "Make a sharp left.", .pre = "Make a sharp left.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildSharpInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSharpRight, .verbal_style = .us, .length_km = 0.192229, .street_names = &.{.{ .value = "Flatbush Avenue", .is_route_number = false }}, .begin_relative_direction = .right }, .text = "Make a sharp right onto Flatbush Avenue.", .speech = .{ .succinct = "Make a sharp right.", .alert = "Make a sharp right onto Flatbush Avenue.", .pre = "Make a sharp right onto Flatbush Avenue.", .post = "Continue for 600 feet." } },
        },
    },
    .{
        .name = "TestBuildSharpInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSharpLeft, .verbal_style = .us, .length_km = 0.840369, .street_names = &.{.{ .value = "MD 924", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "North Bond Street", .is_route_number = false }, .{ .value = "US 1 Business", .is_route_number = true }, .{ .value = "MD 924", .is_route_number = true } }, .begin_relative_direction = .left }, .text = "Make a sharp left onto North Bond Street/US 1 Business/MD 924. Continue on MD 924.", .speech = .{ .succinct = "Make a sharp left.", .alert = "Make a sharp left onto North Bond Street.", .pre = "Make a sharp left onto North Bond Street, U.S. 1 Business.", .post = "Continue on Maryland 9 24 for a half mile." } },
        },
    },
    .{
        .name = "TestBuildBearInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSlightRight, .verbal_style = .us, .length_km = 0.018000, .begin_relative_direction = .right }, .text = "Bear right.", .speech = .{ .succinct = "Bear right.", .alert = "Bear right.", .pre = "Bear right.", .post = "Continue for 60 feet." } },
        },
    },
    .{
        .name = "TestBuildBearInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSlightLeft, .verbal_style = .us, .length_km = 0.118000, .street_names = &.{.{ .value = "Arlen Road", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Bear left onto Arlen Road.", .speech = .{ .succinct = "Bear left.", .alert = "Bear left onto Arlen Road.", .pre = "Bear left onto Arlen Road.", .post = "Continue for 400 feet." } },
        },
    },
    .{
        .name = "TestBuildBearInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kSlightRight, .verbal_style = .us, .length_km = 3.431836, .street_names = &.{.{ .value = "US 1 Business", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Belair Road", .is_route_number = false }, .{ .value = "US 1 Business", .is_route_number = true } }, .begin_relative_direction = .keep_right }, .text = "Bear right onto Belair Road/US 1 Business. Continue on US 1 Business.", .speech = .{ .succinct = "Bear right.", .alert = "Bear right onto Belair Road.", .pre = "Bear right onto Belair Road, U.S. 1 Business.", .post = "Continue on U.S. 1 Business for 2 miles." } },
        },
    },
    .{
        .name = "TestBuildBearInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutExit, .verbal_style = .us, .length_km = 18.278002, .basic_time = 900, .street_names = &.{.{ .value = "US 15", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Catoctin Mountain Highway", .is_route_number = false }, .{ .value = "US 15", .is_route_number = true } }, .begin_relative_direction = .right }, .text = "Exit the roundabout onto Catoctin Mountain Highway/US 15. Continue on US 15.", .speech = .{ .succinct = "Exit the roundabout.", .pre = "Exit the roundabout onto Catoctin Mountain Highway, U.S. 15.", .post = "Continue on U.S. 15 for 11 miles." } },
            .{ .maneuver = .{ .type = .kSlightLeft, .verbal_style = .us, .length_km = 4.137000, .basic_time = 200, .street_names = &.{.{ .value = "US 15 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .to_stay_on = true }, .text = "Bear left to stay on US 15 South.", .speech = .{ .succinct = "Bear left.", .alert = "Bear left to stay on U.S. 15 South.", .pre = "Bear left to stay on U.S. 15 South.", .post = "Continue for 3 miles." } },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kUturnLeft, .verbal_style = .us, .length_km = 0.592000, .begin_relative_direction = .reverse }, .text = "Make a left U-turn.", .speech = .{ .succinct = "Make a left U-turn.", .alert = "Make a left U-turn.", .pre = "Make a left U-turn.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kUturnRight, .verbal_style = .us, .length_km = 0.592000, .street_names = &.{.{ .value = "Bunker Hill Road", .is_route_number = false }}, .begin_relative_direction = .reverse }, .text = "Make a right U-turn onto Bunker Hill Road.", .speech = .{ .succinct = "Make a right U-turn.", .alert = "Make a right U-turn onto Bunker Hill Road.", .pre = "Make a right U-turn onto Bunker Hill Road.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRight, .verbal_style = .us, .length_km = 0.287000, .basic_time = 20, .street_names = &.{.{ .value = "Bunker Hill Road", .is_route_number = false }}, .begin_relative_direction = .right }, .text = "Turn right onto Bunker Hill Road.", .speech = .{ .succinct = "Turn right.", .alert = "Turn right onto Bunker Hill Road.", .pre = "Turn right onto Bunker Hill Road.", .post = "Continue for 900 feet." } },
            .{ .maneuver = .{ .type = .kUturnLeft, .verbal_style = .us, .length_km = 0.287000, .basic_time = 20, .street_names = &.{.{ .value = "Bunker Hill Road", .is_route_number = false }}, .begin_relative_direction = .reverse, .to_stay_on = true }, .text = "Make a left U-turn to stay on Bunker Hill Road.", .speech = .{ .succinct = "Make a left U-turn.", .alert = "Make a left U-turn to stay on Bunker Hill Road.", .pre = "Make a left U-turn to stay on Bunker Hill Road.", .post = "Continue for 900 feet." } },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kUturnLeft, .verbal_style = .us, .length_km = 0.072697, .cross_street_names = &.{.{ .value = "Devonshire Road", .is_route_number = false }}, .begin_relative_direction = .reverse }, .text = "Make a left U-turn at Devonshire Road.", .speech = .{ .succinct = "Make a left U-turn.", .alert = "Make a left U-turn at Devonshire Road.", .pre = "Make a left U-turn at Devonshire Road.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kUturnLeft, .verbal_style = .us, .length_km = 0.072697, .street_names = &.{ .{ .value = "Jonestown Road", .is_route_number = false }, .{ .value = "US 22", .is_route_number = true } }, .cross_street_names = &.{.{ .value = "Devonshire Road", .is_route_number = false }}, .begin_relative_direction = .reverse }, .text = "Make a left U-turn at Devonshire Road onto Jonestown Road/US 22.", .speech = .{ .succinct = "Make a left U-turn.", .alert = "Make a left U-turn at Devonshire Road.", .pre = "Make a left U-turn at Devonshire Road onto Jonestown Road, U.S. 22.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildUturnInstructions_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStart, .verbal_style = .us, .length_km = 0.062923, .basic_time = 2, .street_names = &.{ .{ .value = "Jonestown Road", .is_route_number = false }, .{ .value = "US 22", .is_route_number = true } }, .begin_cardinal_direction = .kNorthEast }, .text = "Drive northeast on Jonestown Road/US 22.", .speech = .{ .succinct = "Drive northeast. Then Make a left U-turn at Devonshire Road.", .pre = "Drive northeast on Jonestown Road, U.S. 22. Then Make a left U-turn at Devonshire Road.", .post = "Continue for 200 feet." } },
            .{ .maneuver = .{ .type = .kUturnLeft, .verbal_style = .us, .length_km = 0.072697, .basic_time = 40, .street_names = &.{ .{ .value = "Jonestown Road", .is_route_number = false }, .{ .value = "US 22", .is_route_number = true } }, .cross_street_names = &.{.{ .value = "Devonshire Road", .is_route_number = false }}, .begin_relative_direction = .reverse, .to_stay_on = true }, .text = "Make a left U-turn at Devonshire Road to stay on Jonestown Road/US 22.", .speech = .{ .succinct = "Make a left U-turn.", .alert = "Make a left U-turn at Devonshire Road.", .pre = "Make a left U-turn at Devonshire Road to stay on Jonestown Road, U.S. 22.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildRampStraight_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .verbal_style = .us, .length_km = 2.4, .basic_time = 30, .begin_relative_direction = .keep_straight, .ramp = true }, .text = "Stay straight to take the ramp.", .speech = .{ .alert = "Stay straight to take the ramp.", .pre = "Stay straight to take the ramp.", .post = "Continue for 1.5 miles." } },
        },
    },
    .{
        .name = "TestBuildRampStraight_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .verbal_style = .us, .length_km = 0.374000, .basic_time = 30, .begin_relative_direction = .keep_straight, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 East", .is_route_number = true, .consecutive_count = 1 }} } }, .text = "Stay straight to take the US 322 East ramp.", .speech = .{ .alert = "Stay straight to take the U.S. 3 22 East ramp.", .pre = "Stay straight to take the U.S. 3 22 East ramp." } },
        },
    },
    .{
        .name = "TestBuildRampStraight_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .verbal_style = .us, .length_km = 0.374000, .basic_time = 30, .begin_relative_direction = .keep_straight, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "Hershey" }} } }, .text = "Stay straight to take the ramp toward Hershey.", .speech = .{ .alert = "Stay straight to take the ramp toward Hershey.", .pre = "Stay straight to take the ramp toward Hershey." } },
        },
    },
    .{
        .name = "TestBuildRampStraight_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .verbal_style = .us, .length_km = 0.374000, .basic_time = 30, .begin_relative_direction = .keep_straight, .ramp = true, .signs = .{ .exit_onto_streets = &.{ .{ .text = "US 322 East", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 422 East", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 522 East", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 622 East", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 722 East", .is_route_number = true, .consecutive_count = 1 } }, .exit_toward_locations = &.{ .{ .text = "Hershey", .consecutive_count = 1 }, .{ .text = "Palmdale", .consecutive_count = 1 }, .{ .text = "Palmyra", .consecutive_count = 1 }, .{ .text = "Campbelltown", .consecutive_count = 1 }, .{ .text = "Eprata", .consecutive_count = 1 } } } }, .text = "Stay straight to take the US 322 East/US 422 East/US 522 East/US 622 East ramp toward Hershey/Palmdale/Palmyra/Campbelltown.", .speech = .{ .alert = "Stay straight to take the U.S. 3 22 East ramp.", .pre = "Stay straight to take the U.S. 3 22 East, U.S. 4 22 East ramp toward Hershey, Palmdale." } },
        },
    },
    .{
        .name = "TestBuildRampStraight_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampStraight, .verbal_style = .us, .length_km = 0.374000, .basic_time = 30, .begin_relative_direction = .keep_straight, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Stay straight to take the Gettysburg Pike ramp.", .speech = .{ .alert = "Stay straight to take the Gettysburg Pike ramp.", .pre = "Stay straight to take the Gettysburg Pike ramp." } },
        },
    },
    .{
        .name = "TestBuildRamp_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.234000, .basic_time = 9, .begin_relative_direction = .keep_right, .ramp = true, .drive_on_right = false }, .text = "Take the ramp on the right.", .speech = .{ .alert = "Take the ramp on the right.", .pre = "Take the ramp on the right." } },
        },
    },
    .{
        .name = "TestBuildRamp_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.234000, .basic_time = 9, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95", .is_route_number = true }} }, .drive_on_right = false }, .text = "Take the I 95 ramp on the right.", .speech = .{ .alert = "Take the Interstate 95 ramp on the right.", .pre = "Take the Interstate 95 ramp on the right." } },
        },
    },
    .{
        .name = "TestBuildRamp_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .verbal_style = .us, .length_km = 0.124000, .basic_time = 6, .street_names = &.{ .{ .value = "NY 27 East", .is_route_number = true }, .{ .value = "South Conduit Avenue", .is_route_number = false } }, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "JFK" }} } }, .text = "Take the ramp on the left toward JFK.", .speech = .{ .alert = "Take the ramp on the left toward JFK.", .pre = "Take the ramp on the left toward JFK." } },
        },
    },
    .{
        .name = "TestBuildRamp_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .verbal_style = .us, .length_km = 0.124000, .basic_time = 6, .street_names = &.{ .{ .value = "NY 27 East", .is_route_number = true }, .{ .value = "South Conduit Avenue", .is_route_number = false } }, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "South Conduit Avenue" }}, .exit_toward_locations = &.{.{ .text = "JFK" }} } }, .text = "Take the South Conduit Avenue ramp on the left toward JFK.", .speech = .{ .alert = "Take the South Conduit Avenue ramp on the left.", .pre = "Take the South Conduit Avenue ramp on the left toward JFK." } },
        },
    },
    .{
        .name = "TestBuildRamp_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.234000, .basic_time = 9, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} }, .drive_on_right = false }, .text = "Take the Gettysburg Pike ramp on the right.", .speech = .{ .alert = "Take the Gettysburg Pike ramp on the right.", .pre = "Take the Gettysburg Pike ramp on the right." } },
        },
    },
    .{
        .name = "TestBuildRamp_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.256000, .basic_time = 23, .begin_relative_direction = .right, .ramp = true }, .text = "Turn right to take the ramp.", .speech = .{ .alert = "Turn right to take the ramp.", .pre = "Turn right to take the ramp." } },
        },
    },
    .{
        .name = "TestBuildRamp_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .verbal_style = .us, .length_km = 0.539000, .basic_time = 23, .begin_relative_direction = .left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "PA 283 West", .is_route_number = true, .consecutive_count = 1 }} } }, .text = "Turn left to take the PA 283 West ramp.", .speech = .{ .alert = "Turn left to take the Pennsylvania 2 83 West ramp.", .pre = "Turn left to take the Pennsylvania 2 83 West ramp." } },
        },
    },
    .{
        .name = "TestBuildRamp_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .verbal_style = .us, .length_km = 0.539000, .basic_time = 23, .begin_relative_direction = .left, .ramp = true, .signs = .{ .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Harrisburg International Airport" } } } }, .text = "Turn left to take the ramp toward Harrisburg/Harrisburg International Airport.", .speech = .{ .alert = "Turn left to take the ramp toward Harrisburg.", .pre = "Turn left to take the ramp toward Harrisburg, Harrisburg International Airport." } },
        },
    },
    .{
        .name = "TestBuildRamp_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .verbal_style = .us, .length_km = 0.539000, .basic_time = 23, .begin_relative_direction = .left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "PA 283 West", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{ .{ .text = "Harrisburg" }, .{ .text = "Harrisburg International Airport" } } } }, .text = "Turn left to take the PA 283 West ramp toward Harrisburg/Harrisburg International Airport.", .speech = .{ .alert = "Turn left to take the Pennsylvania 2 83 West ramp.", .pre = "Turn left to take the Pennsylvania 2 83 West ramp toward Harrisburg, Harrisburg International Airport." } },
        },
    },
    .{
        .name = "TestBuildRamp_9_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.256000, .basic_time = 23, .begin_relative_direction = .right, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Turn right to take the Gettysburg Pike ramp.", .speech = .{ .alert = "Turn right to take the Gettysburg Pike ramp.", .pre = "Turn right to take the Gettysburg Pike ramp." } },
        },
    },
    .{
        .name = "TestBuildRamp_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.234000, .basic_time = 9, .begin_relative_direction = .keep_right, .ramp = true }, .text = "Take the ramp.", .speech = .{ .alert = "Take the ramp.", .pre = "Take the ramp." } },
        },
    },
    .{
        .name = "TestBuildRamp_11_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.234000, .basic_time = 9, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95", .is_route_number = true }} } }, .text = "Take the I 95 ramp.", .speech = .{ .alert = "Take the Interstate 95 ramp.", .pre = "Take the Interstate 95 ramp." } },
        },
    },
    .{
        .name = "TestBuildRamp_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.124000, .basic_time = 6, .street_names = &.{ .{ .value = "NY 27 East", .is_route_number = true }, .{ .value = "South Conduit Avenue", .is_route_number = false } }, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "JFK" }} } }, .text = "Take the ramp toward JFK.", .speech = .{ .alert = "Take the ramp toward JFK.", .pre = "Take the ramp toward JFK." } },
        },
    },
    .{
        .name = "TestBuildRamp_13_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampLeft, .verbal_style = .us, .length_km = 0.124000, .basic_time = 6, .street_names = &.{ .{ .value = "NY 27 East", .is_route_number = true }, .{ .value = "South Conduit Avenue", .is_route_number = false } }, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "South Conduit Avenue" }}, .exit_toward_locations = &.{.{ .text = "JFK" }} } }, .text = "Take the South Conduit Avenue ramp on the left toward JFK.", .speech = .{ .alert = "Take the South Conduit Avenue ramp on the left.", .pre = "Take the South Conduit Avenue ramp on the left toward JFK." } },
        },
    },
    .{
        .name = "TestBuildRamp_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRampRight, .verbal_style = .us, .length_km = 0.234000, .basic_time = 9, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "Gettysburg Pike" }} } }, .text = "Take the Gettysburg Pike ramp.", .speech = .{ .alert = "Take the Gettysburg Pike ramp.", .pre = "Take the Gettysburg Pike ramp." } },
        },
    },
    .{
        .name = "TestBuildExit_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .drive_on_right = false }, .text = "Take the exit on the right.", .speech = .{ .alert = "Take the exit on the right.", .pre = "Take the exit on the right." } },
        },
    },
    .{
        .name = "TestBuildExit_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }} }, .drive_on_right = false }, .text = "Take exit 67 B-A on the right.", .speech = .{ .alert = "Take exit 67 B-A on the right.", .pre = "Take exit 67 B-A on the right." } },
        },
    },
    .{
        .name = "TestBuildExit_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }} }, .drive_on_right = false }, .text = "Take the US 322 West exit on the right.", .speech = .{ .alert = "Take the U.S. 3 22 West exit on the right.", .pre = "Take the U.S. 3 22 West exit on the right." } },
        },
    },
    .{
        .name = "TestBuildExit_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }} }, .drive_on_right = false }, .text = "Take exit 67 B-A on the right onto US 322 West.", .speech = .{ .alert = "Take exit 67 B-A on the right.", .pre = "Take exit 67 B-A on the right onto U.S. 3 22 West." } },
        },
    },
    .{
        .name = "TestBuildExit_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} }, .drive_on_right = false }, .text = "Take the exit on the right toward Lewistown.", .speech = .{ .alert = "Take the exit on the right toward Lewistown.", .pre = "Take the exit on the right toward Lewistown." } },
        },
    },
    .{
        .name = "TestBuildExit_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} }, .drive_on_right = false }, .text = "Take exit 67 B-A on the right toward Lewistown.", .speech = .{ .alert = "Take exit 67 B-A on the right.", .pre = "Take exit 67 B-A on the right toward Lewistown." } },
        },
    },
    .{
        .name = "TestBuildExit_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }}, .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} }, .drive_on_right = false }, .text = "Take the US 322 West exit on the right toward Lewistown.", .speech = .{ .alert = "Take the U.S. 3 22 West exit on the right.", .pre = "Take the U.S. 3 22 West exit on the right toward Lewistown." } },
        },
    },
    .{
        .name = "TestBuildExit_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_onto_streets = &.{ .{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }, .{ .text = "US 22 West", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 22 East", .is_route_number = true }, .{ .text = "PA 230 East", .is_route_number = true }, .{ .text = "Cameron Street" } }, .exit_toward_locations = &.{ .{ .text = "Lewistown", .consecutive_count = 1 }, .{ .text = "State College", .consecutive_count = 1 }, .{ .text = "Harrisburg" } } }, .drive_on_right = false }, .text = "Take exit 67 B-A on the right onto US 322 West toward Lewistown/State College.", .speech = .{ .alert = "Take exit 67 B-A on the right.", .pre = "Take exit 67 B-A on the right onto U.S. 3 22 West toward Lewistown, State College." } },
        },
    },
    .{
        .name = "TestBuildExit_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .verbal_style = .us, .length_km = 1.002000, .basic_time = 46, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "White Marsh Boulevard" }} } }, .text = "Take the White Marsh Boulevard exit on the left.", .speech = .{ .alert = "Take the White Marsh Boulevard exit on the left.", .pre = "Take the White Marsh Boulevard exit on the left." } },
        },
    },
    .{
        .name = "TestBuildExit_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .verbal_style = .us, .length_km = 1.002000, .basic_time = 46, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "MD 43 East", .is_route_number = true, .consecutive_count = 1 }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} } }, .text = "Take the White Marsh Boulevard exit on the left onto MD 43 East.", .speech = .{ .alert = "Take the Maryland 43 East exit on the left.", .pre = "Take the White Marsh Boulevard exit on the left onto Maryland 43 East." } },
        },
    },
    .{
        .name = "TestBuildExit_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .verbal_style = .us, .length_km = 1.002000, .basic_time = 46, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "White Marsh" }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} } }, .text = "Take the White Marsh Boulevard exit on the left toward White Marsh.", .speech = .{ .alert = "Take the exit on the left toward White Marsh.", .pre = "Take the White Marsh Boulevard exit on the left toward White Marsh." } },
        },
    },
    .{
        .name = "TestBuildExit_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .verbal_style = .us, .length_km = 1.002000, .basic_time = 46, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "MD 43 East", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "White Marsh" }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} } }, .text = "Take the White Marsh Boulevard exit on the left onto MD 43 East toward White Marsh.", .speech = .{ .alert = "Take the Maryland 43 East exit on the left.", .pre = "Take the White Marsh Boulevard exit on the left onto Maryland 43 East toward White Marsh." } },
        },
    },
    .{
        .name = "TestBuildExit_15_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true }, .text = "Take the exit.", .speech = .{ .alert = "Take the exit.", .pre = "Take the exit." } },
        },
    },
    .{
        .name = "TestBuildExit_16_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }} } }, .text = "Take exit 67 B-A.", .speech = .{ .alert = "Take exit 67 B-A.", .pre = "Take exit 67 B-A." } },
        },
    },
    .{
        .name = "TestBuildExit_17_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }} } }, .text = "Take the US 322 West exit.", .speech = .{ .alert = "Take the U.S. 3 22 West exit.", .pre = "Take the U.S. 3 22 West exit." } },
        },
    },
    .{
        .name = "TestBuildExit_18_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }} } }, .text = "Take exit 67 B-A onto US 322 West.", .speech = .{ .alert = "Take exit 67 B-A.", .pre = "Take exit 67 B-A onto U.S. 3 22 West." } },
        },
    },
    .{
        .name = "TestBuildExit_19_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} } }, .text = "Take the exit toward Lewistown.", .speech = .{ .alert = "Take the exit toward Lewistown.", .pre = "Take the exit toward Lewistown." } },
        },
    },
    .{
        .name = "TestBuildExit_20_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} } }, .text = "Take exit 67 B-A toward Lewistown.", .speech = .{ .alert = "Take exit 67 B-A.", .pre = "Take exit 67 B-A toward Lewistown." } },
        },
    },
    .{
        .name = "TestBuildExit_21_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }}, .exit_toward_locations = &.{.{ .text = "Lewistown", .consecutive_count = 1 }} } }, .text = "Take the US 322 West exit toward Lewistown.", .speech = .{ .alert = "Take the U.S. 3 22 West exit.", .pre = "Take the U.S. 3 22 West exit toward Lewistown." } },
        },
    },
    .{
        .name = "TestBuildExit_22_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.561000, .basic_time = 23, .street_names = &.{.{ .value = "US 322 West", .is_route_number = true }}, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_numbers = &.{.{ .text = "67 B-A" }}, .exit_onto_streets = &.{ .{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 }, .{ .text = "US 22 West", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "US 22 East", .is_route_number = true }, .{ .text = "PA 230 East", .is_route_number = true }, .{ .text = "Cameron Street" } }, .exit_toward_locations = &.{ .{ .text = "Lewistown", .consecutive_count = 1 }, .{ .text = "State College", .consecutive_count = 1 }, .{ .text = "Harrisburg" } } } }, .text = "Take exit 67 B-A onto US 322 West toward Lewistown/State College.", .speech = .{ .alert = "Take exit 67 B-A.", .pre = "Take exit 67 B-A onto U.S. 3 22 West toward Lewistown, State College." } },
        },
    },
    .{
        .name = "TestBuildExit_23_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .verbal_style = .us, .length_km = 1.002000, .basic_time = 46, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_names = &.{.{ .text = "White Marsh Boulevard" }} }, .drive_on_right = false }, .text = "Take the White Marsh Boulevard exit.", .speech = .{ .alert = "Take the White Marsh Boulevard exit.", .pre = "Take the White Marsh Boulevard exit." } },
        },
    },
    .{
        .name = "TestBuildExit_25_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .verbal_style = .us, .length_km = 1.002000, .basic_time = 46, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "MD 43 East", .is_route_number = true, .consecutive_count = 1 }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} }, .drive_on_right = false }, .text = "Take the White Marsh Boulevard exit onto MD 43 East.", .speech = .{ .alert = "Take the Maryland 43 East exit.", .pre = "Take the White Marsh Boulevard exit onto Maryland 43 East." } },
        },
    },
    .{
        .name = "TestBuildExit_27_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .verbal_style = .us, .length_km = 1.002000, .basic_time = 46, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_toward_locations = &.{.{ .text = "White Marsh" }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} }, .drive_on_right = false }, .text = "Take the White Marsh Boulevard exit toward White Marsh.", .speech = .{ .alert = "Take the exit toward White Marsh.", .pre = "Take the White Marsh Boulevard exit toward White Marsh." } },
        },
    },
    .{
        .name = "TestBuildExit_29_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitLeft, .verbal_style = .us, .length_km = 1.002000, .basic_time = 46, .street_names = &.{.{ .value = "MD 43 East", .is_route_number = true }}, .begin_relative_direction = .keep_left, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "MD 43 East", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "White Marsh" }}, .exit_names = &.{.{ .text = "White Marsh Boulevard" }} }, .drive_on_right = false }, .text = "Take the White Marsh Boulevard exit onto MD 43 East toward White Marsh.", .speech = .{ .alert = "Take the Maryland 43 East exit.", .pre = "Take the White Marsh Boulevard exit onto Maryland 43 East toward White Marsh." } },
        },
    },
    .{
        .name = "TestBuildKeep_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayStraight, .verbal_style = .us, .length_km = 0.068000, .basic_time = 4, .begin_relative_direction = .keep_straight, .ramp = true }, .text = "Keep straight at the fork.", .speech = .{ .alert = "Keep straight at the fork.", .pre = "Keep straight at the fork." } },
        },
    },
    .{
        .name = "TestBuildKeep_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .verbal_style = .us, .length_km = 14.464000, .basic_time = 581, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "62" }} } }, .text = "Keep right to take exit 62.", .speech = .{ .alert = "Keep right to take exit 62.", .pre = "Keep right to take exit 62.", .post = "Continue for 9 miles." } },
        },
    },
    .{
        .name = "TestBuildKeep_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .verbal_style = .us, .length_km = 14.464000, .basic_time = 581, .street_names = &.{.{ .value = "I 895 South", .is_route_number = true }}, .begin_relative_direction = .keep_right }, .text = "Keep right to take I 895 South.", .speech = .{ .alert = "Keep right to take Interstate 8 95 South.", .pre = "Keep right to take Interstate 8 95 South.", .post = "Continue for 9 miles." } },
        },
    },
    .{
        .name = "TestBuildKeep_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .verbal_style = .us, .length_km = 14.464000, .basic_time = 581, .street_names = &.{.{ .value = "I 895 South", .is_route_number = true }}, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "62" }} } }, .text = "Keep right to take exit 62 onto I 895 South.", .speech = .{ .alert = "Keep right to take exit 62.", .pre = "Keep right to take exit 62 onto Interstate 8 95 South.", .post = "Continue for 9 miles." } },
        },
    },
    .{
        .name = "TestBuildKeep_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .verbal_style = .us, .length_km = 14.464000, .basic_time = 581, .begin_relative_direction = .keep_right, .signs = .{ .exit_toward_locations = &.{.{ .text = "Annapolis" }} } }, .text = "Keep right toward Annapolis.", .speech = .{ .alert = "Keep right toward Annapolis.", .pre = "Keep right toward Annapolis.", .post = "Continue for 9 miles." } },
        },
    },
    .{
        .name = "TestBuildKeep_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .verbal_style = .us, .length_km = 14.464000, .basic_time = 581, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "62" }}, .exit_toward_locations = &.{.{ .text = "Annapolis" }} } }, .text = "Keep right to take exit 62 toward Annapolis.", .speech = .{ .alert = "Keep right to take exit 62.", .pre = "Keep right to take exit 62 toward Annapolis.", .post = "Continue for 9 miles." } },
        },
    },
    .{
        .name = "TestBuildKeep_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .verbal_style = .us, .length_km = 14.464000, .basic_time = 581, .begin_relative_direction = .keep_right, .signs = .{ .exit_onto_streets = &.{ .{ .text = "I 895 South", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "Baltimore Harbor Tunnel Thruway" } }, .exit_toward_locations = &.{.{ .text = "Annapolis" }} } }, .text = "Keep right to take I 895 South toward Annapolis.", .speech = .{ .alert = "Keep right to take Interstate 8 95 South.", .pre = "Keep right to take Interstate 8 95 South toward Annapolis.", .post = "Continue for 9 miles." } },
        },
    },
    .{
        .name = "TestBuildKeep_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kStayRight, .verbal_style = .us, .length_km = 14.464000, .basic_time = 581, .street_names = &.{.{ .value = "I 895 South", .is_route_number = true }}, .begin_relative_direction = .keep_right, .signs = .{ .exit_numbers = &.{.{ .text = "62" }}, .exit_onto_streets = &.{ .{ .text = "I 895 South", .is_route_number = true, .consecutive_count = 1 }, .{ .text = "Baltimore Harbor Tunnel Thruway" } }, .exit_toward_locations = &.{.{ .text = "Annapolis" }} } }, .text = "Keep right to take exit 62 onto I 895 South toward Annapolis.", .speech = .{ .alert = "Keep right to take exit 62.", .pre = "Keep right to take exit 62 onto Interstate 8 95 South toward Annapolis.", .post = "Continue for 9 miles." } },
        },
    },
    .{
        .name = "TestBuildKeepToStayOn_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kMerge, .verbal_style = .us, .length_km = 23.639002, .basic_time = 832, .street_names = &.{ .{ .value = "I 95 South", .is_route_number = true }, .{ .value = "John F. Kennedy Memorial Highway", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 95 South/John F. Kennedy Memorial Highway.", .speech = .{ .succinct = "Merge.", .pre = "Merge onto Interstate 95 South, John F. Kennedy Memorial Highway.", .post = "Continue for 15 miles." } },
            .{ .maneuver = .{ .type = .kStayLeft, .verbal_style = .us, .length_km = 8.258000, .basic_time = 334, .street_names = &.{.{ .value = "I 95 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} }, .to_stay_on = true }, .text = "Keep left to stay on I 95 South.", .speech = .{ .alert = "Keep left to stay on Interstate 95 South.", .pre = "Keep left to stay on Interstate 95 South.", .post = "Continue for 5 miles." } },
        },
    },
    .{
        .name = "TestBuildKeepToStayOn_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kMerge, .verbal_style = .us, .length_km = 23.639002, .basic_time = 832, .street_names = &.{ .{ .value = "I 95 South", .is_route_number = true }, .{ .value = "John F. Kennedy Memorial Highway", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 95 South/John F. Kennedy Memorial Highway.", .speech = .{ .succinct = "Merge.", .pre = "Merge onto Interstate 95 South, John F. Kennedy Memorial Highway.", .post = "Continue for 15 miles." } },
            .{ .maneuver = .{ .type = .kStayLeft, .verbal_style = .us, .length_km = 8.258000, .basic_time = 334, .street_names = &.{.{ .value = "I 95 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "62" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }} }, .to_stay_on = true }, .text = "Keep left to take exit 62 to stay on I 95 South.", .speech = .{ .alert = "Keep left to stay on Interstate 95 South.", .pre = "Keep left to take exit 62 to stay on Interstate 95 South.", .post = "Continue for 5 miles." } },
        },
    },
    .{
        .name = "TestBuildKeepToStayOn_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kMerge, .verbal_style = .us, .length_km = 23.639002, .basic_time = 832, .street_names = &.{ .{ .value = "I 95 South", .is_route_number = true }, .{ .value = "John F. Kennedy Memorial Highway", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 95 South/John F. Kennedy Memorial Highway.", .speech = .{ .succinct = "Merge.", .pre = "Merge onto Interstate 95 South, John F. Kennedy Memorial Highway.", .post = "Continue for 15 miles." } },
            .{ .maneuver = .{ .type = .kStayLeft, .verbal_style = .us, .length_km = 8.258000, .basic_time = 334, .street_names = &.{.{ .value = "I 95 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} }, .to_stay_on = true }, .text = "Keep left to stay on I 95 South toward Baltimore.", .speech = .{ .alert = "Keep left to stay on Interstate 95 South.", .pre = "Keep left to stay on Interstate 95 South toward Baltimore.", .post = "Continue for 5 miles." } },
        },
    },
    .{
        .name = "TestBuildKeepToStayOn_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kMerge, .verbal_style = .us, .length_km = 23.639002, .basic_time = 832, .street_names = &.{ .{ .value = "I 95 South", .is_route_number = true }, .{ .value = "John F. Kennedy Memorial Highway", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 95 South/John F. Kennedy Memorial Highway.", .speech = .{ .succinct = "Merge.", .pre = "Merge onto Interstate 95 South, John F. Kennedy Memorial Highway.", .post = "Continue for 15 miles." } },
            .{ .maneuver = .{ .type = .kStayLeft, .verbal_style = .us, .length_km = 8.258000, .basic_time = 334, .street_names = &.{.{ .value = "I 95 South", .is_route_number = true }}, .begin_relative_direction = .keep_left, .signs = .{ .exit_numbers = &.{.{ .text = "62" }}, .exit_onto_streets = &.{.{ .text = "I 95 South", .is_route_number = true }}, .exit_toward_locations = &.{.{ .text = "Baltimore" }} }, .to_stay_on = true }, .text = "Keep left to take exit 62 to stay on I 95 South toward Baltimore.", .speech = .{ .alert = "Keep left to stay on Interstate 95 South.", .pre = "Keep left to take exit 62 to stay on Interstate 95 South toward Baltimore.", .post = "Continue for 5 miles." } },
        },
    },
    .{
        .name = "TestBuildMerge_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.864000, .basic_time = 34, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 76 West", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "Pittsburgh" }} } }, .text = "Take the I 76 West exit toward Pittsburgh.", .speech = .{ .alert = "Take the Interstate 76 West exit.", .pre = "Take the Interstate 76 West exit toward Pittsburgh." } },
            .{ .maneuver = .{ .type = .kMerge, .verbal_style = .us, .length_km = 7.624001, .basic_time = 243, .begin_relative_direction = .keep_straight }, .text = "Merge.", .speech = .{ .succinct = "Merge.", .pre = "Merge.", .post = "Continue for 5 miles." } },
        },
    },
    .{
        .name = "TestBuildMerge_1_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 0.864000, .basic_time = 34, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 76 West", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "Pittsburgh" }} } }, .text = "Take the I 76 West exit toward Pittsburgh.", .speech = .{ .alert = "Take the Interstate 76 West exit.", .pre = "Take the Interstate 76 West exit toward Pittsburgh." } },
            .{ .maneuver = .{ .type = .kMerge, .verbal_style = .us, .length_km = 7.624001, .basic_time = 243, .street_names = &.{ .{ .value = "I 76 West", .is_route_number = true }, .{ .value = "Pennsylvania Turnpike", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 76 West/Pennsylvania Turnpike.", .speech = .{ .succinct = "Merge.", .pre = "Merge onto Interstate 76 West, Pennsylvania Turnpike.", .post = "Continue for 5 miles." } },
        },
    },
    .{
        .name = "TestBuildMerge_1_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kExitRight, .verbal_style = .us, .length_km = 2.1, .basic_time = 34, .begin_relative_direction = .keep_right, .ramp = true, .signs = .{ .exit_onto_streets = &.{.{ .text = "I 76 West", .is_route_number = true, .consecutive_count = 1 }}, .exit_toward_locations = &.{.{ .text = "Pittsburgh" }} } }, .text = "Take the I 76 West exit toward Pittsburgh.", .speech = .{ .alert = "Take the Interstate 76 West exit.", .pre = "Take the Interstate 76 West exit toward Pittsburgh.", .post = "Continue for 1.5 miles." } },
            .{ .maneuver = .{ .type = .kMerge, .verbal_style = .us, .length_km = 7.624001, .basic_time = 243, .street_names = &.{ .{ .value = "I 76 West", .is_route_number = true }, .{ .value = "Pennsylvania Turnpike", .is_route_number = false } }, .begin_relative_direction = .keep_straight }, .text = "Merge onto I 76 West/Pennsylvania Turnpike.", .speech = .{ .succinct = "Merge.", .alert = "Merge onto Interstate 76 West.", .pre = "Merge onto Interstate 76 West, Pennsylvania Turnpike.", .post = "Continue for 5 miles." } },
        },
    },
    .{
        .name = "TestBuildEnterRoundabout_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true }, .text = "Enter the roundabout.", .speech = .{ .succinct = "Enter the roundabout.", .alert = "Enter the roundabout.", .pre = "Enter the roundabout." } },
        },
    },
    .{
        .name = "TestBuildEnterRoundabout_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 1 }, .text = "Enter the roundabout and take the 1st exit.", .speech = .{ .succinct = "Enter the roundabout and take the 1st exit.", .alert = "Enter the roundabout and take the 1st exit.", .pre = "Enter the roundabout and take the 1st exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 2 }, .text = "Enter the roundabout and take the 2nd exit.", .speech = .{ .succinct = "Enter the roundabout and take the 2nd exit.", .alert = "Enter the roundabout and take the 2nd exit.", .pre = "Enter the roundabout and take the 2nd exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 3 }, .text = "Enter the roundabout and take the 3rd exit.", .speech = .{ .succinct = "Enter the roundabout and take the 3rd exit.", .alert = "Enter the roundabout and take the 3rd exit.", .pre = "Enter the roundabout and take the 3rd exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 4 }, .text = "Enter the roundabout and take the 4th exit.", .speech = .{ .succinct = "Enter the roundabout and take the 4th exit.", .alert = "Enter the roundabout and take the 4th exit.", .pre = "Enter the roundabout and take the 4th exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 5 }, .text = "Enter the roundabout and take the 5th exit.", .speech = .{ .succinct = "Enter the roundabout and take the 5th exit.", .alert = "Enter the roundabout and take the 5th exit.", .pre = "Enter the roundabout and take the 5th exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 6 }, .text = "Enter the roundabout and take the 6th exit.", .speech = .{ .succinct = "Enter the roundabout and take the 6th exit.", .alert = "Enter the roundabout and take the 6th exit.", .pre = "Enter the roundabout and take the 6th exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 7 }, .text = "Enter the roundabout and take the 7th exit.", .speech = .{ .succinct = "Enter the roundabout and take the 7th exit.", .alert = "Enter the roundabout and take the 7th exit.", .pre = "Enter the roundabout and take the 7th exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 8 }, .text = "Enter the roundabout and take the 8th exit.", .speech = .{ .succinct = "Enter the roundabout and take the 8th exit.", .alert = "Enter the roundabout and take the 8th exit.", .pre = "Enter the roundabout and take the 8th exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 9 }, .text = "Enter the roundabout and take the 9th exit.", .speech = .{ .succinct = "Enter the roundabout and take the 9th exit.", .alert = "Enter the roundabout and take the 9th exit.", .pre = "Enter the roundabout and take the 9th exit." } },
            .{ .maneuver = .{ .type = .kRoundaboutEnter, .verbal_style = .us, .length_km = 0.043000, .basic_time = 2, .begin_relative_direction = .right, .roundabout = true, .roundabout_exit_count = 10 }, .text = "Enter the roundabout and take the 10th exit.", .speech = .{ .succinct = "Enter the roundabout and take the 10th exit.", .alert = "Enter the roundabout and take the 10th exit.", .pre = "Enter the roundabout and take the 10th exit." } },
        },
    },
    .{
        .name = "TestBuildExitRoundabout_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutExit, .verbal_style = .us, .length_km = 1.041000, .basic_time = 64, .begin_relative_direction = .keep_straight }, .text = "Exit the roundabout.", .speech = .{ .succinct = "Exit the roundabout.", .pre = "Exit the roundabout.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildExitRoundabout_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutExit, .verbal_style = .us, .length_km = 1.041000, .basic_time = 64, .street_names = &.{ .{ .value = "Philadelphia Road", .is_route_number = false }, .{ .value = "MD 7", .is_route_number = true } }, .begin_relative_direction = .keep_straight }, .text = "Exit the roundabout onto Philadelphia Road/MD 7.", .speech = .{ .succinct = "Exit the roundabout.", .pre = "Exit the roundabout onto Philadelphia Road, Maryland 7.", .post = "Continue for a half mile." } },
        },
    },
    .{
        .name = "TestBuildExitRoundabout_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kRoundaboutExit, .verbal_style = .us, .length_km = 18.278002, .basic_time = 914, .street_names = &.{.{ .value = "US 15", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Catoctin Mountain Highway", .is_route_number = false }, .{ .value = "US 15", .is_route_number = true } }, .begin_relative_direction = .right }, .text = "Exit the roundabout onto Catoctin Mountain Highway/US 15. Continue on US 15.", .speech = .{ .succinct = "Exit the roundabout.", .pre = "Exit the roundabout onto Catoctin Mountain Highway, U.S. 15.", .post = "Continue on U.S. 15 for 11 miles." } },
        },
    },
    .{
        .name = "TestBuildEnterFerry_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryEnter, .verbal_style = .us, .length_km = 1.446000, .basic_time = 521, .begin_relative_direction = .keep_straight }, .text = "Take the Ferry.", .speech = .{ .alert = "Take the Ferry.", .pre = "Take the Ferry.", .post = "Continue for 1 mile." } },
        },
    },
    .{
        .name = "TestBuildEnterFerry_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryEnter, .verbal_style = .us, .length_km = 1.446000, .basic_time = 521, .street_names = &.{.{ .value = "Millersburg FERRY", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Take the Millersburg FERRY.", .speech = .{ .alert = "Take the Millersburg FERRY.", .pre = "Take the Millersburg FERRY.", .post = "Continue for 1 mile." } },
        },
    },
    .{
        .name = "TestBuildEnterFerry_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryEnter, .verbal_style = .us, .length_km = 27.731001, .basic_time = 3328, .street_names = &.{.{ .value = "Bridgeport - Port Jefferson", .is_route_number = false }}, .begin_relative_direction = .keep_straight }, .text = "Take the Bridgeport - Port Jefferson Ferry.", .speech = .{ .alert = "Take the Bridgeport - Port Jefferson Ferry.", .pre = "Take the Bridgeport - Port Jefferson Ferry.", .post = "Continue for 17 miles." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.065000, .basic_time = 12, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kTransit }, .text = "Head southeast.", .speech = .{ .succinct = "Head southeast.", .pre = "Head southeast.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.065000, .basic_time = 12, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kTransit, .include_verbal_pre_transition_length = true }, .text = "Head southeast.", .speech = .{ .succinct = "Head southeast for 200 feet.", .pre = "Head southeast for 200 feet.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.578000, .basic_time = 70, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kTransit }, .text = "Head west on Ferry Lane.", .speech = .{ .succinct = "Head west.", .pre = "Head west on Ferry Lane.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.578000, .basic_time = 70, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kTransit, .include_verbal_pre_transition_length = true }, .text = "Head west on Ferry Lane.", .speech = .{ .succinct = "Head west for a quarter mile.", .pre = "Head west on Ferry Lane for a quarter mile.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.099000, .basic_time = 5, .street_names = &.{.{ .value = "US 9", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Cape May-Lewes Ferry Entrance", .is_route_number = false }, .{ .value = "US 9", .is_route_number = true } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kNorthEast, .travel_mode = .kTransit }, .text = "Head northeast on Cape May-Lewes Ferry Entrance/US 9. Continue on US 9.", .speech = .{ .succinct = "Head northeast.", .pre = "Head northeast on Cape May-Lewes Ferry Entrance, U.S. 9.", .post = "Continue on U.S. 9 for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.065000, .basic_time = 12, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kDrive }, .text = "Drive southeast.", .speech = .{ .succinct = "Drive southeast.", .pre = "Drive southeast.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.065000, .basic_time = 12, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kDrive, .include_verbal_pre_transition_length = true }, .text = "Drive southeast.", .speech = .{ .succinct = "Drive southeast for 200 feet.", .pre = "Drive southeast for 200 feet.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.578000, .basic_time = 70, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kDrive }, .text = "Drive west on Ferry Lane.", .speech = .{ .succinct = "Drive west.", .pre = "Drive west on Ferry Lane.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.578000, .basic_time = 70, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kDrive, .include_verbal_pre_transition_length = true }, .text = "Drive west on Ferry Lane.", .speech = .{ .succinct = "Drive west for a quarter mile.", .pre = "Drive west on Ferry Lane for a quarter mile.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_9_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.099000, .basic_time = 5, .street_names = &.{.{ .value = "US 9", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Cape May-Lewes Ferry Entrance", .is_route_number = false }, .{ .value = "US 9", .is_route_number = true } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kNorthEast, .travel_mode = .kDrive }, .text = "Drive northeast on Cape May-Lewes Ferry Entrance/US 9. Continue on US 9.", .speech = .{ .succinct = "Drive northeast.", .pre = "Drive northeast on Cape May-Lewes Ferry Entrance, U.S. 9.", .post = "Continue on U.S. 9 for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.065000, .basic_time = 12, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kPedestrian }, .text = "Walk southeast.", .speech = .{ .succinct = "Walk southeast.", .pre = "Walk southeast.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_11_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.065000, .basic_time = 12, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kPedestrian, .include_verbal_pre_transition_length = true }, .text = "Walk southeast.", .speech = .{ .succinct = "Walk southeast for 200 feet.", .pre = "Walk southeast for 200 feet.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.578000, .basic_time = 70, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kPedestrian }, .text = "Walk west on Ferry Lane.", .speech = .{ .succinct = "Walk west.", .pre = "Walk west on Ferry Lane.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_13_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.578000, .basic_time = 70, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kPedestrian, .include_verbal_pre_transition_length = true }, .text = "Walk west on Ferry Lane.", .speech = .{ .succinct = "Walk west for a quarter mile.", .pre = "Walk west on Ferry Lane for a quarter mile.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.099000, .basic_time = 5, .street_names = &.{.{ .value = "US 9", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Cape May-Lewes Ferry Entrance", .is_route_number = false }, .{ .value = "US 9", .is_route_number = true } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kNorthEast, .travel_mode = .kPedestrian }, .text = "Walk northeast on Cape May-Lewes Ferry Entrance/US 9. Continue on US 9.", .speech = .{ .succinct = "Walk northeast.", .pre = "Walk northeast on Cape May-Lewes Ferry Entrance, U.S. 9.", .post = "Continue on U.S. 9 for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_15_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.065000, .basic_time = 12, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kBicycle }, .text = "Bike southeast.", .speech = .{ .succinct = "Bike southeast.", .pre = "Bike southeast.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_16_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.065000, .basic_time = 12, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthEast, .travel_mode = .kBicycle, .include_verbal_pre_transition_length = true }, .text = "Bike southeast.", .speech = .{ .succinct = "Bike southeast for 200 feet.", .pre = "Bike southeast for 200 feet.", .post = "Continue for 200 feet." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_17_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.578000, .basic_time = 70, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kBicycle }, .text = "Bike west on Ferry Lane.", .speech = .{ .succinct = "Bike west.", .pre = "Bike west on Ferry Lane.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_18_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.578000, .basic_time = 70, .street_names = &.{.{ .value = "Ferry Lane", .is_route_number = false }}, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kWest, .travel_mode = .kBicycle, .include_verbal_pre_transition_length = true }, .text = "Bike west on Ferry Lane.", .speech = .{ .succinct = "Bike west for a quarter mile.", .pre = "Bike west on Ferry Lane for a quarter mile.", .post = "Continue for a quarter mile." } },
        },
    },
    .{
        .name = "TestBuildExitFerry_19_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kFerryExit, .verbal_style = .us, .length_km = 0.099000, .basic_time = 5, .street_names = &.{.{ .value = "US 9", .is_route_number = true }}, .begin_street_names = &.{ .{ .value = "Cape May-Lewes Ferry Entrance", .is_route_number = false }, .{ .value = "US 9", .is_route_number = true } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kNorthEast, .travel_mode = .kBicycle }, .text = "Bike northeast on Cape May-Lewes Ferry Entrance/US 9. Continue on US 9.", .speech = .{ .succinct = "Bike northeast.", .pre = "Bike northeast on Cape May-Lewes Ferry Entrance, U.S. 9.", .post = "Continue on U.S. 9 for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest.", .speech = .{ .succinct = "Head southwest.", .pre = "Head southwest.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_1_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit, .include_verbal_pre_transition_length = true }, .text = "Head southwest.", .speech = .{ .succinct = "Head southwest for 300 feet.", .pre = "Head southwest for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_2_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 6th Avenue/Avenue of the Americas.", .speech = .{ .succinct = "Head southwest.", .pre = "Head southwest on 6th Avenue, Avenue of the Americas.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_3_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit, .include_verbal_pre_transition_length = true }, .text = "Head southwest on 6th Avenue/Avenue of the Americas.", .speech = .{ .succinct = "Head southwest for 300 feet.", .pre = "Head southwest on 6th Avenue, Avenue of the Americas for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_4_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{.{ .value = "6th Avenue", .is_route_number = false }}, .begin_street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kTransit }, .text = "Head southwest on 6th Avenue/Avenue of the Americas. Continue on 6th Avenue.", .speech = .{ .succinct = "Head southwest.", .pre = "Head southwest on 6th Avenue, Avenue of the Americas.", .post = "Continue on 6th Avenue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_5_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest.", .speech = .{ .succinct = "Drive southwest.", .pre = "Drive southwest.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_6_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive, .include_verbal_pre_transition_length = true }, .text = "Drive southwest.", .speech = .{ .succinct = "Drive southwest for 300 feet.", .pre = "Drive southwest for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_7_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest on 6th Avenue/Avenue of the Americas.", .speech = .{ .succinct = "Drive southwest.", .pre = "Drive southwest on 6th Avenue, Avenue of the Americas.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_8_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive, .include_verbal_pre_transition_length = true }, .text = "Drive southwest on 6th Avenue/Avenue of the Americas.", .speech = .{ .succinct = "Drive southwest for 300 feet.", .pre = "Drive southwest on 6th Avenue, Avenue of the Americas for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_9_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{.{ .value = "6th Avenue", .is_route_number = false }}, .begin_street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kDrive }, .text = "Drive southwest on 6th Avenue/Avenue of the Americas. Continue on 6th Avenue.", .speech = .{ .succinct = "Drive southwest.", .pre = "Drive southwest on 6th Avenue, Avenue of the Americas.", .post = "Continue on 6th Avenue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_10_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest.", .speech = .{ .succinct = "Walk southwest.", .pre = "Walk southwest.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_11_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian, .include_verbal_pre_transition_length = true }, .text = "Walk southwest.", .speech = .{ .succinct = "Walk southwest for 300 feet.", .pre = "Walk southwest for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_12_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest on 6th Avenue/Avenue of the Americas.", .speech = .{ .succinct = "Walk southwest.", .pre = "Walk southwest on 6th Avenue, Avenue of the Americas.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_13_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian, .include_verbal_pre_transition_length = true }, .text = "Walk southwest on 6th Avenue/Avenue of the Americas.", .speech = .{ .succinct = "Walk southwest for 300 feet.", .pre = "Walk southwest on 6th Avenue, Avenue of the Americas for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_14_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{.{ .value = "6th Avenue", .is_route_number = false }}, .begin_street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kPedestrian }, .text = "Walk southwest on 6th Avenue/Avenue of the Americas. Continue on 6th Avenue.", .speech = .{ .succinct = "Walk southwest.", .pre = "Walk southwest on 6th Avenue, Avenue of the Americas.", .post = "Continue on 6th Avenue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_15_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest.", .speech = .{ .succinct = "Bike southwest.", .pre = "Bike southwest.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_16_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle, .include_verbal_pre_transition_length = true }, .text = "Bike southwest.", .speech = .{ .succinct = "Bike southwest for 300 feet.", .pre = "Bike southwest for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_17_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest on 6th Avenue/Avenue of the Americas.", .speech = .{ .succinct = "Bike southwest.", .pre = "Bike southwest on 6th Avenue, Avenue of the Americas.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_18_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle, .include_verbal_pre_transition_length = true }, .text = "Bike southwest on 6th Avenue/Avenue of the Americas.", .speech = .{ .succinct = "Bike southwest for 300 feet.", .pre = "Bike southwest on 6th Avenue, Avenue of the Americas for 300 feet.", .post = "Continue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildPostTransitConnectionDestination_19_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kPostTransitConnectionDestination, .verbal_style = .us, .length_km = 0.088000, .basic_time = 62, .street_names = &.{.{ .value = "6th Avenue", .is_route_number = false }}, .begin_street_names = &.{ .{ .value = "6th Avenue", .is_route_number = false }, .{ .value = "Avenue of the Americas", .is_route_number = false } }, .begin_relative_direction = .keep_straight, .begin_cardinal_direction = .kSouthWest, .travel_mode = .kBicycle }, .text = "Bike southwest on 6th Avenue/Avenue of the Americas. Continue on 6th Avenue.", .speech = .{ .succinct = "Bike southwest.", .pre = "Bike southwest on 6th Avenue, Avenue of the Americas.", .post = "Continue on 6th Avenue for 300 feet." } },
        },
    },
    .{
        .name = "TestBuildVerbalMultiCue_0_miles_en_US",
        .steps = &.{
            .{ .maneuver = .{ .type = .kLeft, .verbal_style = .us, .length_km = 0.074000, .basic_time = 4, .street_names = &.{.{ .value = "North Plum Street", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Turn left onto North Plum Street.", .speech = .{ .succinct = "Turn left. Then Turn left onto East Fulton Street.", .alert = "Turn left onto North Plum Street.", .pre = "Turn left onto North Plum Street. Then Turn left onto East Fulton Street.", .post = "Continue for 200 feet." } },
            .{ .maneuver = .{ .type = .kLeft, .verbal_style = .us, .length_km = 0.120478, .basic_time = 12, .street_names = &.{.{ .value = "East Fulton Street", .is_route_number = false }}, .begin_relative_direction = .left }, .text = "Turn left onto East Fulton Street.", .speech = .{ .succinct = "Turn left.", .alert = "Turn left onto East Fulton Street.", .pre = "Turn left onto East Fulton Street.", .post = "Continue for 400 feet." } },
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

pub const post = [_]struct { units: request.Units, maneuver: Maneuver, include_street_names: bool, expected: []const u8 }{
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 4.0 }, .include_street_names = false, .expected = "Continue for 4 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 3.4 }, .include_street_names = false, .expected = "Continue for 3 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 3.6 }, .include_street_names = false, .expected = "Continue for 4 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 2.8 }, .include_street_names = true, .expected = "Continue on Main Street for 3 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 2.7 }, .include_street_names = false, .expected = "Continue for 2.5 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 2.3 }, .include_street_names = false, .expected = "Continue for 2.5 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 2.2 }, .include_street_names = false, .expected = "Continue for 2 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 1.8 }, .include_street_names = false, .expected = "Continue for 2 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 1.7 }, .include_street_names = false, .expected = "Continue for 1.5 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 1.3 }, .include_street_names = false, .expected = "Continue for 1.5 kilometers." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 1.1 }, .include_street_names = false, .expected = "Continue for 1 kilometer." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.95 }, .include_street_names = false, .expected = "Continue for 1 kilometer." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 1.0 }, .include_street_names = true, .expected = "Continue on Main Street for 1 kilometer." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.94 }, .include_street_names = false, .expected = "Continue for 900 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.85 }, .include_street_names = false, .expected = "Continue for 900 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.9 }, .include_street_names = true, .expected = "Continue on Main Street for 900 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.44 }, .include_street_names = false, .expected = "Continue for 400 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.35 }, .include_street_names = false, .expected = "Continue for 400 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.4 }, .include_street_names = true, .expected = "Continue on Main Street for 400 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.14 }, .include_street_names = false, .expected = "Continue for 100 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.095 }, .include_street_names = false, .expected = "Continue for 100 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.1 }, .include_street_names = true, .expected = "Continue on Main Street for 100 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.094 }, .include_street_names = false, .expected = "Continue for 90 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.085 }, .include_street_names = false, .expected = "Continue for 90 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.09 }, .include_street_names = true, .expected = "Continue on Main Street for 90 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.034 }, .include_street_names = false, .expected = "Continue for 30 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.025 }, .include_street_names = false, .expected = "Continue for 30 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.03 }, .include_street_names = true, .expected = "Continue on Main Street for 30 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.012 }, .include_street_names = false, .expected = "Continue for 10 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.0096 }, .include_street_names = false, .expected = "Continue for 10 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.01 }, .include_street_names = true, .expected = "Continue on Main Street for 10 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.0094 }, .include_street_names = false, .expected = "Continue for less than 10 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.0088 }, .include_street_names = false, .expected = "Continue for less than 10 meters." },
    .{ .units = .kilometers, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.005 }, .include_street_names = true, .expected = "Continue on Main Street for less than 10 meters." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 4.828032 }, .include_street_names = false, .expected = "Continue for 3 miles." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 92.21541 }, .include_street_names = false, .expected = "Continue for 57 miles." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 3.604931 }, .include_street_names = false, .expected = "Continue for 2 miles." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 2.848539 }, .include_street_names = false, .expected = "Continue for 2 miles." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 3.637117 }, .include_street_names = true, .expected = "Continue on Main Street for 2 miles." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 2.73588 }, .include_street_names = false, .expected = "Continue for 1.5 miles." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 2.09215 }, .include_street_names = false, .expected = "Continue for 1.5 miles." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 2.41402 }, .include_street_names = true, .expected = "Continue on Main Street for 1.5 miles." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 1.657624 }, .include_street_names = false, .expected = "Continue for 1 mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 1.561064 }, .include_street_names = false, .expected = "Continue for 1 mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 1.60934 }, .include_street_names = true, .expected = "Continue on Main Street for 1 mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.965606 }, .include_street_names = false, .expected = "Continue for a half mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.643738 }, .include_street_names = false, .expected = "Continue for a half mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.804672 }, .include_street_names = true, .expected = "Continue on Main Street for a half mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.5632704 }, .include_street_names = false, .expected = "Continue for a quarter mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.30632398537 }, .include_street_names = false, .expected = "Continue for a quarter mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.402336 }, .include_street_names = true, .expected = "Continue on Main Street for a quarter mile." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.155448 }, .include_street_names = false, .expected = "Continue for 500 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.149352 }, .include_street_names = false, .expected = "Continue for 500 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.1524 }, .include_street_names = true, .expected = "Continue on Main Street for 500 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.036576 }, .include_street_names = false, .expected = "Continue for 100 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.028956 }, .include_street_names = false, .expected = "Continue for 100 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.03048 }, .include_street_names = true, .expected = "Continue on Main Street for 100 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.0283464 }, .include_street_names = false, .expected = "Continue for 90 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.0268224 }, .include_street_names = false, .expected = "Continue for 90 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.027432 }, .include_street_names = true, .expected = "Continue on Main Street for 90 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.0036576 }, .include_street_names = false, .expected = "Continue for 10 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.00292608 }, .include_street_names = false, .expected = "Continue for 10 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.003048 }, .include_street_names = true, .expected = "Continue on Main Street for 10 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.00280416 }, .include_street_names = false, .expected = "Continue for less than 10 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.00268224 }, .include_street_names = false, .expected = "Continue for less than 10 feet." },
    .{ .units = .miles, .maneuver = .{ .street_names = &.{.{ .value = "Main Street", .is_route_number = false }}, .length_km = 0.001524 }, .include_street_names = true, .expected = "Continue on Main Street for less than 10 feet." },
};

pub const approach = [_]struct { units: request.Units, distance: f32, cue: []const u8, expected: []const u8 }{
    .{ .units = .kilometers, .distance = 0.125, .cue = "Turn right onto Main Street.", .expected = "In 100 meters, Turn right onto Main Street." },
    .{ .units = .kilometers, .distance = 0.4, .cue = "Turn right onto Main Street.", .expected = "In 400 meters, Turn right onto Main Street." },
    .{ .units = .kilometers, .distance = 0.8, .cue = "Turn right onto Main Street.", .expected = "In 800 meters, Turn right onto Main Street." },
    .{ .units = .kilometers, .distance = 1.0, .cue = "Take exit 1 30.", .expected = "In 1 kilometer, Take exit 1 30." },
    .{ .units = .kilometers, .distance = 3.0, .cue = "Take exit 9 on the left.", .expected = "In 3 kilometers, Take exit 9 on the left." },
    .{ .units = .miles, .distance = 0.125, .cue = "Turn right onto Main Street", .expected = "In 700 feet, Turn right onto Main Street" },
    .{ .units = .miles, .distance = 0.25, .cue = "Turn right onto Main Street", .expected = "In a quarter mile, Turn right onto Main Street" },
    .{ .units = .miles, .distance = 0.5, .cue = "Turn right onto Main Street", .expected = "In a half mile, Turn right onto Main Street" },
    .{ .units = .miles, .distance = 1.0, .cue = "Take exit 31C on the left.", .expected = "In 1 mile, Take exit 31C on the left." },
    .{ .units = .miles, .distance = 2.0, .cue = "Take exit 3 26.", .expected = "In 2 miles, Take exit 3 26." },
};

pub const multi_cue = [_]struct { units: request.Units, maneuver: Maneuver, first: []const u8, next: []const u8, expected: []const u8 }{
    .{ .units = .kilometers, .maneuver = .{}, .first = "Turn left onto North Plum Street.", .next = "Turn right onto East Fulton Street.", .expected = "Turn left onto North Plum Street. Then Turn right onto East Fulton Street." },
    .{ .units = .kilometers, .maneuver = .{ .distant_verbal_multi_cue = true, .length_km = 0.16 }, .first = "Turn left onto North Plum Street.", .next = "Turn right onto East Fulton Street.", .expected = "Turn left onto North Plum Street. Then, in 200 meters, Turn right onto East Fulton Street." },
    .{ .units = .miles, .maneuver = .{ .distant_verbal_multi_cue = true, .length_km = 0.16 }, .first = "Turn left onto North Plum Street.", .next = "Turn right onto East Fulton Street.", .expected = "Turn left onto North Plum Street. Then, in 500 feet, Turn right onto East Fulton Street." },
};
