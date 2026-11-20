// Ported from src/odin/narrativebuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const trip = @import("../api/trip.zig");
const dictionary = @import("dictionary.zig");
const format = @import("instruction_format.zig");
const Maneuver = @import("maneuver.zig").Maneuver;
const maneuvers = @import("maneuvers.zig");

pub const Options = struct {
    language: []const u8 = "en-US",
    roundabout_exits: bool = true,
};

/// Produce the annotated trip leg and its visual instructions in the request arena.
pub fn build(arena: std.mem.Allocator, leg: *const trip.TripLeg, options: Options, deadline: io.Deadline) !maneuvers.BuildResult {
    const built = try maneuvers.buildAnnotated(arena, leg, .{ .roundabout_exits = options.roundabout_exits }, deadline);
    const destination: trip.Location = if (leg.location.len == 0) .{} else leg.location[leg.location.len - 1];
    const builder: Builder = .{
        .locale = dictionary.forLanguage(options.language),
        .destination = destination,
        .sign_limits = .{ .deadline = deadline },
    };
    for (built.maneuvers, 0..) |*step, index| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const previous = if (index == 0) null else &built.maneuvers[index - 1];
        step.instruction = try builder.instruction(arena, step, previous);
    }
    return built;
}

const Value = format.Value;
const present = format.present;
const direction = format.direction;
const forkDirection = format.forkDirection;
const PhraseMap = dictionary.types.PhraseMap;

const Phrase = struct {
    text: []const u8,
    fields: format.Fields,
    articulate: bool,

    fn init(phrases: PhraseMap, id: u8, fields: format.Fields) Phrase {
        return .{ .text = phrases.get(id) orelse unreachable, .fields = fields, .articulate = true };
    }

    fn literal(phrases: PhraseMap, id: u8, fields: format.Fields) Phrase {
        return .{ .text = phrases.get(id) orelse unreachable, .fields = fields, .articulate = false };
    }
};

const Builder = struct {
    locale: *const dictionary.NarrativeDictionary,
    destination: trip.Location = .{},
    sign_limits: format.SignLimits = .{},

    fn instruction(self: Builder, arena: std.mem.Allocator, step: *const Maneuver, previous: ?*const Maneuver) ![]const u8 {
        const deadline = self.sign_limits.deadline;
        const phrase = try self.select(step, previous);
        const prefix: []const u8 = switch (step.bss_maneuver_type) {
            .kRentBikeAtBikeShare => "Then rent a bike at BSS. ",
            .kReturnBikeAtBikeShare => "Then return the bike to BSS. ",
            else => "",
        };
        if (phrase == null) return prefix;
        const selected = phrase.?;
        var out = io.Writer.Allocating.init(arena);
        errdefer out.deinit();
        try out.writer.writeAll(prefix);
        try format.writePhrase(&out.writer, selected.text, selected.fields, .{ .deadline = deadline });
        const bytes = try out.toOwnedSlice();
        if (selected.articulate and std.mem.eql(u8, self.locale.language_tag, "it-IT")) {
            const len = try format.articulateItalian(bytes[prefix.len..], deadline);
            return bytes[0 .. prefix.len + len];
        }
        return bytes;
    }

    fn select(self: Builder, step: *const Maneuver, previous: ?*const Maneuver) !?Phrase {
        return switch (step.type) {
            .kStart, .kStartLeft, .kStartRight, .kFerryExit, .kPostTransitConnectionDestination => try self.start(step),
            .kDestination, .kDestinationLeft, .kDestinationRight => self.arrive(step),
            .kBecomes => if (previous) |before| try self.becomes(step, before) else null,
            .kSlightLeft, .kSlightRight => try self.turn(step, self.locale.bear_subset),
            .kLeft, .kRight => try self.turn(step, self.locale.turn_subset),
            .kSharpLeft, .kSharpRight => try self.turn(step, self.locale.sharp_subset),
            .kUturnLeft, .kUturnRight => try self.uturn(step),
            .kRampStraight, .kRampLeft, .kRampRight => try self.ramp(step),
            .kExitLeft, .kExitRight => try self.exit(step),
            .kStayLeft, .kStayStraight, .kStayRight => if (step.to_stay_on) try self.keepToStayOn(step) else try self.keep(step),
            .kMerge, .kMergeLeft, .kMergeRight => try self.merge(step),
            .kRoundaboutEnter => try self.enterRoundabout(step),
            .kRoundaboutExit => try self.exitRoundabout(step),
            .kFerryEnter => try self.enterFerry(step),
            .kElevatorEnter => level(step, self.locale.elevator_subset.phrases, true),
            .kStepsEnter => level(step, self.locale.steps_subset.phrases, true),
            .kEscalatorEnter => level(step, self.locale.escalator_subset.phrases, true),
            .kLevelChange => level(step, self.locale.level_change_subset.phrases, false),
            .kBuildingEnter => try self.building(step, self.locale.enter_building_subset.phrases, &self.locale.enter_building_subset.empty_street_name_labels),
            .kBuildingExit => try self.building(step, self.locale.exit_building_subset.phrases, &self.locale.exit_building_subset.empty_street_name_labels),
            .kParkVehicle => Phrase.literal(self.locale.park_vehicle_subset.phrases, 0, .{}),
            .kTransit, .kTransitTransfer, .kTransitRemainOn, .kTransitConnectionStart, .kTransitConnectionTransfer, .kTransitConnectionDestination => null,
            else => if (step.node_type) |kind| try self.pass(step, kind) else try self.goOn(step),
        };
    }

    fn start(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.start_subset;
        const street_names = try format.startNames(step, &subset.empty_street_name_labels, 0, self.sign_limits.deadline);
        const offset: u8 = switch (step.travel_mode) {
            .kDrive => 4,
            .kPedestrian => 8,
            .kBicycle => 16,
            else => 0,
        };
        return Phrase.init(subset.phrases, offset + present(!street_names.street.isEmpty()) + present(!street_names.begin.isEmpty()), .{
            .CARDINAL_DIRECTION = .{ .text = subset.cardinal_directions[@intCast(@backingInt(step.begin_cardinal_direction))] },
            .STREET_NAMES = street_names.street,
            .BEGIN_STREET_NAMES = street_names.begin,
        });
    }

    fn arrive(self: Builder, step: *const Maneuver) Phrase {
        const subset = self.locale.destination_subset;
        const name = if (self.destination.name.len != 0) self.destination.name else self.destination.street;
        const with_side = step.type != .kDestination;
        return Phrase.init(subset.phrases, present(name.len != 0) + 2 * present(with_side), .{
            .DESTINATION = .{ .text = name },
            .RELATIVE_DIRECTION = if (with_side) direction(step, subset.relative_directions) else .empty,
        });
    }

    fn becomes(self: Builder, step: *const Maneuver, previous: *const Maneuver) !Phrase {
        return Phrase.init(self.locale.becomes_subset.phrases, 0, .{
            .STREET_NAMES = try self.names(step.street_names),
            .PREVIOUS_STREET_NAMES = try self.names(previous.street_names),
        });
    }

    fn goOn(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.continue_subset;
        const street_name = try self.street(step, &subset.empty_street_name_labels, 0);
        const sign = try format.junctionOrGuide(step, self.sign_limits, 2, 3);
        return Phrase.init(subset.phrases, sign.id orelse present(!street_name.isEmpty()), .{
            .STREET_NAMES = street_name,
            .JUNCTION_NAME = sign.junction,
            .TOWARD_SIGN = sign.guide,
        });
    }

    fn turn(self: Builder, step: *const Maneuver, subset: dictionary.types.TurnSubset) !Phrase {
        const street_names = try format.startNames(step, &subset.empty_street_name_labels, 0, self.sign_limits.deadline);
        const sign = try format.junctionOrGuide(step, self.sign_limits, 4, 5);
        const id: u8 = sign.id orelse if (step.to_stay_on) 3 else if (!street_names.begin.isEmpty()) 2 else present(!street_names.street.isEmpty());
        return Phrase.init(subset.phrases, id, .{
            .RELATIVE_DIRECTION = direction(step, subset.relative_directions),
            .STREET_NAMES = street_names.street,
            .BEGIN_STREET_NAMES = street_names.begin,
            .JUNCTION_NAME = sign.junction,
            .TOWARD_SIGN = sign.guide,
        });
    }

    fn uturn(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.uturn_subset;
        const street_name = try self.street(step, &subset.empty_street_name_labels, 0);
        const cross = try self.names(step.cross_street_names);
        const sign = try format.junctionOrGuide(step, self.sign_limits, 6, 7);
        const street_id: u8 = if (street_name.isEmpty()) 0 else 1 + present(step.to_stay_on);
        return Phrase.init(subset.phrases, sign.id orelse street_id + 3 * present(!cross.isEmpty()), .{
            .RELATIVE_DIRECTION = direction(step, subset.relative_directions),
            .STREET_NAMES = street_name,
            .CROSS_STREET_NAMES = cross,
            .JUNCTION_NAME = sign.junction,
            .TOWARD_SIGN = sign.guide,
        });
    }

    fn ramp(self: Builder, step: *const Maneuver) !Phrase {
        const sign = step.signs;
        const branch = sign.exit_onto_streets.len != 0;
        const toward = sign.exit_toward_locations.len != 0;
        const name = !branch and !toward and sign.exit_names.len != 0;
        var fields: format.Fields = .{
            .BRANCH_SIGN = try self.sign_limits.signs(sign.exit_onto_streets),
            .TOWARD_SIGN = try self.sign_limits.signs(sign.exit_toward_locations),
            .NAME_SIGN = if (name) try self.sign_limits.signs(sign.exit_names) else .empty,
        };
        const id = present(branch) + 2 * present(toward) + 4 * present(name);
        if (step.type == .kRampStraight) return Phrase.init(self.locale.ramp_straight_subset.phrases, id, fields);
        const subset = self.locale.ramp_subset;
        fields.RELATIVE_DIRECTION = direction(step, subset.relative_directions);
        return Phrase.init(subset.phrases, format.rampDirectionOffset(step) + id, fields);
    }

    fn exit(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.exit_subset;
        const sign = step.signs;
        const number = sign.exit_numbers.len != 0;
        const name = !number and sign.exit_names.len != 0;
        const driving_side = (step.type == .kExitRight) == step.drive_on_right;
        const id = 15 * present(driving_side) + present(number) + 2 * present(sign.exit_onto_streets.len != 0) +
            4 * present(sign.exit_toward_locations.len != 0) + 8 * present(name);
        return Phrase.init(subset.phrases, id, .{
            .RELATIVE_DIRECTION = direction(step, subset.relative_directions),
            .NUMBER_SIGN = try format.exitNumbers(sign, self.sign_limits.deadline),
            .BRANCH_SIGN = try self.sign_limits.signs(sign.exit_onto_streets),
            .TOWARD_SIGN = try self.sign_limits.signs(sign.exit_toward_locations),
            .NAME_SIGN = if (name) try self.sign_limits.signs(sign.exit_names) else .empty,
        });
    }

    fn keep(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.keep_subset;
        const sign = step.signs;
        const names_and_signs = try format.keepNames(step, &subset.empty_street_name_labels, self.sign_limits);
        const id = present(sign.exit_numbers.len != 0) + 2 * present(!names_and_signs.street.isEmpty()) + 4 * present(!names_and_signs.toward.isEmpty());
        return Phrase.init(subset.phrases, id, .{
            .RELATIVE_DIRECTION = forkDirection(step, subset.relative_directions),
            .NUMBER_SIGN = try format.exitNumbers(sign, self.sign_limits.deadline),
            .STREET_NAMES = names_and_signs.street,
            .TOWARD_SIGN = names_and_signs.toward,
        });
    }

    fn keepToStayOn(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.keep_to_stay_on_subset;
        const sign = step.signs;
        const toward = try self.sign_limits.signs(if (sign.guide_toward_locations.len != 0) sign.guide_toward_locations else sign.exit_toward_locations);
        const id = present(sign.exit_numbers.len != 0) + 2 * present(!toward.isEmpty());
        return Phrase.init(subset.phrases, id, .{
            .RELATIVE_DIRECTION = forkDirection(step, subset.relative_directions),
            .NUMBER_SIGN = try format.exitNumbers(sign, self.sign_limits.deadline),
            .STREET_NAMES = try self.street(step, &subset.empty_street_name_labels, self.sign_limits.count),
            .TOWARD_SIGN = toward,
        });
    }

    fn merge(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.merge_subset;
        const street_name = try self.street(step, &subset.empty_street_name_labels, 0);
        const has_direction = step.type != .kMerge;
        const use_guide = street_name.isEmpty() and step.hasGuideSign();
        const id = present(has_direction) + 2 * present(!street_name.isEmpty()) + 4 * present(use_guide);
        return Phrase.init(subset.phrases, id, .{
            .RELATIVE_DIRECTION = if (has_direction) direction(step, subset.relative_directions) else .empty,
            .STREET_NAMES = street_name,
            .TOWARD_SIGN = if (use_guide) try self.sign_limits.guide(step.signs) else .empty,
        });
    }

    fn enterRoundabout(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.enter_roundabout_subset;
        const circle = try self.names(step.street_names);
        // Valhalla always uses the first exit name list here, even when its
        // maneuver builder folds the exit into the entry.
        const exit_names = try self.names(if (step.roundabout_exit_begin_street_names.len != 0)
            step.roundabout_exit_begin_street_names
        else
            step.roundabout_exit_street_names);
        const sign = step.roundabout_exit_signs;
        const guide = sign.guide_onto_streets.len != 0 or sign.guide_toward_locations.len != 0;
        const count = step.roundabout_exit_count;
        const has_ordinal = count >= 1 and count <= subset.ordinal_values.len;
        const ordinal: Value = if (has_ordinal) .{ .text = subset.ordinal_values[count - 1] } else .empty;
        const offset: u8 = if (has_ordinal) 1 else if (!exit_names.isEmpty() or guide) 4 else 0;
        const exit_id = if (guide) @as(u8, 3) else present(!exit_names.isEmpty());
        return Phrase.init(subset.phrases, 8 * present(!circle.isEmpty()) + offset + exit_id, .{
            .ORDINAL_VALUE = ordinal,
            .STREET_NAMES = circle,
            .TOWARD_SIGN = if (guide) try self.sign_limits.guide(sign) else .empty,
            .ROUNDABOUT_EXIT_STREET_NAMES = exit_names,
            .ROUNDABOUT_EXIT_BEGIN_STREET_NAMES = .empty,
        });
    }

    fn exitRoundabout(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.exit_roundabout_subset;
        const street_names = try format.startNames(step, &subset.empty_street_name_labels, 0, self.sign_limits.deadline);
        const guide = step.hasGuideSign();
        const id = if (guide) @as(u8, 3) else present(!street_names.street.isEmpty()) + present(!street_names.begin.isEmpty());
        return Phrase.init(subset.phrases, id, .{
            .STREET_NAMES = street_names.street,
            .BEGIN_STREET_NAMES = street_names.begin,
            .TOWARD_SIGN = if (guide) try self.sign_limits.guide(step.signs) else .empty,
        });
    }

    fn enterFerry(self: Builder, step: *const Maneuver) !Phrase {
        const subset = self.locale.enter_ferry_subset;
        const street_name = try self.street(step, &subset.empty_street_name_labels, 0);
        const guide = step.hasGuideSign();
        const id: u8 = if (guide) 3 else if (street_name.isEmpty()) 0 else if (street_name.endsWithLabel(subset.ferry_label)) 1 else 2;
        return Phrase.init(subset.phrases, id, .{
            .STREET_NAMES = street_name,
            .FERRY_LABEL = .{ .text = subset.ferry_label },
            .TOWARD_SIGN = if (guide) try self.sign_limits.guide(step.signs) else .empty,
        });
    }

    fn level(step: *const Maneuver, phrases: PhraseMap, has_default: bool) Phrase {
        return Phrase.literal(phrases, present(has_default and step.end_level_ref.len != 0), .{
            .LEVEL = .{ .text = step.end_level_ref },
        });
    }

    fn building(self: Builder, step: *const Maneuver, phrases: PhraseMap, labels: []const []const u8) !Phrase {
        const name = try self.street(step, labels, 0);
        return Phrase.literal(phrases, present(!name.isEmpty()), .{ .STREET_NAMES = name });
    }

    fn pass(self: Builder, step: *const Maneuver, kind: trip.NodeType) !Phrase {
        const subset = self.locale.pass_subset;
        const cross = if (kind == .kStreetIntersection) try self.names(step.cross_street_names) else .empty;
        const index: usize = switch (kind) {
            .kGate => 0,
            .kBollard => 1,
            else => 2,
        };
        return Phrase.init(subset.phrases, present(kind == .kStreetIntersection and step.traffic_signal), .{
            .OBJECT_LABEL = if (cross.isEmpty()) .{ .text = subset.object_labels[index] } else cross,
        });
    }

    fn names(self: Builder, list: []const trip.StreetName) !Value {
        return format.names(list, 0, self.sign_limits.deadline);
    }

    fn street(self: Builder, step: *const Maneuver, labels: []const []const u8, limit: usize) !Value {
        return format.streetNames(step, step.street_names, labels, limit, self.sign_limits.deadline);
    }
};

test "Valhalla visual instruction snapshots" {
    const fixtures = @import("instruction_fixtures.zig");
    const snapshot = @import("reference_snapshot.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (&fixtures.visual) |fixture| {
        if (fixture.upstream_disabled) continue;
        _ = arena.reset(.retain_capacity);
        const builder: Builder = .{
            .locale = dictionary.forLanguage(fixture.language),
            .destination = fixture.destination,
        };
        for (fixture.steps, 0..) |*step, index| {
            const previous = if (index == 0) null else &fixture.steps[index - 1].maneuver;
            const actual = try builder.instruction(arena.allocator(), &step.maneuver, previous);
            snapshot.match(fixture.name, step.text, actual) catch |err| {
                std.debug.print("{s}, step {d}\n", .{ fixture.name, index });
                return err;
            };
        }
    }
}

test "Valhalla signed ramp and exit snapshots" {
    const fixtures = @import("instruction_fixtures.zig");
    const snapshot = @import("reference_snapshot.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const builder: Builder = .{ .locale = dictionary.forLanguage("en-US") };
    for (&fixtures.signed_ramps_and_exits) |fixture| {
        _ = arena.reset(.retain_capacity);
        for (fixture.steps, 0..) |*step, index| {
            const actual = try builder.instruction(arena.allocator(), &step.maneuver, null);
            snapshot.match(fixture.name, step.text, actual) catch |err| {
                std.debug.print("{s}, case {d}\n", .{ fixture.name, index });
                return err;
            };
        }
    }
}
