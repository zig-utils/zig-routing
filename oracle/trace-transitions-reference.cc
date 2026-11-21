// Test-time instrumentation of the pinned Meili emission and routing models.
#include <boost/property_tree/json_parser.hpp>
#include <array>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <rapidjson/document.h>
#include <set>
#include <valhalla/meili/candidate_search.h>
#include <valhalla/meili/config.h>
#include <valhalla/meili/emission_cost_model.h>
#include <valhalla/meili/routing.h>
#include <valhalla/meili/transition_cost_model.h>
#include <valhalla/midgard/logging.h>
#include <valhalla/sif/costfactory.h>

#include "trace-transition-audit.h"

int main(int argc, char** argv) {
  if (argc < 3 || argc > 4) {
    std::cerr << "usage: trace-transitions-reference CONFIG CORPUS [AUDIT_COLUMNS]\n";
    return 2;
  }
  const bool audit = argc == 4;
  std::set<std::pair<size_t, size_t>> selected;
  if (audit) {
    std::ifstream columns(argv[3]);
    size_t row, source;
    while (columns >> row) {
      if (!(columns >> source) || !selected.emplace(row, source).second)
        throw std::runtime_error("invalid or duplicate audit column");
    }
    if (!columns.eof() || selected.empty())
      throw std::runtime_error("expected audit rows and source candidate indices");
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
  for (; input >> from_lat >> from_lon >> to_lat >> to_lon >> radius >> clock; ++row) {
    if (audit && (selected.empty() || selected.begin()->first != row))
      continue;
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
      std::vector<trace_audit::Path> directed;
      meili::labelset_ptr_t labels;
      std::unordered_map<uint16_t, uint32_t> found;
      destinations[0] = &from[s];
      if (audit) {
        if (selected.erase({row, s}) == 0)
          continue;
        trace_audit::Enumerator enumerator(reader, costing, penalties, to, max_distance, max_time);
        directed = enumerator.run(from[s]);
        std::cerr << "Audited row " << row << " source " << s << " over " << enumerator.prefixes()
                  << " path prefixes\n";
      } else {
        labels = std::make_shared<meili::LabelSet>(max_distance);
        found = meili::find_shortest_path(reader, destinations, 0, labels, approx, radius, costing,
                                           nullptr, penalties.data(), max_distance, max_time);
      }
      for (size_t t = 0; t < to.size(); ++t) {
        const auto left_score = emission.CalculateEmissionCost(from[s].correlation().edges(0).distance());
        const auto right_score = emission.CalculateEmissionCost(to[t].correlation().edges(0).distance());
        std::cout << row << '\t' << s << '\t' << t << '\t' << left_score << '\t' << right_score;
        trace_audit::Path stock;
        if (!audit) {
          const auto result = found.find(t + 1);
          if (result != found.end()) {
            const auto& label = labels->label(result->second);
            stock.cost = label.cost();
            stock.turns = label.turn_cost();
            const meili::RoutePathIterator end(labels.get());
            for (meili::RoutePathIterator it(labels.get(), result->second); it != end; ++it)
              if (it->edgeid().is_valid())
                stock.cuts.push_back({it->edgeid(), it->source(), it->target()});
            std::reverse(stock.cuts.begin(), stock.cuts.end());
          }
        }
        const auto& path = audit ? directed[t] : stock;
        if (!std::isfinite(path.cost.cost)) {
          std::cout << "\t-1\t-1\t-1\t-1\n";
        } else {
          const auto cost = path.cost;
          const auto score = transition.CalculateTransitionCost(path.turns, cost.cost, observed, cost.secs, clock);
          std::cout << '\t' << cost.cost << '\t' << cost.secs << '\t' << path.turns << '\t' << score << '\t';
          for (size_t i = 0; i < path.cuts.size(); ++i)
            std::cout << (i == 0 ? "" : ",") << path.cuts[i].edge.id();
          std::cout << '\n';
        }
      }
    }
  }
  return input.eof() && std::cout.good() && selected.empty() ? 0 : 2;
}
