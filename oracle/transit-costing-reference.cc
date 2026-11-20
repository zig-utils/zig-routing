// Samples the pinned Valhalla library's transit and pedestrian cost options.
#include <valhalla/baldr/directededge.h>
#include <valhalla/baldr/rapidjson_utils.h>
#include <valhalla/baldr/transitdeparture.h>
#include <valhalla/sif/pedestriancost.h>
#include <valhalla/sif/transitcost.h>

#include <array>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <sstream>
#include <stdexcept>

namespace {

namespace baldr = valhalla::baldr;
namespace sif = valhalla::sif;

void write_cost(const sif::Cost& cost) {
  std::cout << "{\"cost\":" << cost.cost << ",\"secs\":" << cost.secs << '}';
}

void emit(const std::string& input,
          baldr::Use use,
          const char* use_name,
          uint32_t depart,
          uint32_t current,
          uint32_t elapsed,
          bool from_walk) {
  rapidjson::Document document;
  document.Parse(input.c_str());
  if (document.HasParseError()) {
    throw std::runtime_error("invalid sample options");
  }
  google::protobuf::RepeatedPtrField<valhalla::CodedDescription> warnings;
  valhalla::Costing transit_options, pedestrian_options;
  sif::ParsePedestrianCostOptions(document, "/pedestrian", &pedestrian_options, warnings);
  sif::ParseTransitCostOptions(document, "/transit", &transit_options, warnings);
  const auto transit = sif::CreateTransitCost(transit_options);
  const auto pedestrian = sif::CreatePedestrianCost(pedestrian_options);
  const auto& options = transit_options.options();

  baldr::DirectedEdge edge;
  edge.set_use(use);
  const baldr::TransitDeparture departure(0, 1, 0, 0, 0, depart, elapsed, 0, true, true);
  const auto prior_mode = from_walk ? sif::TravelMode::kPedestrian : sif::TravelMode::kPublicTransit;
  const sif::EdgeLabel prior(0, baldr::GraphId{}, &edge, sif::Cost{}, 0, prior_mode, 0, 0, false,
                            false, sif::InternalTurn::kNoTurn);
  std::cout << "{\"options\":" << input << ",\"use\":\"" << use_name << "\",\"departure\":" << depart
            << ",\"current\":" << current << ",\"elapsed\":" << elapsed
            << ",\"from_walk\":" << from_walk << ",\"warnings\":" << warnings.size()
            << ",\"mode_factor\":" << transit->GetModeFactor()
            << ",\"walking_factor\":" << pedestrian->GetModeFactor()
            << ",\"walking_limit\":"
            << pedestrian_options.options().transit_start_end_max_distance()
            << ",\"transfer_limit\":" << pedestrian->GetMaxTransferDistanceMM()
            << ",\"use_bus\":" << options.use_bus() << ",\"use_rail\":" << options.use_rail()
            << ",\"use_transfers\":" << options.use_transfers()
            << ",\"wheelchair\":" << transit->wheelchair() << ",\"bicycle\":" << transit->bicycle()
            << ",\"edge\":";
  write_cost(transit->EdgeCost(&edge, &departure, current));
  std::cout << ",\"transition\":";
  write_cost(transit->TransitionCost(&edge, nullptr, prior, {}, {}));
  std::cout << ",\"transfer\":";
  write_cost(transit->TransferCost());
  std::cout << ",\"default_transfer\":";
  write_cost(transit->DefaultTransferCost());
  std::cout << "}\n";
}

} // namespace

int main() {
  std::cout << std::setprecision(std::numeric_limits<float>::max_digits10) << std::boolalpha;
  emit("{}", baldr::Use::kBus, "bus", 500, 470, 300, true);
  emit("{}", baldr::Use::kRail, "rail", 500, 490, 300, false);
  std::mt19937 random(189);
  constexpr std::array<float, 11> preferences{
      -0.5f, 0.0f, 0.1f, 0.3f, 0.49999f, 0.5f, 0.50001f, 0.6f, 0.8f, 1.0f, 1.5f};
  constexpr std::array<float, 7> penalties{-1.0f, 0.0f, 0.5f, 15.0f, 300.0f, 43200.0f, 43201.0f};
  constexpr std::array<float, 7> factors{0.0f, 0.1f, 1.0f, 1.5f, 4.0f, 100000.0f, 100001.0f};
  constexpr std::array<uint32_t, 7> distances{0, 1, 805, 2415, 50000, 100000, 100001};
  for (size_t i = 0; i < 4096; ++i) {
    const auto preference = [&] { return preferences[random() % preferences.size()]; };
    const auto penalty = [&] { return penalties[random() % penalties.size()]; };
    const auto factor = [&] { return factors[random() % factors.size()]; };
    const auto distance = [&] { return distances[random() % distances.size()]; };
    std::ostringstream input;
    input << std::setprecision(std::numeric_limits<float>::max_digits10) << std::boolalpha
          << "{\"pedestrian\":{\"mode_factor\":" << factor()
          << ",\"transit_start_end_max_distance\":" << distance()
          << ",\"transit_transfer_max_distance\":" << distance()
          << "},\"transit\":{\"mode_factor\":" << factor() << ",\"use_bus\":" << preference()
          << ",\"use_rail\":" << preference() << ",\"use_transfers\":" << preference()
          << ",\"transfer_cost\":" << penalty() << ",\"transfer_penalty\":" << penalty()
          << ",\"wheelchair\":" << (i % 2 != 0) << ",\"bicycle\":" << (i % 4 >= 2) << "}}";
    const bool bus = i % 3 == 0;
    const bool rail = i % 3 == 1;
    const auto use = bus ? baldr::Use::kBus : rail ? baldr::Use::kRail : baldr::Use::kRoad;
    const uint32_t depart = 1000 + random() % 100000;
    const uint32_t current = depart - random() % 601;
    const uint32_t elapsed = 1 + random() % 7200;
    emit(input.str(), use, bus ? "bus" : rail ? "rail" : "road", depart, current, elapsed,
         i % 4 < 2);
  }
}
