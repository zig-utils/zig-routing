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
#include <valhalla/meili/map_matcher.h>
#include <valhalla/meili/topk_search.h>
#include <valhalla/meili/transition_cost_model.h>
#include <valhalla/midgard/logging.h>
#include <valhalla/sif/costfactory.h>

#include "trace-transition-audit.h"

namespace {
using namespace valhalla;

trace_audit::Cut stationary_cut(baldr::GraphReader& reader,
                                 const Location& location,
                                 baldr::GraphId previous,
                                 baldr::GraphId following) {
  const auto& candidates = location.correlation().edges();
  for (const auto& candidate : candidates) {
    const baldr::GraphId id(candidate.graph_id());
    const float fraction = candidate.percent_along();
    if (id == previous || id == following)
      return {id, fraction, fraction};
    if (fraction != 0.f && fraction != 1.f)
      continue;
    baldr::graph_tile_ptr tile;
    const auto nodes = reader.GetDirectedEdgeNodes(id, tile);
    const auto node = fraction == 0.f ? nodes.first : nodes.second;
    if (previous.is_valid() && reader.directededge(previous, tile)->endnode() == node)
      return {previous, 1.f, 1.f};
    if (following.is_valid() && reader.directededge(reader.GetOpposingEdgeId(following), tile)->endnode() == node)
      return {following, 0.f, 0.f};
  }
  const auto& candidate = candidates.Get(0);
  const auto fraction = candidate.percent_along();
  return {baldr::GraphId(candidate.graph_id()), fraction, fraction};
}

void write_directed_segments(
    size_t row,
    baldr::GraphReader& reader,
    meili::ViterbiSearch& search,
    const meili::StateContainer& states,
    const std::vector<meili::StateId>& reverse,
    const std::unordered_map<meili::StateId, std::vector<trace_audit::Path>>& routed) {
  struct Segment { trace_audit::Cut cut; bool disconnected = false; };
  std::vector<Segment> segments;
  std::vector<const trace_audit::Path*> pairs;
  for (size_t i = reverse.size(); i > 1; --i) {
    const auto left = reverse[i - 1];
    const auto right = reverse[i - 2];
    pairs.push_back(left.IsValid() && right.IsValid() && search.Predecessor(right) == left
        ? &routed.at(left).at(right.id()) : nullptr);
  }
  bool gap = false;
  baldr::GraphId previous;
  for (size_t i = 0; i < pairs.size(); ++i) {
    const auto* route = pairs[i];
    if (!route) {
      gap = true;
      previous = {};
      continue;
    }
    if (route->arrival.is_valid())
      previous = route->arrival;
    const auto append = [&](trace_audit::Cut cut) {
      if (!segments.empty() && gap)
        segments.back().disconnected = true;
      gap = false;
      if (!segments.empty() && !segments.back().disconnected &&
          segments.back().cut.edge == cut.edge && segments.back().cut.end == cut.begin) {
        segments.back().cut.end = cut.end;
      } else {
        segments.push_back({cut});
      }
    };
    if (route->cuts.empty()) {
      baldr::GraphId following;
      for (size_t next = i + 1; next < pairs.size() && pairs[next]; ++next) {
        if (!pairs[next]->cuts.empty()) {
          following = pairs[next]->cuts.front().edge;
          break;
        }
      }
      const auto right = reverse[reverse.size() - i - 2];
      append(stationary_cut(reader, states.state(right).candidate(), previous, following));
    } else {
      for (const auto& cut : route->cuts)
        append(cut);
    }
  }
  std::cout << row;
  for (const auto& entry : segments) {
    const auto& cut = entry.cut;
    std::cout << '\t' << cut.edge.id() << ',' << cut.begin << ',' << cut.end << ',' << entry.disconnected;
  }
  std::cout << '\n';
}
} // namespace

int main(int argc, char** argv) {
  const bool directed_segments = argc == 4 && std::string_view(argv[3]) == "--directed-segments";
  const bool directed = directed_segments || (argc == 4 && std::string_view(argv[3]) == "--directed");
  const bool segments = argc == 4 && std::string_view(argv[3]) == "--segments";
  if (argc != 3 && !directed && !segments) {
    std::cerr << "usage: viterbi-reference CONFIG CORPUS [--directed|--segments|--directed-segments]\n";
    return 2;
  }
  using namespace valhalla;
  boost::property_tree::ptree config;
  boost::property_tree::read_json(argv[1], config);
  midgard::logging::Configure({{"type", "std_err"}});
  baldr::GraphReader reader(config.get_child("mjolnir"));
  meili::Config settings(config.get_child("meili"));
  // Use the same turn penalty in the full matcher and the Viterbi probes.
  settings.transition_cost.turn_penalty_factor = 200.f;
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
    std::vector<meili::Measurement> measurements;
    measurements.reserve(count);
    for (uint32_t time = 0; time < count; ++time) {
      double lat, lon, epoch;
      if (!(input >> lat >> lon >> epoch))
        return 2;
      measurements.emplace_back(midgard::PointLL{lon, lat}, accuracy, radius, epoch);
    }
    if (segments) {
      meili::MapMatcher matcher(settings, reader, query, modes, mode);
      const auto matches = matcher.OfflineMatch(measurements, 1);
      std::cout << row++;
      for (const auto& edge : matches.front().segments) {
        std::cout << '\t' << edge.edgeid.id() << ',' << edge.source << ',' << edge.target << ','
                  << edge.discontinuity;
      }
      std::cout << '\n';
      continue;
    }
    meili::StateContainer states;
    meili::ViterbiSearch search;
    meili::TopKSearch topk(search);
    meili::EmissionCostModel emission(reader, states, 4.07f);
    meili::TransitionCostModel transition(reader, search, topk, states, modes, mode,
                                          3.f, 2000.f, 5.f, 5.f, 200.f);
    std::unordered_map<meili::StateId, std::vector<trace_audit::Path>> routed;
    search.set_emission_cost_model(std::ref(emission));
    search.set_transition_cost_model(std::ref(transition));
    size_t selected = 0;
    for (size_t i = 0; i < measurements.size(); ++i) {
      const auto& measurement = measurements[i];
      if (directed_segments && i != 0) {
        const auto& previous = measurements[selected];
        const auto distance = settings.routing.interpolation_distance_meters;
        if (i + 1 != measurements.size() && previous.distance_squared(measurement) <= distance * distance)
          continue;
        if (i > selected + 1 && measurements[i - 1].epoch_time() >= 0) {
          const auto& start = previous.lnglat();
          const auto& finish = measurement.lnglat();
          const auto projected = measurements[i - 1].lnglat().Project(start, finish);
          const auto span = start.Distance(finish);
          if (span > 0 && start.Distance(projected) / span < 0.2f)
            states.SetMeasurementLeaveTime(states.size() - 1, measurements[i - 1].epoch_time());
        }
      }
      states.AppendMeasurement(measurement);
      selected = i;
      auto candidates = query.Query(measurement.lnglat(), measurement.stop_type(), effective * effective, costing);
      for (auto& candidate : candidates)
        search.AddStateId(states.AppendCandidate(std::move(candidate)));
    }
    if (directed) {
      search.set_transition_cost_model([&](meili::StateId from, meili::StateId to) {
        const auto& left = states.measurement(from.time());
        const auto& right = states.measurement(to.time());
        const float observed = left.distance(right);
        const auto leave = states.leave_time(from.time());
        const double clock = leave < 0 || right.epoch_time() < 0 ? -1 : right.epoch_time() - leave;
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
      while (reverse.size() < states.size()) {
        const uint32_t time = states.size() - reverse.size() - 1;
        std::copy(search.SearchPathVS(time, false), search.PathEnd(), std::back_inserter(reverse));
        const auto winner = search.SearchWinner(time);
        if (winner.IsValid()) {
          cost += search.AccumulatedCost(winner);
        } else {
          cost += break_penalty;
          broken = true;
        }
        if (reverse.size() < states.size()) {
          cost += break_penalty;
          broken = true;
        }
      }
      if (directed_segments) {
        write_directed_segments(row, reader, search, states, reverse, routed);
        break;
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
