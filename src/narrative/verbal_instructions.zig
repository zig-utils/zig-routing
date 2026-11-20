// Ported from the verbal instruction methods in src/odin/narrativebuilder.cc
// (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const request = @import("../api/request.zig");
const trip = @import("../api/trip.zig");
const dictionary = @import("dictionary.zig");
const format = @import("instruction_format.zig");
const visual = @import("instructions.zig");
const locale_format = @import("locale_format.zig");
const maneuver = @import("maneuver.zig");
const maneuvers = @import("maneuvers.zig");
const markup = @import("markup.zig");
const postprocess = @import("postprocess.zig");
const distance = @import("verbal_distances.zig");
const verbal_text = @import("verbal_text.zig");

const Maneuver = maneuver.Maneuver;
const Value = format.Value;
const present = format.present;
const direction = format.direction;
const forkDirection = format.forkDirection;

pub const Options = struct {
    language: []const u8 = "en-US",
    roundabout_exits: bool = true,
    units: request.Units = .kilometers,
    markup_formatter: markup.Formatter = .{},
};

/// Build the annotated trip leg and all visual and spoken road guidance.
pub fn build(arena: std.mem.Allocator, leg: *const trip.TripLeg, options: Options, deadline: io.Deadline) !maneuvers.BuildResult {
    const built = try visual.build(arena, leg, .{ .language = options.language, .roundabout_exits = options.roundabout_exits }, deadline);
    const destination: trip.Location = if (leg.location.len == 0) .{} else leg.location[leg.location.len - 1];
    var text_formatter = verbal_text.Formatter.init(arena, options.markup_formatter, deadline);
    defer text_formatter.deinit();
    const builder = Builder.init(arena, options.language, options.units, destination, &text_formatter, deadline);
    try builder.annotate(built.maneuvers);
    return built;
}

const Cue = enum {
    succinct,
    alert,
    pre,

    fn limit(self: Cue) usize {
        return if (self == .alert) 1 else 2;
    }
};

const Builder = struct {
    arena: std.mem.Allocator,
    locale: *const dictionary.NarrativeDictionary,
    local_format: locale_format.Format,
    units: request.Units,
    destination: trip.Location,
    text_formatter: *verbal_text.Formatter,
    deadline: io.Deadline,

    fn init(arena: std.mem.Allocator, language: []const u8, units: request.Units, destination: trip.Location, text_formatter: *verbal_text.Formatter, deadline: io.Deadline) Builder {
        const locale = dictionary.forLanguage(language);
        return .{
            .arena = arena,
            .locale = locale,
            .local_format = locale_format.Format.forPosixLocale(locale.posix_locale),
            .units = units,
            .destination = destination,
            .text_formatter = text_formatter,
            .deadline = deadline,
        };
    }

    fn annotate(self: *const Builder, steps: []Maneuver) !void {
        for (steps, 0..) |*step, index| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const previous = if (index == 0) null else &steps[index - 1];
            step.verbal_succinct_transition_instruction = try self.transition(step, previous, .succinct);
            step.verbal_transition_alert_instruction = try self.transition(step, previous, .alert);
            step.verbal_pre_transition_instruction = try self.transition(step, previous, .pre);
            if (postStreetNames(step)) |include_street_names| {
                step.verbal_post_transition_instruction = try self.post(step, include_street_names);
            }
        }

        var previous: ?*Maneuver = null;
        for (steps) |*next| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (next.pedestrian_type == .kBlind) continue;
            if (previous) |step| {
                if (postprocess.markVerbalMultiCue(step, next)) try self.multiCue(step, next);
            }
            previous = next;
        }
    }

    fn transition(self: *const Builder, step: *const Maneuver, previous: ?*const Maneuver, cue: Cue) ![]const u8 {
        return switch (step.type) {
            .kStart, .kStartLeft, .kStartRight, .kFerryExit, .kPostTransitConnectionDestination => if (cue == .alert) "" else self.start(step, cue),
            .kDestination, .kDestinationLeft, .kDestinationRight => if (cue == .succinct) "" else self.arrive(step, cue),
            .kBecomes => if (cue == .pre and previous != null) self.becomes(step, previous.?) else "",
            .kSlightLeft, .kSlightRight => self.turn(step, cue, self.locale.bear_verbal_subset),
            .kLeft, .kRight => self.turn(step, cue, self.locale.turn_verbal_subset),
            .kSharpLeft, .kSharpRight => self.turn(step, cue, self.locale.sharp_verbal_subset),
            .kUturnLeft, .kUturnRight => self.uturn(step, cue),
            .kRampStraight, .kRampLeft, .kRampRight => if (cue == .succinct) "" else self.ramp(step, cue),
            .kExitLeft, .kExitRight => if (cue == .succinct) "" else self.exit(step, cue),
            .kStayLeft, .kStayRight, .kStayStraight => if (cue == .succinct) "" else if (step.to_stay_on)
                self.keepToStayOn(step, cue)
            else
                self.keep(step, cue),
            .kMerge, .kMergeLeft, .kMergeRight => if (cue == .alert and (previous == null or previous.?.length_km <= 2))
                ""
            else
                self.merge(step, cue),
            .kRoundaboutEnter => self.enterRoundabout(step, cue),
            .kRoundaboutExit => if (cue == .alert) "" else self.exitRoundabout(step, cue),
            .kFerryEnter => if (cue == .succinct) "" else self.enterFerry(step, cue),
            .kStepsEnter => if (cue == .succinct) "" else step.instruction,
            .kElevatorEnter => if (cue == .succinct or step.node_type != .kElevator) "" else step.instruction,
            .kEscalatorEnter, .kBuildingEnter, .kBuildingExit, .kLevelChange, .kParkVehicle => "",
            .kTransit, .kTransitTransfer, .kTransitRemainOn, .kTransitConnectionStart, .kTransitConnectionDestination, .kTransitConnectionTransfer => "",
            else => if (step.node_type != null)
                (if (cue == .pre) step.instruction else "")
            else if (cue == .succinct)
                ""
            else
                self.goOn(step, cue),
        };
    }

    fn start(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.start_verbal_subset;
        const names = if (cue == .succinct) format.StreetPair{} else try format.startNames(step, &subset.empty_street_name_labels, cue.limit(), self.deadline);
        const offset: u8 = switch (step.travel_mode) {
            .kDrive => 5,
            .kPedestrian => 10,
            .kBicycle => 15,
            else => 0,
        };
        const id = offset + 2 * present(!names.street.isEmpty()) + (if (!names.begin.isEmpty()) @as(u8, 2) else present(step.include_verbal_pre_transition_length));
        return self.emit(step.verbal_style, subset.phrases, id, .{
            .CARDINAL_DIRECTION = .{ .text = subset.cardinal_directions[@intCast(@backingInt(step.begin_cardinal_direction))] },
            .STREET_NAMES = if (cue == .succinct) null else names.street,
            .BEGIN_STREET_NAMES = if (cue == .succinct) null else names.begin,
            .LENGTH = self.length(step, .from(subset)),
        });
    }

    fn arrive(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = if (cue == .alert) self.locale.destination_verbal_alert_subset else self.locale.destination_verbal_subset;
        const name: Value = if (self.destination.name.len != 0) .{ .text = self.destination.name } else .{ .spoken = self.destination.street };
        const side = step.type != .kDestination;
        const id = present(!name.isEmpty()) + 2 * present(side);
        return self.emit(step.verbal_style, subset.phrases, id, .{
            .DESTINATION = name,
            .RELATIVE_DIRECTION = if (side) direction(step, self.locale.destination_subset.relative_directions) else .empty,
        });
    }

    fn becomes(self: *const Builder, step: *const Maneuver, previous: *const Maneuver) ![]const u8 {
        return self.emit(previous.verbal_style, self.locale.becomes_verbal_subset.phrases, 0, .{
            .STREET_NAMES = try format.names(step.street_names, Cue.pre.limit(), self.deadline),
            .PREVIOUS_STREET_NAMES = try format.names(previous.street_names, Cue.pre.limit(), self.deadline),
        });
    }

    fn goOn(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const alert = self.locale.continue_verbal_alert_subset;
        const pre = self.locale.continue_verbal_subset;
        const limits = self.cueLimits(cue);
        const labels = if (cue == .alert) &alert.empty_street_name_labels else &pre.empty_street_name_labels;
        const street = try format.streetNames(step, step.street_names, labels, limits.count, self.deadline);
        const sign = try format.junctionOrGuide(step, limits, 2, 3);
        const id = sign.id orelse present(!street.isEmpty());
        var fields: format.Fields = .{ .STREET_NAMES = street, .JUNCTION_NAME = sign.junction, .TOWARD_SIGN = sign.guide };
        if (cue == .alert) return self.emit(step.verbal_style, alert.phrases, id, fields);
        fields.LENGTH = self.length(step, .from(pre));
        return self.emit(step.verbal_style, pre.phrases, 2 * id + present(step.include_verbal_pre_transition_length), fields);
    }

    fn turn(self: *const Builder, step: *const Maneuver, cue: Cue, subset: dictionary.types.TurnSubset) ![]const u8 {
        const limits = self.cueLimits(cue);
        const names = if (cue == .succinct) format.StreetPair{} else try format.startNames(step, &subset.empty_street_name_labels, limits.count, self.deadline);
        const sign = try format.junctionOrGuide(step, limits, 4, 5);
        const street_id: u8 = if (cue == .succinct) 0 else if (step.to_stay_on) 3 else if (!names.begin.isEmpty()) 2 else present(!names.street.isEmpty());
        return self.emit(step.verbal_style, subset.phrases, sign.id orelse street_id, .{
            .RELATIVE_DIRECTION = direction(step, subset.relative_directions),
            .STREET_NAMES = if (cue == .succinct) null else names.street,
            .BEGIN_STREET_NAMES = if (cue == .succinct) null else names.begin,
            .JUNCTION_NAME = sign.junction,
            .TOWARD_SIGN = sign.guide,
        });
    }

    fn uturn(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.uturn_verbal_subset;
        const limits = self.cueLimits(cue);
        const street = if (cue == .succinct) .empty else try format.streetNames(step, step.street_names, &subset.empty_street_name_labels, limits.count, self.deadline);
        const cross = if (cue == .succinct) .empty else try format.names(step.cross_street_names, limits.count, self.deadline);
        const sign = try format.junctionOrGuide(step, limits, 6, 7);
        const street_id: u8 = if (street.isEmpty()) 0 else 1 + present(step.to_stay_on);
        const id: u8 = if (cue == .alert and !cross.isEmpty()) 3 else street_id + 3 * present(!cross.isEmpty());
        return self.emit(step.verbal_style, subset.phrases, sign.id orelse id, .{
            .RELATIVE_DIRECTION = direction(step, subset.relative_directions),
            .STREET_NAMES = if (cue == .succinct) null else street,
            .CROSS_STREET_NAMES = if (cue == .succinct) null else cross,
            .JUNCTION_NAME = sign.junction,
            .TOWARD_SIGN = sign.guide,
        });
    }

    fn ramp(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const sign = step.signs;
        const limits = self.cueLimits(cue);
        const branch = sign.exit_onto_streets.len != 0;
        const toward = sign.exit_toward_locations.len != 0 and (cue != .alert or !branch);
        const name = !branch and !toward and sign.exit_names.len != 0;
        const id = present(branch) + 2 * present(toward) + 4 * present(name);
        var fields: format.Fields = .{
            .BRANCH_SIGN = if (branch) try limits.signs(sign.exit_onto_streets) else .empty,
            .TOWARD_SIGN = if (toward) try limits.signs(sign.exit_toward_locations) else .empty,
            .NAME_SIGN = if (name) try limits.signs(sign.exit_names) else .empty,
        };
        if (step.type == .kRampStraight) return self.emit(step.verbal_style, self.locale.ramp_straight_verbal_subset.phrases, id, fields);
        const subset = self.locale.ramp_verbal_subset;
        fields.RELATIVE_DIRECTION = direction(step, subset.relative_directions);
        return self.emit(step.verbal_style, subset.phrases, format.rampDirectionOffset(step) + id, fields);
    }

    fn exit(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.exit_verbal_subset;
        const sign = step.signs;
        const limits = self.cueLimits(cue);
        const number = sign.exit_numbers.len != 0;
        const branch = sign.exit_onto_streets.len != 0 and (cue != .alert or !number);
        const toward = sign.exit_toward_locations.len != 0 and (cue != .alert or (!number and !branch));
        const name = sign.exit_names.len != 0 and !number and (cue != .alert or (!branch and !toward));
        const driving_side = (step.type == .kExitRight) == step.drive_on_right;
        const id = 15 * present(driving_side) + present(number) + 2 * present(branch) + 4 * present(toward) + 8 * present(name);
        return self.emit(step.verbal_style, subset.phrases, id, .{
            .RELATIVE_DIRECTION = direction(step, subset.relative_directions),
            .NUMBER_SIGN = try format.exitNumbers(sign, self.deadline),
            .BRANCH_SIGN = if (branch) try limits.signs(sign.exit_onto_streets) else .empty,
            .TOWARD_SIGN = if (toward) try limits.signs(sign.exit_toward_locations) else .empty,
            .NAME_SIGN = if (name) try limits.signs(sign.exit_names) else .empty,
        });
    }

    fn keep(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.keep_verbal_subset;
        const sign = step.signs;
        const limits = self.cueLimits(cue);
        const names_and_signs = try format.keepNames(step, &subset.empty_street_name_labels, limits);
        const number = present(sign.exit_numbers.len != 0);
        const names = 2 * present(!names_and_signs.street.isEmpty());
        const destination = 4 * present(!names_and_signs.toward.isEmpty());
        const id = if (cue == .alert)
            (if (number != 0) number else if (names != 0) names else destination)
        else
            number + names + destination;
        return self.emit(step.verbal_style, subset.phrases, id, .{
            .RELATIVE_DIRECTION = forkDirection(step, subset.relative_directions),
            .NUMBER_SIGN = if (cue == .alert and number == 0) .empty else try format.exitNumbers(sign, self.deadline),
            .STREET_NAMES = names_and_signs.street,
            .TOWARD_SIGN = names_and_signs.toward,
        });
    }

    fn keepToStayOn(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.keep_to_stay_on_verbal_subset;
        const sign = step.signs;
        const limits = self.cueLimits(cue);
        const toward = if (cue == .alert)
            .empty
        else
            try limits.signs(if (sign.guide_toward_locations.len != 0) sign.guide_toward_locations else sign.exit_toward_locations);
        const id = if (cue == .alert) 0 else present(sign.exit_numbers.len != 0) + 2 * present(!toward.isEmpty());
        return self.emit(step.verbal_style, subset.phrases, id, .{
            .RELATIVE_DIRECTION = forkDirection(step, subset.relative_directions),
            .STREET_NAMES = try format.streetNames(step, step.street_names, &subset.empty_street_name_labels, limits.count, self.deadline),
            .NUMBER_SIGN = if (cue == .alert) .empty else try format.exitNumbers(sign, self.deadline),
            .TOWARD_SIGN = toward,
        });
    }

    fn merge(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.merge_verbal_subset;
        const limits = self.cueLimits(cue);
        const street = if (cue == .succinct) .empty else try format.streetNames(step, step.street_names, &subset.empty_street_name_labels, limits.count, self.deadline);
        const relative = step.type != .kMerge;
        const guide = street.isEmpty() and step.hasGuideSign();
        const id = present(relative) + 2 * present(!street.isEmpty()) + 4 * present(guide);
        return self.emit(step.verbal_style, subset.phrases, id, .{
            .RELATIVE_DIRECTION = if (relative) direction(step, subset.relative_directions) else .empty,
            .STREET_NAMES = if (cue == .succinct) null else street,
            .TOWARD_SIGN = if (guide) try limits.guide(step.signs) else .empty,
        });
    }

    fn enterRoundabout(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.enter_roundabout_verbal_subset;
        const limits = self.cueLimits(cue);
        const sign = step.roundabout_exit_signs;
        const has_guide = sign.guide_onto_streets.len != 0 or sign.guide_toward_locations.len != 0;
        const count = step.roundabout_exit_count;
        const has_ordinal = count >= 1 and count <= subset.ordinal_values.len;
        const ordinal: Value = if (has_ordinal) .{ .text = subset.ordinal_values[count - 1] } else .empty;
        const guide: Value = if (has_guide) try limits.guide(sign) else .empty;
        if (cue == .succinct) {
            return self.emit(step.verbal_style, subset.phrases, present(has_ordinal) + 3 * present(has_guide), .{
                .ORDINAL_VALUE = ordinal,
                .TOWARD_SIGN = guide,
            });
        }
        const circle_name = try format.names(step.street_names, limits.count, self.deadline);
        const exit_name = try format.names(step.roundabout_exit_street_names, limits.count, self.deadline);
        const begin_name = try format.names(step.roundabout_exit_begin_street_names, limits.count, self.deadline);
        const has_exit = !exit_name.isEmpty() or !begin_name.isEmpty() or has_guide;
        const exit_offset: u8 = if (has_ordinal) 1 else if (has_exit) 4 else 0;
        const exit_info = if (has_guide) @as(u8, 3) else present(!exit_name.isEmpty()) + present(!begin_name.isEmpty());
        return self.emit(step.verbal_style, subset.phrases, 8 * present(!circle_name.isEmpty()) + exit_offset + exit_info, .{
            .ORDINAL_VALUE = ordinal,
            .STREET_NAMES = circle_name,
            .TOWARD_SIGN = guide,
            .ROUNDABOUT_EXIT_STREET_NAMES = exit_name,
            .ROUNDABOUT_EXIT_BEGIN_STREET_NAMES = begin_name,
        });
    }

    fn exitRoundabout(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.exit_roundabout_verbal_subset;
        const limits = self.cueLimits(cue);
        const street = if (cue == .succinct) format.StreetPair{} else try format.startNames(step, &subset.empty_street_name_labels, limits.count, self.deadline);
        const guide = step.hasGuideSign();
        const id = if (guide) @as(u8, 3) else present(!street.street.isEmpty()) + present(!street.begin.isEmpty());
        return self.emit(step.verbal_style, subset.phrases, id, .{
            .STREET_NAMES = if (cue == .succinct) null else street.street,
            .BEGIN_STREET_NAMES = if (cue == .succinct) null else street.begin,
            .TOWARD_SIGN = if (guide) try limits.guide(step.signs) else .empty,
        });
    }

    fn enterFerry(self: *const Builder, step: *const Maneuver, cue: Cue) ![]const u8 {
        const subset = self.locale.enter_ferry_verbal_subset;
        const limits = self.cueLimits(cue);
        const street = try format.streetNames(step, step.street_names, &subset.empty_street_name_labels, limits.count, self.deadline);
        const guide = step.hasGuideSign();
        const id: u8 = if (guide) 3 else if (street.isEmpty()) 0 else if (try self.hasFerryLabel(step, street, subset.ferry_label)) 1 else 2;
        return self.emit(step.verbal_style, subset.phrases, id, .{
            .STREET_NAMES = street,
            .FERRY_LABEL = .{ .text = subset.ferry_label },
            .TOWARD_SIGN = if (guide) try limits.guide(step.signs) else .empty,
        });
    }

    fn hasFerryLabel(self: *const Builder, step: *const Maneuver, street: Value, label: []const u8) !bool {
        if (step.verbal_style == .generic and !self.text_formatter.markup_formatter.enabled) return street.endsWithLabel(label);
        var spoken = io.Writer.Allocating.init(self.arena);
        defer spoken.deinit();
        try street.write(&spoken.writer, self.context(step.verbal_style));
        return (Value{ .text = spoken.written() }).endsWithLabel(label);
    }

    fn post(self: *const Builder, step: *const Maneuver, include_street_names: bool) ![]const u8 {
        const subset = self.locale.post_transition_verbal_subset;
        const eligible = include_street_names and !step.contains_obvious_maneuver and !step.has_long_street_name;
        const names = if (step.has_combined_enter_exit_roundabout) step.roundabout_exit_street_names else step.street_names;
        const street = if (eligible) try format.streetNames(step, names, &subset.empty_street_name_labels, 2, self.deadline) else .empty;
        return self.emit(step.verbal_style, subset.phrases, present(!street.isEmpty()), .{
            .STREET_NAMES = street,
            .LENGTH = self.length(step, .from(subset)),
        });
    }

    fn approach(self: *const Builder, length_in_units: f32, cue: []const u8) ![]const u8 {
        const subset = self.locale.approach_verbal_alert_subset;
        return self.emit(.generic, subset.phrases, 0, .{
            .LENGTH = .{ .length = .fromDistance(length_in_units, self.units, .from(subset)) },
            .CURRENT_VERBAL_CUE = .{ .text = cue },
        });
    }

    fn multiCue(self: *const Builder, step: *Maneuver, next: *const Maneuver) !void {
        const following = if (next.verbal_transition_alert_instruction.len != 0)
            next.verbal_transition_alert_instruction
        else
            next.verbal_pre_transition_instruction;
        if (step.verbal_succinct_transition_instruction.len != 0) {
            step.verbal_succinct_transition_instruction = try self.combineCues(step, step.verbal_succinct_transition_instruction, following);
        }
        step.verbal_pre_transition_instruction = try self.combineCues(step, step.verbal_pre_transition_instruction, following);
    }

    fn combineCues(self: *const Builder, step: *const Maneuver, first: []const u8, second: []const u8) ![]const u8 {
        const subset = self.locale.verbal_multi_cue_subset;
        return self.emit(step.verbal_style, subset.phrases, present(step.distant_verbal_multi_cue), .{
            .CURRENT_VERBAL_CUE = .{ .text = first },
            .NEXT_VERBAL_CUE = .{ .text = second },
            .LENGTH = self.length(step, .from(self.locale.post_transition_verbal_subset)),
        });
    }

    fn length(self: *const Builder, step: *const Maneuver, labels: distance.Labels) Value {
        return .{ .length = .forManeuver(step, self.units, labels) };
    }

    fn cueLimits(self: *const Builder, cue: Cue) format.SignLimits {
        return .{ .count = cue.limit(), .deadline = self.deadline };
    }

    fn context(self: *const Builder, style: verbal_text.Style) format.Context {
        return .{
            .deadline = self.deadline,
            .speech = .{ .text_formatter = self.text_formatter, .style = style, .numbers = self.local_format.numbers },
        };
    }

    fn emit(self: *const Builder, style: verbal_text.Style, phrases: dictionary.types.PhraseMap, id: u8, fields: format.Fields) ![]const u8 {
        var out = io.Writer.Allocating.init(self.arena);
        errdefer out.deinit();
        try format.writePhrase(&out.writer, phrases.get(id) orelse unreachable, fields, self.context(style));
        const bytes = try out.toOwnedSlice();
        if (std.mem.eql(u8, self.locale.language_tag, "it-IT")) return bytes[0..try format.articulateItalian(bytes, self.deadline)];
        return bytes;
    }
};

fn postStreetNames(step: *const Maneuver) ?bool {
    return switch (step.type) {
        .kStart,
        .kStartLeft,
        .kStartRight,
        .kFerryExit,
        .kPostTransitConnectionDestination,
        .kBecomes,
        .kSlightLeft,
        .kSlightRight,
        .kLeft,
        .kRight,
        .kSharpLeft,
        .kSharpRight,
        .kRoundaboutExit,
        => step.begin_street_names.len != 0,
        .kUturnLeft, .kUturnRight, .kMerge, .kMergeLeft, .kMergeRight, .kFerryEnter, .kStepsEnter => false,
        .kRampStraight, .kRampLeft, .kRampRight, .kExitLeft, .kExitRight => if (step.length_km > 2 or step.contains_obvious_maneuver or step.has_collapsed_merge_maneuver) false else null,
        .kStayLeft, .kStayRight, .kStayStraight => if (!step.ramp or step.has_collapsed_merge_maneuver or step.length_km > 2) false else null,
        .kRoundaboutEnter => if (step.has_combined_enter_exit_roundabout) step.roundabout_exit_begin_street_names.len != 0 else null,
        .kElevatorEnter => if (step.node_type == .kElevator) false else null,
        .kDestination,
        .kDestinationLeft,
        .kDestinationRight,
        .kEscalatorEnter,
        .kBuildingEnter,
        .kBuildingExit,
        .kLevelChange,
        .kParkVehicle,
        .kTransit,
        .kTransitTransfer,
        .kTransitRemainOn,
        .kTransitConnectionStart,
        .kTransitConnectionDestination,
        .kTransitConnectionTransfer,
        => null,
        else => if (step.node_type == null) false else null,
    };
}

/// Distance is in the request's units, as it is for the voice serializer.
pub fn approachAlert(arena: std.mem.Allocator, options: Options, length_in_units: f32, verbal_cue: []const u8, deadline: io.Deadline) ![]const u8 {
    var speech = verbal_text.Formatter.init(arena, options.markup_formatter, deadline);
    defer speech.deinit();
    const builder = Builder.init(arena, options.language, options.units, .{}, &speech, deadline);
    return builder.approach(length_in_units, verbal_cue);
}

pub const TransitTimeCue = enum { depart, arrive };

/// Render just the schedule-time phrasing shared by transit directions.
pub fn transitTimeCue(arena: std.mem.Allocator, language: []const u8, cue: TransitTimeCue, stop: []const u8, timestamp: []const u8, deadline: io.Deadline) ![]const u8 {
    var speech = verbal_text.Formatter.init(arena, .{}, deadline);
    defer speech.deinit();
    const builder = Builder.init(arena, language, .kilometers, .{}, &speech, deadline);
    var time_buffer: [32]u8 = undefined;
    var time_writer = io.Writer.fixed(&time_buffer);
    try builder.local_format.writeLocalTime(&time_writer, timestamp);
    const subset = switch (cue) {
        .depart => builder.locale.depart_verbal_subset,
        .arrive => builder.locale.arrive_verbal_subset,
    };
    return builder.emit(.generic, subset.phrases, present(stop.len != 0), .{
        .TRANSIT_STOP = .{ .text = stop },
        .TIME = .{ .text = time_writer.buffered() },
    });
}

test "Valhalla route verbal instruction snapshots" {
    const fixtures = @import("instruction_fixtures.zig");
    const snapshot = @import("reference_snapshot.zig");
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const arena = allocator.allocator();
    for (&fixtures.visual) |fixture| {
        if (fixture.upstream_disabled) continue;
        _ = allocator.reset(.retain_capacity);
        var speech = verbal_text.Formatter.init(arena, .{}, .none);
        defer speech.deinit();
        const builder = Builder.init(arena, fixture.language, fixture.units, fixture.destination, &speech, .none);
        const steps = try arena.alloc(Maneuver, fixture.steps.len);
        for (steps, fixture.steps) |*step, expected| {
            step.* = expected.maneuver;
            step.instruction = expected.text;
        }
        try builder.annotate(steps);
        for (steps, fixture.steps, 0..) |step, expected, index| {
            const actual = [_][]const u8{
                step.verbal_succinct_transition_instruction,
                step.verbal_transition_alert_instruction,
                step.verbal_pre_transition_instruction,
                step.verbal_post_transition_instruction,
            };
            const goldens = [_][]const u8{ expected.speech.succinct, expected.speech.alert, expected.speech.pre, expected.speech.post };
            for (actual, goldens, [_][]const u8{ "succinct", "alert", "pre", "post" }) |output, golden, kind| {
                snapshot.match(fixture.name, golden, output) catch |err| {
                    std.debug.print("{s}, step {d} ({s})\n", .{ fixture.name, index, kind });
                    return err;
                };
            }
        }
    }
}

test "Valhalla round distances for spoken post, approaching and multi-cue instructions" {
    const fixtures = @import("instruction_fixtures.zig");
    const snapshot = @import("reference_snapshot.zig");
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const arena = allocator.allocator();
    var speech = verbal_text.Formatter.init(arena, .{}, .none);
    defer speech.deinit();
    for (&fixtures.post) |*fixture| {
        const builder = Builder.init(arena, "en-US", fixture.units, .{}, &speech, .none);
        try snapshot.match("TestFormVerbalPostTransitionInstruction", fixture.expected, try builder.post(&fixture.maneuver, fixture.include_street_names));
    }
    for (fixtures.approach) |fixture| {
        try snapshot.match("TestFormVerbalAlertApproachInstruction", fixture.expected, try approachAlert(arena, .{ .units = fixture.units }, fixture.distance, fixture.cue, .none));
    }
    for (&fixtures.multi_cue) |*fixture| {
        const builder = Builder.init(arena, "en-US", fixture.units, .{}, &speech, .none);
        try snapshot.match("TestFormVerbalMultiCue", fixture.expected, try builder.combineCues(&fixture.maneuver, fixture.first, fixture.next));
    }
}

test "Valhalla localized schedule time phrases" {
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const arena = allocator.allocator();
    try std.testing.expectEqualStrings("Depart at 8:02 AM from 8 St - NYU.", try transitTimeCue(arena, "en-US", .depart, "8 St - NYU", "2015-05-06T08:02-05:00", .none));
    try std.testing.expectEqualStrings("Arrive at 8:08 AM at 34 St - Herald Sq.", try transitTimeCue(arena, "en-US", .arrive, "34 St - Herald Sq", "2015-05-06T08:08-05:00", .none));
    try std.testing.expectEqualStrings("In 1,000 feet, Turn right.", try approachAlert(arena, .{ .units = .miles }, 1000.0 / 5280.0, "Turn right.", .none));
}

// Ported from test/gurka/test_route_with_pronunciations.cc.
test "Valhalla pronunciations in street, exit, guide and junction names" {
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const arena = allocator.allocator();
    var speech = verbal_text.Formatter.init(arena, .{
        .enabled = true,
        .phoneme_format = "<TEXTUAL_STRING> (<span class=<QUOTES>phoneme<QUOTES>>/<VERBAL_STRING>/</span>)",
    }, .none);
    defer speech.deinit();
    const builder = Builder.init(arena, "en-US", .kilometers, .{}, &speech, .none);
    const exit_sign: trip.SignElement = .{ .text = "126B", .pronunciation = .{ .alphabet = .kIpa, .value = "1 26bi" } };
    const route: trip.SignElement = .{ .text = "SR 37", .pronunciation = .{ .alphabet = .kIpa, .value = "ˈsinjər 37" } };
    const road: trip.SignElement = .{ .text = "Lancaster Road", .pronunciation = .{ .alphabet = .kIpa, .value = "ˈlæŋkəstər ˈɹoʊd" } };
    const granville: trip.SignElement = .{ .text = "Granville", .pronunciation = .{ .alphabet = .kIpa, .value = "ˈgɹænvɪl" } };
    const lancaster: trip.SignElement = .{ .text = "Lancaster", .pronunciation = .{ .alphabet = .kIpa, .value = "ˈlæŋkəstər" } };
    const cases = [_]struct {
        step: Maneuver,
        succinct: []const u8 = "",
        alert: []const u8,
        pre: []const u8,
        post: []const u8 = "",
    }{
        .{
            .step = .{ .type = .kExitRight, .verbal_style = .us, .signs = .{
                .exit_numbers = &.{exit_sign},
                .exit_onto_streets = &.{ route, road },
                .exit_toward_locations = &.{ granville, lancaster },
            } },
            .alert = "Take exit 126B (<span class=\"phoneme\">/1 26bi/</span>).",
            .pre = "Take exit 126B (<span class=\"phoneme\">/1 26bi/</span>) onto SR 37 (<span class=\"phoneme\">/ˈsinjər 37/</span>), Lancaster Road (<span class=\"phoneme\">/ˈlæŋkəstər ˈɹoʊd/</span>) toward Granville (<span class=\"phoneme\">/ˈgɹænvɪl/</span>), Lancaster (<span class=\"phoneme\">/ˈlæŋkəstər/</span>).",
        },
        .{
            .step = .{
                .type = .kRight,
                .verbal_style = .us,
                .street_names = &.{
                    .{ .value = road.text, .is_route_number = false, .pronunciation = road.pronunciation },
                    .{ .value = route.text, .is_route_number = true, .pronunciation = route.pronunciation },
                },
                .length_km = 0.4,
            },
            .succinct = "Turn right.",
            .alert = "Turn right onto Lancaster Road (<span class=\"phoneme\">/ˈlæŋkəstər ˈɹoʊd/</span>).",
            .pre = "Turn right onto Lancaster Road (<span class=\"phoneme\">/ˈlæŋkəstər ˈɹoʊd/</span>), SR 37 (<span class=\"phoneme\">/ˈsinjər 37/</span>).",
            .post = "Continue for 400 meters.",
        },
        .{
            .step = .{ .type = .kExitRight, .verbal_style = .us, .signs = .{
                .exit_numbers = &.{exit_sign},
                .exit_toward_locations = &.{
                    .{ .text = "I 80", .pronunciation = .{ .alphabet = .kIpa, .value = "aɪ 80" } },
                    .{ .text = "Main Street", .pronunciation = .{ .alphabet = .kIpa, .value = "meɪn strit" } },
                },
            } },
            .alert = "Take exit 126B (<span class=\"phoneme\">/1 26bi/</span>).",
            .pre = "Take exit 126B (<span class=\"phoneme\">/1 26bi/</span>) toward I 80 (<span class=\"phoneme\">/aɪ 80/</span>), Main Street (<span class=\"phoneme\">/meɪn strit/</span>).",
        },
        .{
            .step = .{ .type = .kRight, .verbal_style = .us, .length_km = 0.5, .signs = .{
                .guide_onto_streets = &.{.{ .text = "Granville Road", .pronunciation = .{ .alphabet = .kIpa, .value = "ˈgɹænvɪl ˈɹoʊd" } }},
                .guide_toward_locations = &.{granville},
            } },
            .succinct = "Turn right toward Granville Road (<span class=\"phoneme\">/ˈgɹænvɪl ˈɹoʊd/</span>), Granville (<span class=\"phoneme\">/ˈgɹænvɪl/</span>).",
            .alert = "Turn right toward Granville Road (<span class=\"phoneme\">/ˈgɹænvɪl ˈɹoʊd/</span>).",
            .pre = "Turn right toward Granville Road (<span class=\"phoneme\">/ˈgɹænvɪl ˈɹoʊd/</span>), Granville (<span class=\"phoneme\">/ˈgɹænvɪl/</span>).",
            .post = "Continue for 500 meters.",
        },
        .{
            .step = .{ .type = .kLeft, .verbal_style = .us, .length_km = 0.4, .signs = .{
                .junction_names = &.{.{ .text = "M Junction", .pronunciation = .{ .alphabet = .kIpa, .value = "ɛm ˈʤʌŋkʃən" } }},
            } },
            .succinct = "Turn left at M Junction (<span class=\"phoneme\">/ɛm ˈʤʌŋkʃən/</span>).",
            .alert = "Turn left at M Junction (<span class=\"phoneme\">/ɛm ˈʤʌŋkʃən/</span>).",
            .pre = "Turn left at M Junction (<span class=\"phoneme\">/ɛm ˈʤʌŋkʃən/</span>).",
            .post = "Continue for 400 meters.",
        },
    };
    for (&cases) |case| {
        var steps = [_]Maneuver{case.step};
        try builder.annotate(&steps);
        const step = steps[0];
        try std.testing.expectEqualStrings(case.succinct, step.verbal_succinct_transition_instruction);
        try std.testing.expectEqualStrings(case.alert, step.verbal_transition_alert_instruction);
        try std.testing.expectEqualStrings(case.pre, step.verbal_pre_transition_instruction);
        try std.testing.expectEqualStrings(case.post, step.verbal_post_transition_instruction);
    }
}
