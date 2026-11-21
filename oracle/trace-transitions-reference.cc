// Test-time instrumentation of the pinned Meili emission and routing models.
#include <boost/property_tree/json_parser.hpp>
#include <array>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <rapidjson/document.h>
#include <valhalla/meili/candidate_search.h>
#include <valhalla/meili/config.h>
#include <valhalla/meili/emission_cost_model.h>
#include <valhalla/meili/routing.h>
#include <valhalla/meili/transition_cost_model.h>
#include <valhalla/midgard/logging.h>
#include <valhalla/sif/costfactory.h>

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: trace-transitions-reference CONFIG CORPUS\n";
    return 2;
  }
  using namespace valhalla;
  boost::property_tree::ptree config;
  boost::property_tree::read_json(argv[1], config);
  midgard::logging::Configure({{"type", "std_err"}});
  baldr::GraphReader reader(config.get_child("mjolnir"));
  const meili::Config settings(config.get_child("meili"));
  const auto mode = sif::TravelMode::kDrive;
  sif::CostFactory factory;
  sif::mode_costing_t modes;
  rapidjson::Document request;
  request.Parse(R"({"costing":"auto"})");
  Costing parsed;
  google::protobuf::RepeatedPtrField<CodedDescription> warnings;
  sif::ParseCosting(request, "/costing_options/auto", &parsed, warnings, Costing::auto_);
  modes[static_cast<size_t>(mode)] = factory.Create(parsed);
  const auto& costing = modes[static_cast<size_t>(mode)];
  const float cell = baldr::TileHierarchy::levels().back().tiles.TileSize() / settings.candidate_search.grid_size;
  meili::CandidateGridQuery query(reader, cell, cell);
  meili::StateContainer states;
  meili::ViterbiSearch viterbi;
  meili::TopKSearch topk(viterbi);
  constexpr float sigma = 4.07f;
  constexpr float turn_factor = 200.f;
  constexpr float route_distance_factor = 5.f;
  constexpr float route_time_factor = 5.f;
  constexpr float breakage = 2000.f;
  const meili::EmissionCostModel emission(reader, states, sigma);
  const meili::TransitionCostModel transition(reader, viterbi, topk, states, modes, mode, 3.f, breakage,
                                              route_distance_factor, route_time_factor, turn_factor);
  std::array<float, 181> penalties;
  for (size_t i = 0; i < penalties.size(); ++i)
    penalties[i] = turn_factor * std::exp(-static_cast<float>(i) / 45.f);
  std::ifstream input(argv[2]);
  if (!input)
    return 2;
  std::cout << std::setprecision(17);
  double from_lat, from_lon, to_lat, to_lon, clock;
  float radius;
  size_t row = 0;
  while (input >> from_lat >> from_lon >> to_lat >> to_lon >> radius >> clock) {
    const midgard::PointLL left{from_lon, from_lat};
    const midgard::PointLL right{to_lon, to_lat};
    const auto effective = std::min(settings.candidate_search.max_search_radius_meters, std::max(5.f, radius));
    const auto from = query.Query(left, Location_Type_kVia, effective * effective, costing);
    const auto to = query.Query(right, Location_Type_kVia, effective * effective, costing);
    const float observed = left.Distance(right);
    const float max_distance = std::ceil(std::max(1.f, std::min(breakage, observed * route_distance_factor)));
    const float max_time = clock < 0 ? -1.f : std::ceil(static_cast<float>(clock) * route_time_factor);
    std::vector<const Location*> destinations(1, nullptr);
    for (const auto& target : to)
      destinations.push_back(&target);
    const midgard::DistanceApproximator<midgard::PointLL> approx(right);
    for (size_t s = 0; s < from.size(); ++s) {
      destinations[0] = &from[s];
      auto labels = std::make_shared<meili::LabelSet>(max_distance);
      const auto found = meili::find_shortest_path(reader, destinations, 0, labels, approx, radius, costing,
                                                   nullptr, penalties.data(), max_distance, max_time);
      for (size_t t = 0; t < to.size(); ++t) {
        const auto left_score = emission.CalculateEmissionCost(from[s].correlation().edges(0).distance());
        const auto right_score = emission.CalculateEmissionCost(to[t].correlation().edges(0).distance());
        std::cout << row << '\t' << s << '\t' << t << '\t' << left_score << '\t' << right_score;
        const auto result = found.find(t + 1);
        if (result == found.end()) {
          std::cout << "\t-1\t-1\t-1\t-1\n";
        } else {
          const auto& label = labels->label(result->second);
          const auto cost = label.cost();
          const auto score = transition.CalculateTransitionCost(label.turn_cost(), cost.cost, observed, cost.secs, clock);
          std::cout << '\t' << cost.cost << '\t' << cost.secs << '\t' << label.turn_cost() << '\t' << score << '\t';
          std::vector<uint32_t> edges;
          const meili::RoutePathIterator end(labels.get());
          for (meili::RoutePathIterator it(labels.get(), result->second); it != end; ++it)
            if (it->edgeid().is_valid())
              edges.push_back(it->edgeid().id());
          for (size_t i = 0; i < edges.size(); ++i)
            std::cout << (i == 0 ? "" : ",") << edges[edges.size() - 1 - i];
          std::cout << '\n';
        }
      }
    }
    ++row;
  }
  return input.eof() && std::cout.good() ? 0 : 2;
}
