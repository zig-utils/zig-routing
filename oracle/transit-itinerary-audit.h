// Test-time costing replay using the pinned Valhalla libraries and exact path movements.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <optional>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <valhalla/baldr/time_info.h>
#include <valhalla/sif/edgelabel.h>

namespace transit_audit {
using namespace valhalla;

struct Movement {
  baldr::GraphId edge;
  std::optional<float> begin, end;
  std::optional<uint32_t> trip;
  std::optional<int64_t> board;
  sif::Cost expected;
};

struct Choice {
  uint32_t trip, departure, elapsed;
};

struct Step {
  sif::Cost total;
  std::optional<uint64_t> ready;
  uint32_t walking_distance = 0;
  std::optional<Choice> stock_next;
  uint32_t exact_second = 0;
  uint32_t stock_second = 0;
  float boarding_transition = 0;
};

struct TerminalGate {
  size_t step;
  uint32_t full_walk, clipped_walk, limit;
};

struct Result {
  std::vector<Step> steps;
  std::optional<size_t> first_cost_difference;
  const char* blocked = nullptr;
  std::optional<TerminalGate> terminal_gate;
  uint32_t walking_limit = 0;
};

inline const PathEdge* cut(const Location& location, const baldr::GraphId& id,
                           std::optional<float> fraction) {
  for (const auto& candidate : location.correlation().edges())
    if (candidate.graph_id() == id.value && (!fraction || static_cast<float>(candidate.percent_along()) == *fraction))
      return &candidate;
  for (const auto& candidate : location.correlation().filtered_edges())
    if (candidate.graph_id() == id.value && (!fraction || static_cast<float>(candidate.percent_along()) == *fraction))
      return &candidate;
  return nullptr;
}

struct Departure {
  std::unique_ptr<const baldr::TransitDeparture> frequency;
  const baldr::TransitDeparture* record = nullptr;
  uint32_t ready_seconds = 0;
  uint32_t day = 0, day_of_week = 0;
  bool before_tile = false;
};

inline Departure lookup(const baldr::GraphTile& tile, uint32_t line, uint32_t trip,
                        int64_t board, const baldr::TimeInfo& ready, const sif::DynamicCost& transit) {
  const auto* zone = baldr::DateTime::get_tz_db().from_index(ready.timezone_index);
  if (zone == nullptr || board < static_cast<int64_t>(ready.unix_time))
    return {};
  const auto local_board = date::make_zoned(zone, date::sys_seconds{std::chrono::seconds{board}}).get_local_time();
  const auto local_ready = date::make_zoned(zone, date::sys_seconds{std::chrono::seconds{ready.unix_time}}).get_local_time();
  const auto board_day = date::floor<date::days>(local_board);
  for (int days_back = 0; days_back <= 1; ++days_back) {
    const auto service_day = board_day - date::days{days_back};
    if (local_ready < service_day)
      continue;
    const auto seek = static_cast<uint32_t>((local_board - service_day).count());
    const auto* row = tile.GetTransitDeparture(line, trip, seek);
    if (!row)
      continue;
    Departure result;
    if (row->type() == baldr::kFrequencySchedule)
      result.frequency.reset(row);
    if (row->departure_time() != seek || (transit.wheelchair() && !row->wheelchair_accessible()) ||
        (transit.bicycle() && !row->bicycle_accessible()))
      continue;
    const auto date = date::format("%F", service_day);
    const auto day = baldr::DateTime::days_from_pivot_date(service_day);
    const auto created = tile.header()->date_created();
    result.before_tile = day < created;
    result.day = result.before_tile ? 0 : day - created;
    result.day_of_week = baldr::DateTime::day_of_week_mask(date);
    const auto* schedule = tile.GetTransitSchedule(row->schedule_index());
    if (!schedule || !schedule->IsValid(result.day, result.day_of_week, result.before_tile))
      continue;
    result.ready_seconds = static_cast<uint32_t>((local_ready - service_day).count());
    result.record = row;
    return result;
  }
  return {};
}

inline std::optional<Choice> next_departure(const baldr::GraphTile& tile, const uint32_t line,
                                            const Departure& exact, uint32_t stock_second, const sif::MMEdgeLabel& prior,
                                            const sif::DynamicCost& transit) {
  auto seek = stock_second;
  for (unsigned attempt = 0; attempt < 2; ++attempt) {
    const auto* row = tile.GetNextDeparture(line, seek, exact.day, exact.day_of_week,
                                           exact.before_tile, transit.wheelchair(), transit.bicycle());
    if (!row)
      return {};
    std::unique_ptr<const baldr::TransitDeparture> frequency;
    if (row->type() == baldr::kFrequencySchedule)
      frequency.reset(row);
    const bool continuing = row->tripid() == prior.tripid() ||
                            (row->blockid() && row->blockid() == prior.blockid());
    if (attempt == 0 && !continuing && prior.tripid() && row->departure_time() < seek + 30) {
      seek += 30;
      continue;
    }
    return Choice{row->tripid(), row->departure_time(), row->elapsed_time()};
  }
  return {};
}

inline Result replay(baldr::GraphReader& reader, const sif::mode_costing_t& modes, Options& options,
                     const std::vector<Movement>& path) {
  using baldr::GraphId;
  using baldr::NodeType;
  using baldr::Use;
  using sif::TravelMode;
  const auto& walking = modes[static_cast<unsigned>(TravelMode::kPedestrian)];
  const auto& transit = modes[static_cast<unsigned>(TravelMode::kPublicTransit)];
  if (path.empty() || path.front().trip || path.back().trip)
    return {{}, {}, "endpoints"};
  const auto* from = cut(options.locations(0), path.front().edge, path.front().begin);
  const auto* to = cut(options.locations(1), path.back().edge, path.back().end);
  if (!from || !to)
    return {{}, {}, "correlation"};

  walking->SetAllowTransitConnections(true);
  const auto walking_limit =
      options.costings().at(Costing::pedestrian).options().transit_start_end_max_distance();
  const auto transfer_limit = walking->GetMaxTransferDistanceMM();
  baldr::DateTime::tz_sys_info_cache_t cache;
  const auto start = baldr::TimeInfo::make(*options.mutable_locations(0), reader, &cache);
  std::unordered_map<std::string, uint32_t> operators;
  std::unordered_set<uint32_t> processed_tiles;
  sif::MMEdgeLabel prior;
  sif::Cost total{};
  GraphId prior_stop;
  uint32_t walking_distance = 0, path_distance = 0, operator_id = 0;
  bool ridden = false;
  Result result;
  result.walking_limit = walking_limit;
  auto block = [&](const char* reason) {
    result.blocked = reason;
    return result;
  };
  if (!start.valid)
    return block("origin_clock");

  for (size_t i = 0; i < path.size(); ++i) {
    const auto& step = path[i];
    baldr::graph_tile_ptr tile;
    const auto* edge = reader.directededge(step.edge, tile);
    if (!edge || edge->is_shortcut() || edge->IsTransitLine() != step.trip.has_value())
      return block("movement");
    const bool first = i == 0;
    const bool last = i + 1 == path.size();
    uint32_t trip = 0, trip_block = 0;
    sif::Cost transition{};
    std::optional<uint64_t> reached;
    std::optional<Choice> stock_next;
    uint32_t exact_second = 0, stock_second = 0;
    float boarding_transition = 0;
    const auto mode = step.trip ? TravelMode::kPublicTransit : TravelMode::kPedestrian;

    if (first) {
      if (walking->AvoidAsOriginEdge(step.edge, from->percent_along()))
        return block("origin_access");
      if (last && to->percent_along() < from->percent_along())
        return block("endpoint_order");
      total = walking->EdgeCost(edge, step.edge, tile) * (1.f - from->percent_along());
      total.cost += from->distance();
      walking_distance = edge->length() * (1.f - from->percent_along());
      if (last) {
        total -= walking->EdgeCost(edge, step.edge, tile) * (1.f - to->percent_along());
        total.cost = std::max(0.f, total.cost + static_cast<float>(to->distance()));
      }
    } else {
      const auto node_id = prior.endnode();
      const auto node_tile = reader.GetGraphTile(node_id);
      const auto* node = node_tile->node(node_id);
      if (step.edge.tile_base() != node_id.tile_base() || step.edge.id() < node->edge_index() ||
          step.edge.id() - node->edge_index() >= node->edge_count())
        return block("disconnected");

      if (node->type() == NodeType::kMultiUseTransitPlatform || node->type() == NodeType::kTransitStation) {
        if (processed_tiles.insert(node_id.tileid()).second)
          transit->AddToExcludeList(node_tile);
        if (transit->IsExcluded(node_tile, node))
          return block("stop_access");
      }
      const auto ready = start.forward(total.secs, node->timezone());
      const bool walking_before = prior.mode() == TravelMode::kPedestrian;
      auto transfer = transit->DefaultTransferCost();
      if (node->type() == NodeType::kMultiUseTransitPlatform) {
        if (walking_before && prior_stop.is_valid() && ridden)
          transfer = transit->TransferCost();
        prior_stop = node_id;
      }

      uint8_t restriction = baldr::kInvalidRestriction, exceptions = 0;
      if (step.trip) {
        reached = ready.unix_time;
        if (!transit->Allowed(edge, prior, tile, step.edge, 0, 0, restriction, exceptions) ||
            transit->IsExcluded(tile, edge))
          return block("transit_access");
        if (!step.board || *step.board < static_cast<int64_t>(ready.unix_time))
          return block("departure_before_ready");
        const auto departure = lookup(*tile, edge->lineid(), *step.trip, *step.board, ready, *transit);
        if (!departure.record)
          return block("schedule");
        exact_second = departure.ready_seconds;
        stock_second = ready.day_seconds();
        stock_next = next_departure(*tile, edge->lineid(), departure, stock_second, prior, *transit);
        if (walking_before) {
          auto get_reader = [&reader]() { return baldr::LimitedGraphReader(reader); };
          boarding_transition = transit->TransitionCost(edge, node, prior, tile, get_reader).cost;
        }
        trip = departure.record->tripid();
        trip_block = departure.record->blockid();
        const bool continuing = trip == prior.tripid() || (trip_block != 0 && trip_block == prior.blockid());
        if (!continuing) {
          if (prior.tripid() > 0 && *step.board - static_cast<int64_t>(ready.unix_time) < 30)
            return block("transfer_time");
          operator_id = tile->GetTransitOperatorId(departure.record->routeindex(), operators);
          total.cost += prior.transit_operator() > 0 && prior.transit_operator() != operator_id
                            ? 300.f : transfer.cost;
        }
        total += transit->EdgeCost(edge, departure.record, departure.ready_seconds);
        ridden = true;
      } else {
        const auto full = walking_before ? walking_distance + edge->length() : 0;
        const auto clipped = !walking_before ? 0 : last
            ? walking_distance + static_cast<uint32_t>(edge->length() * to->percent_along()) : full;
        if (clipped > walking_limit)
          return block("walking_limit");
        if (full > walking_limit)
          result.terminal_gate = TerminalGate{i, full, clipped, walking_limit};
        walking_distance = clipped;
        if (walking_before && node->type() == NodeType::kTransitEgress &&
            prior.use() == Use::kTransitConnection && edge->use() == Use::kTransitConnection)
          return block("egress_access");
        if (!walking->Allowed(edge, prior, tile, step.edge, 0, 0, restriction, exceptions))
          return block("walking_access");
        if (edge->use() == Use::kPlatformConnection &&
            (edge->endnode() == prior.prior_stopid() ||
             (prior.prior_stopid().is_valid() && walking_distance > transfer_limit)))
          return block("platform_transfer");
        auto cost = walking->EdgeCost(edge, step.edge, tile);
        cost.cost *= walking->GetModeFactor();
        total += cost;
      }

      if (mode == prior.mode()) {
        auto reader_getter = [&reader]() { return baldr::LimitedGraphReader(reader); };
        transition = modes[static_cast<unsigned>(mode)]->TransitionCost(edge, node, prior, tile, reader_getter);
        total += transition;
      }
      if (last) {
        if (walking->AvoidAsDestinationEdge(step.edge, to->percent_along()))
          return block("destination_access");
        auto remainder = walking->EdgeCost(edge, step.edge, tile) * (1.f - to->percent_along());
        remainder.cost += to->distance();
        total -= remainder;
      }
    }
    path_distance += edge->length();
    prior = sif::MMEdgeLabel(baldr::kInvalidLabel, step.edge, edge, total, total.cost, 0, mode,
                             path_distance, walking_distance, trip, prior_stop, trip_block,
                             operator_id, ridden, transition, baldr::kInvalidRestriction);
    if (!result.first_cost_difference && std::abs(total.cost - step.expected.cost) > 0.01f)
      result.first_cost_difference = i;
    result.steps.push_back({total, reached, walking_distance, stock_next, exact_second, stock_second, boarding_transition});
  }
  return result;
}
} // namespace transit_audit
