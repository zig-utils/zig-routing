// Test-time candidate sequences from the pinned Meili Viterbi and top-k.
#include <boost/property_tree/json_parser.hpp>
#include <algorithm>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <rapidjson/document.h>
#include <string_view>
#include <valhalla/meili/candidate_search.h>
#include <valhalla/meili/config.h>
#include <valhalla/meili/emission_cost_model.h>
#include <valhalla/meili/topk_search.h>
#include <valhalla/meili/transition_cost_model.h>
#include <valhalla/midgard/logging.h>
#include <valhalla/sif/costfactory.h>

#include "trace-transition-audit.h"

int main(int argc, char** argv) {
  const bool directed = argc == 4 && std::string_view(argv[3]) == "--directed";
  if (argc != 3 && !directed) {
    std::cerr << "usage: viterbi-reference CONFIG CORPUS [--directed]\n";
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
  constexpr float radius = 35.f;
  constexpr float accuracy = 5.f;
  const float effective = std::min(settings.candidate_search.max_search_radius_meters, radius);
  constexpr double break_penalty = 99999999.f;
  std::array<float, 181> penalties;
  for (size_t degree = 0; degree < penalties.size(); ++degree)
    penalties[degree] = 200.f * std::exp(-static_cast<float>(degree) / 45.f);
  std::cout << std::setprecision(17);

  std::ifstream input(argv[2]);
  size_t row = 0;
  uint32_t k, count;
  while (input >> k) {
    if (!(input >> count) || k == 0)
      return 2;
    meili::StateContainer states;
    meili::ViterbiSearch search;
    meili::TopKSearch topk(search);
    meili::EmissionCostModel emission(reader, states, 4.07f);
    meili::TransitionCostModel transition(reader, search, topk, states, modes, mode,
                                          3.f, 2000.f, 5.f, 5.f, 200.f);
    std::unordered_map<meili::StateId, std::vector<trace_audit::Path>> routed;
    search.set_emission_cost_model(std::ref(emission));
    search.set_transition_cost_model(std::ref(transition));
    for (uint32_t time = 0; time < count; ++time) {
      double lat, lon, epoch;
      if (!(input >> lat >> lon >> epoch))
        return 2;
      const midgard::PointLL point{lon, lat};
      const meili::Measurement measurement(point, accuracy, radius, epoch);
      states.AppendMeasurement(measurement);
      auto candidates = query.Query(point, measurement.stop_type(), effective * effective, costing);
      for (auto& candidate : candidates)
        search.AddStateId(states.AppendCandidate(std::move(candidate)));
    }
    if (directed) {
      search.set_transition_cost_model([&](meili::StateId from, meili::StateId to) {
        const auto& left = states.measurement(from.time());
        const auto& right = states.measurement(to.time());
        const float observed = left.distance(right);
        const double clock = left.epoch_time() < 0 || right.epoch_time() < 0
            ? -1 : right.epoch_time() - left.epoch_time();
        auto found = routed.find(from);
        if (found == routed.end()) {
          std::vector<Location> targets;
          for (const auto& candidate : states.column(to.time()))
            targets.push_back(candidate.candidate());
          const auto previous = search.Predecessor(from);
          const auto origin = topk.GetOrigin(previous, previous);
          const auto arrival = origin.IsValid() ? routed.at(origin).at(from.id()).arrival : baldr::GraphId{};
          const auto max_distance = std::ceil(std::max(1.f, std::min(2000.f, observed * 5.f)));
          const auto max_time = clock < 0 ? -1.f : std::ceil(static_cast<float>(clock) * 5.f);
          trace_audit::Enumerator walker(reader, costing, penalties, targets, max_distance, max_time, true);
          found = routed.emplace(from, walker.run(states.state(from).candidate(), arrival)).first;
        }
        const auto& path = found->second.at(to.id());
        return std::isfinite(path.cost.cost)
            ? transition.CalculateTransitionCost(path.turns, path.cost.cost, observed, path.cost.secs, clock)
            : -1.f;
      });
    }

    for (uint32_t rank = 0; rank < k; ++rank) {
      std::vector<meili::StateId> reverse;
      bool broken = false;
      double cost = 0;
      while (reverse.size() < count) {
        const uint32_t time = count - reverse.size() - 1;
        std::copy(search.SearchPathVS(time, false), search.PathEnd(), std::back_inserter(reverse));
        const auto winner = search.SearchWinner(time);
        if (winner.IsValid()) {
          cost += search.AccumulatedCost(winner);
        } else {
          cost += break_penalty;
          broken = true;
        }
        if (reverse.size() < count) {
          cost += break_penalty;
          broken = true;
        }
      }
      if (rank != 0 && broken)
        break;
      std::cout << row << '\t' << rank << '\t' << broken << '\t' << cost;
      for (auto it = reverse.rbegin(); it != reverse.rend(); ++it) {
        const auto state = topk.GetOrigin(*it, *it);
        std::cout << '\t' << (state.IsValid() ? static_cast<int64_t>(state.id()) : -1);
      }
      std::cout << '\n';
      if (broken || reverse.empty() || rank + 1 == k)
        break;
      topk.RemovePath(reverse);
      search.ClearSearch();
    }
    ++row;
  }
  return input.eof() && std::cout.good() ? 0 : 2;
}
