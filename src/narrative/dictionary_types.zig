// Ported from valhalla/odin/narrative_dictionary.h (Valhalla 3.9.3).
const Text = []const u8;
const EmptyStreetNameLabels = [7]Text;
const BuildingStreetNameLabels = [4]Text;
const CardinalDirections = [8]Text;
const RelativeDirections = [2]Text;
const ForkDirections = [3]Text;
const MetricLengths = [4]Text;
const UsCustomaryLengths = [6]Text;
const Ordinals = [10]Text;
const TransitNames = [8]Text;

pub const Phrase = struct { id: u8, text: Text };

pub const PhraseMap = struct {
    entries: []const Phrase,

    pub fn get(self: PhraseMap, id: u8) ?Text {
        var low: usize = 0;
        var high = self.entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = self.entries[middle];
            if (entry.id == id) return entry.text;
            if (entry.id < id) low = middle + 1 else high = middle;
        }
        return null;
    }
};

pub const PluralCategory = enum { zero, one, two, few, many, other };

pub const TransitStopCountLabels = struct {
    zero: ?Text = null,
    one: ?Text = null,
    two: ?Text = null,
    few: ?Text = null,
    many: ?Text = null,
    other: ?Text = null,

    pub fn get(self: TransitStopCountLabels, category: PluralCategory) ?Text {
        return switch (category) {
            inline else => |choice| @field(self, @tagName(choice)),
        };
    }
};

pub const PhraseSet = struct { phrases: PhraseMap };
pub const StartSubset = struct { phrases: PhraseMap, cardinal_directions: CardinalDirections, empty_street_name_labels: EmptyStreetNameLabels };
pub const StartVerbalSubset = struct { phrases: PhraseMap, cardinal_directions: CardinalDirections, empty_street_name_labels: EmptyStreetNameLabels, metric_lengths: MetricLengths, us_customary_lengths: UsCustomaryLengths };
pub const DestinationSubset = struct { phrases: PhraseMap, relative_directions: RelativeDirections };
pub const ContinueSubset = struct { phrases: PhraseMap, empty_street_name_labels: EmptyStreetNameLabels };
pub const ContinueVerbalSubset = struct { phrases: PhraseMap, empty_street_name_labels: EmptyStreetNameLabels, metric_lengths: MetricLengths, us_customary_lengths: UsCustomaryLengths };
pub const TurnSubset = struct { phrases: PhraseMap, relative_directions: RelativeDirections, empty_street_name_labels: EmptyStreetNameLabels };
pub const RampSubset = struct { phrases: PhraseMap, relative_directions: RelativeDirections };
pub const KeepSubset = struct { phrases: PhraseMap, relative_directions: ForkDirections, empty_street_name_labels: EmptyStreetNameLabels };
pub const EnterFerrySubset = struct { phrases: PhraseMap, empty_street_name_labels: EmptyStreetNameLabels, ferry_label: Text };
pub const EnterRoundaboutSubset = struct { phrases: PhraseMap, ordinal_values: Ordinals, empty_street_name_labels: EmptyStreetNameLabels };
pub const TransitConnectionSubset = struct { phrases: PhraseMap, station_label: Text };
pub const TransitSubset = struct { phrases: PhraseMap, empty_transit_name_labels: TransitNames };
pub const TransitStopSubset = struct { phrases: PhraseMap, empty_transit_name_labels: TransitNames, transit_stop_count_labels: TransitStopCountLabels };
pub const PostTransitionVerbalSubset = struct { phrases: PhraseMap, empty_street_name_labels: EmptyStreetNameLabels, metric_lengths: MetricLengths, us_customary_lengths: UsCustomaryLengths };
pub const PostTransitionTransitVerbalSubset = struct { phrases: PhraseMap, transit_stop_count_labels: TransitStopCountLabels };
pub const VerbalMultiCueSubset = struct { phrases: PhraseMap, metric_lengths: MetricLengths, us_customary_lengths: UsCustomaryLengths };
pub const ApproachVerbalAlertSubset = struct { phrases: PhraseMap, metric_lengths: MetricLengths, us_customary_lengths: UsCustomaryLengths };
pub const PassSubset = struct { phrases: PhraseMap, object_labels: [3]Text };
pub const EnterBuildingSubset = struct { phrases: PhraseMap, empty_street_name_labels: BuildingStreetNameLabels };
pub const ExitBuildingSubset = struct { phrases: PhraseMap, empty_street_name_labels: BuildingStreetNameLabels };

pub const NarrativeDictionary = struct {
    language_tag: Text,
    posix_locale: Text,
    start_subset: StartSubset,
    start_verbal_subset: StartVerbalSubset,
    destination_subset: DestinationSubset,
    destination_verbal_alert_subset: DestinationSubset,
    destination_verbal_subset: DestinationSubset,
    becomes_subset: PhraseSet,
    becomes_verbal_subset: PhraseSet,
    continue_subset: ContinueSubset,
    continue_verbal_alert_subset: ContinueSubset,
    continue_verbal_subset: ContinueVerbalSubset,
    bear_subset: TurnSubset,
    bear_verbal_subset: TurnSubset,
    turn_subset: TurnSubset,
    turn_verbal_subset: TurnSubset,
    sharp_subset: TurnSubset,
    sharp_verbal_subset: TurnSubset,
    uturn_subset: TurnSubset,
    uturn_verbal_subset: TurnSubset,
    ramp_straight_subset: PhraseSet,
    ramp_straight_verbal_subset: PhraseSet,
    ramp_subset: RampSubset,
    ramp_verbal_subset: RampSubset,
    exit_subset: RampSubset,
    exit_verbal_subset: RampSubset,
    exit_visual_subset: PhraseSet,
    keep_subset: KeepSubset,
    keep_verbal_subset: KeepSubset,
    keep_to_stay_on_subset: KeepSubset,
    keep_to_stay_on_verbal_subset: KeepSubset,
    merge_subset: TurnSubset,
    merge_verbal_subset: TurnSubset,
    enter_roundabout_subset: EnterRoundaboutSubset,
    enter_roundabout_verbal_subset: EnterRoundaboutSubset,
    exit_roundabout_subset: ContinueSubset,
    exit_roundabout_verbal_subset: ContinueSubset,
    enter_ferry_subset: EnterFerrySubset,
    enter_ferry_verbal_subset: EnterFerrySubset,
    transit_connection_start_subset: TransitConnectionSubset,
    transit_connection_start_verbal_subset: TransitConnectionSubset,
    transit_connection_transfer_subset: TransitConnectionSubset,
    transit_connection_transfer_verbal_subset: TransitConnectionSubset,
    transit_connection_destination_subset: TransitConnectionSubset,
    transit_connection_destination_verbal_subset: TransitConnectionSubset,
    depart_subset: PhraseSet,
    depart_verbal_subset: PhraseSet,
    arrive_subset: PhraseSet,
    arrive_verbal_subset: PhraseSet,
    transit_subset: TransitStopSubset,
    transit_verbal_subset: TransitSubset,
    transit_remain_on_subset: TransitStopSubset,
    transit_remain_on_verbal_subset: TransitSubset,
    transit_transfer_subset: TransitStopSubset,
    transit_transfer_verbal_subset: TransitSubset,
    post_transition_verbal_subset: PostTransitionVerbalSubset,
    post_transition_transit_verbal_subset: PostTransitionTransitVerbalSubset,
    verbal_multi_cue_subset: VerbalMultiCueSubset,
    approach_verbal_alert_subset: ApproachVerbalAlertSubset,
    pass_subset: PassSubset,
    elevator_subset: PhraseSet,
    steps_subset: PhraseSet,
    escalator_subset: PhraseSet,
    level_change_subset: PhraseSet,
    enter_building_subset: EnterBuildingSubset,
    exit_building_subset: ExitBuildingSubset,
    park_vehicle_subset: PhraseSet,
};

// Prefixing the bytes by one keeps different lengths distinct.
pub fn shortTagKey(tag: []const u8) u64 {
    var code: u64 = 1;
    for (tag) |byte| code = (code << 8) | byte;
    return code;
}
