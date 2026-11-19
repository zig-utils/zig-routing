// Ported from src/mjolnir/pbfgraphparser.cc and src/mjolnir/directededgebuilder.cc.
// Test-only accessor for Valhalla 3.9.3 parseways artifacts.
#include <valhalla/mjolnir/osmway.h>

#include <bit>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using valhalla::mjolnir::OSMWay;

using namespace valhalla::baldr;

static_assert(std::endian::native == std::endian::little);

uint32_t access(const OSMWay& way, bool forward) {
    uint32_t bits = 0;
    bits |= (forward ? way.auto_forward() : way.auto_backward()) ? kAutoAccess : 0;
    bits |= (forward ? way.truck_forward() : way.truck_backward()) ? kTruckAccess : 0;
    bits |= (forward ? way.pedestrian_forward() : way.pedestrian_backward()) ? kPedestrianAccess : 0;
    bits |= (forward ? way.bike_forward() : way.bike_backward()) ? kBicycleAccess : 0;
    bits |= (forward ? way.taxi_forward() : way.taxi_backward()) ? kTaxiAccess : 0;
    bits |= (forward ? way.bus_forward() : way.bus_backward()) ? kBusAccess : 0;
    bits |= (forward ? way.emergency_forward() : way.emergency_backward()) ? kEmergencyAccess : 0;
    bits |= (forward ? way.hov_forward() : way.hov_backward()) ? kHOVAccess : 0;
    bits |= (forward ? way.moped_forward() : way.moped_backward()) ? kMopedAccess : 0;
    bits |= (forward ? way.motorcycle_forward() : way.motorcycle_backward()) ? kMotorcycleAccess : 0;
    if (way.use() != Use::kSteps && way.use() != Use::kLadder && way.use() != Use::kConstruction &&
        way.surface() != Surface::kImpassable) {
        if (way.wheelchair_tag() ? way.wheelchair() : (bits & kPedestrianAccess)) bits |= kWheelchairAccess;
    }
    return bits;
}

uint32_t u32(std::ifstream& f) {
    uint32_t value{};
    f.read(reinterpret_cast<char*>(&value), sizeof(value));
    return value;
}

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    std::ifstream ways(argv[1], std::ios::binary), names(argv[2], std::ios::binary);
    if (!ways || !names) return 3;
    const uint32_t count = u32(names);
    std::vector<uint32_t> lengths(count);
    for (auto& length : lengths) length = u32(names);
    const uint32_t total = u32(names);
    std::vector<std::string> strings(1);
    uint64_t bytes = 0;
    for (uint32_t len : lengths) {
        if (!len) return 4;
        std::string text(len, '\0');
        names.read(text.data(), text.size());
        if (!names || text.back()) return 4;
        text.pop_back();
        strings.push_back(std::move(text));
        bytes += len;
    }
    if (!names || bytes != total) return 4;
    auto write = [&](uint32_t id) {
        constexpr char digits[] = "0123456789abcdef";
        std::cout << '\t';
        for (const unsigned char byte : strings.at(id)) {
            std::cout << digits[byte >> 4] << digits[byte & 15];
        }
    };

    std::cout << "id"
                 "\tn:road_class\tn:use\tn:surface\tn:forward_access\tn:backward_access"
                 "\tn:speed\tn:speed_limit\tn:forward_speed\tn:backward_speed\tn:truck_speed"
                 "\tn:lanes\tn:forward_lanes\tn:backward_lanes\tn:lane_left\tn:lane_right"
                 "\tn:sac_scale\tn:bike_network\tb:oneway\tb:oneway_reverse\tb:roundabout"
                 "\tb:link\tb:turn_channel\tb:ferry\tb:rail\tb:pedestrian_area\tb:bridge"
                 "\tb:tunnel\tb:lit\tb:indoor\tb:destination_only\tb:destination_only_hgv"
                 "\tb:no_thru_traffic\tb:tagged_speed\tb:forward_tagged_speed"
                 "\tb:backward_tagged_speed\tb:tagged_lanes\tb:forward_tagged_lanes"
                 "\tb:backward_tagged_lanes\tb:wheelchair\tb:wheelchair_tag\tb:sidewalk_left"
                 "\tb:sidewalk_right\tb:shoulder_left\tb:shoulder_right"
                 "\tb:tagged_internal_intersection\tb:left_opposite\tb:right_opposite"
                 "\tb:use_sidepath\tb:dismount\ts:name\ts:name_language\ts:alt_name"
                 "\ts:alt_name_language\ts:official_name\ts:official_name_language\ts:ref"
                 "\ts:ref_language\ts:int_ref\ts:int_ref_language\ts:tunnel_name"
                 "\ts:tunnel_name_language\ts:destination\ts:destination_language"
                 "\ts:destination_forward\ts:destination_forward_language"
                 "\ts:destination_backward\ts:destination_backward_language\ts:destination_ref"
                 "\ts:destination_ref_language\ts:destination_ref_to"
                 "\ts:destination_ref_to_language\ts:destination_street"
                 "\ts:destination_street_language\ts:destination_street_to"
                 "\ts:destination_street_to_language\ts:junction_ref\ts:junction_ref_language"
                 "\ts:junction_name\ts:junction_name_language\ts:destination_int_ref"
                 "\ts:destination_int_ref_to\ts:turn_lanes_forward\ts:turn_lanes_backward\n";
    OSMWay way;
    while (ways.read(reinterpret_cast<char*>(&way), sizeof(way))) {
        std::cout << way.way_id();
        std::cout << '\t' << unsigned(way.road_class());
        std::cout << '\t' << unsigned(way.use());
        std::cout << '\t' << unsigned(way.surface());
        std::cout << '\t' << access(way, true);
        std::cout << '\t' << access(way, false);
        std::cout << '\t' << unsigned(way.speed());
        std::cout << '\t' << unsigned(way.speed_limit());
        std::cout << '\t' << unsigned(way.forward_speed());
        std::cout << '\t' << unsigned(way.backward_speed());
        std::cout << '\t' << unsigned(way.truck_speed());
        std::cout << '\t' << way.lanes();
        std::cout << '\t' << way.forward_lanes();
        std::cout << '\t' << way.backward_lanes();
        std::cout << '\t' << unsigned(way.cyclelane_left());
        std::cout << '\t' << unsigned(way.cyclelane_right());
        std::cout << '\t' << unsigned(way.sac_scale());
        std::cout << '\t' << way.bike_network();
        std::cout << '\t' << way.oneway();
        std::cout << '\t' << way.oneway_reverse();
        std::cout << '\t' << way.roundabout();
        std::cout << '\t' << way.link();
        std::cout << '\t' << way.turn_channel();
        std::cout << '\t' << way.ferry();
        std::cout << '\t' << way.rail();
        std::cout << '\t' << way.area();
        std::cout << '\t' << way.bridge();
        std::cout << '\t' << way.tunnel();
        std::cout << '\t' << way.lit();
        std::cout << '\t' << way.indoor();
        std::cout << '\t' << way.destination_only();
        std::cout << '\t' << way.destination_only_hgv();
        std::cout << '\t' << way.no_thru_traffic();
        std::cout << '\t' << way.tagged_speed();
        std::cout << '\t' << way.forward_tagged_speed();
        std::cout << '\t' << way.backward_tagged_speed();
        std::cout << '\t' << way.tagged_lanes();
        std::cout << '\t' << way.forward_tagged_lanes();
        std::cout << '\t' << way.backward_tagged_lanes();
        std::cout << '\t' << way.wheelchair();
        std::cout << '\t' << way.wheelchair_tag();
        std::cout << '\t' << way.sidewalk_left();
        std::cout << '\t' << way.sidewalk_right();
        std::cout << '\t' << way.shoulder_left();
        std::cout << '\t' << way.shoulder_right();
        std::cout << '\t' << way.internal();
        std::cout << '\t' << way.cyclelane_left_opposite();
        std::cout << '\t' << way.cyclelane_right_opposite();
        std::cout << '\t' << way.use_sidepath();
        std::cout << '\t' << way.dismount();
        write(way.name_index());
        write(way.name_lang_index());
        write(way.alt_name_index());
        write(way.alt_name_lang_index());
        write(way.official_name_index());
        write(way.official_name_lang_index());
        write(way.ref_index());
        write(way.ref_lang_index());
        write(way.int_ref_index());
        write(way.int_ref_lang_index());
        write(way.tunnel_name_index());
        write(way.tunnel_name_lang_index());
        write(way.destination_index());
        write(way.destination_lang_index());
        write(way.destination_forward_index());
        write(way.destination_forward_lang_index());
        write(way.destination_backward_index());
        write(way.destination_backward_lang_index());
        write(way.destination_ref_index());
        write(way.destination_ref_lang_index());
        write(way.destination_ref_to_index());
        write(way.destination_ref_to_lang_index());
        write(way.destination_street_index());
        write(way.destination_street_lang_index());
        write(way.destination_street_to_index());
        write(way.destination_street_to_lang_index());
        write(way.junction_ref_index());
        write(way.junction_ref_lang_index());
        write(way.junction_name_index());
        write(way.junction_name_lang_index());
        write(way.destination_int_ref_index());
        write(way.destination_int_ref_to_index());
        write(way.fwd_turn_lanes_index());
        write(way.bwd_turn_lanes_index());
        std::cout << '\n';
    }
    if (!ways.eof() || ways.gcount()) return 5;
}
