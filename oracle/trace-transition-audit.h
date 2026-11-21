// Test-time path enumeration for the single-level Meili transition fixture.
#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>
#include <valhalla/meili/routing.h>
#include <valhalla/midgard/util.h>
#include <valhalla/sif/dynamiccost.h>
#include <valhalla/thor/edgestatus.h>

namespace trace_audit {
using namespace valhalla;
using baldr::GraphId;
using baldr::graph_tile_ptr;

struct Path {
  sif::Cost cost{std::numeric_limits<float>::infinity(), 0.f};
  float turns = 0.f;
  std::vector<uint32_t> edges;
  GraphId arrival;
};

class Enumerator {
public:
  Enumerator(baldr::GraphReader& reader,
             const sif::cost_ptr_t& costing,
             const std::array<float, 181>& penalties,
             const std::vector<Location>& targets,
             float max_distance,
             float max_time,
             bool use_dominance = false)
      : reader_(reader), costing_(costing), penalties_(penalties), paths_(targets.size()),
        max_distance_(max_distance), max_time_(max_time), bound_(max_distance),
        remaining_(targets.size()), use_dominance_(use_dominance) {
    for (size_t index = 0; index < targets.size(); ++index) {
      for (const auto& edge : targets[index].correlation().edges()) {
        const GraphId id(edge.graph_id());
        if (edge.begin_node() || edge.end_node()) {
          node_targets_[endpoint(edge)].push_back(index);
        } else {
          edge_targets_[id].emplace_back(index, edge.percent_along());
        }
      }
    }
  }

  std::vector<Path> run(const Location& origin, GraphId arrival = {}) {
    if (arrival.is_valid()) {
      const auto tile = tile_for(arrival);
      const auto* edge = tile->directededge(arrival);
      push(meili::Label(edge->endnode(), meili::kInvalidDestination, arrival, 0.f, 0.f,
                        sif::Cost{}, 0.f, 0.f, baldr::kInvalidLabel, edge,
                        costing_->travel_mode(), -1));
      inherited_ = 1;
    }
    for (const auto& edge : origin.correlation().edges()) {
      if (edge.begin_node() || edge.end_node()) {
        const auto node = endpoint(edge);
        const auto tile = tile_for(node);
        if (costing_->Allowed(tile->node(node)))
          walk(node, false);
      } else {
        const GraphId id(edge.graph_id());
        if (auto label = traverse(tile_for(id), id, edge.percent_along())) {
          push(*label);
          walk(label->nodeid(), true);
        }
      }
    }
    return std::move(paths_);
  }

  size_t prefixes() const {
    return prefixes_;
  }

private:
  struct Frame {
    GraphId node;
    graph_tile_ptr tile;
    const baldr::NodeInfo* info;
    uint32_t next = 0;
    uint16_t inbound = 0;
  };

  struct Arrival {
    GraphId edge;
    std::vector<GraphId> restriction_suffix;

    bool operator==(const Arrival&) const = default;
  };

  struct ArrivalHash {
    size_t operator()(const Arrival& state) const {
      size_t hash = state.edge.value;
      for (const auto edge : state.restriction_suffix)
        hash ^= edge.value + 0x9e3779b9 + (hash << 6) + (hash >> 2);
      return hash;
    }
  };

  baldr::GraphReader& reader_;
  const sif::cost_ptr_t& costing_;
  const std::array<float, 181>& penalties_;
  std::unordered_map<GraphId, std::vector<size_t>> node_targets_;
  std::unordered_map<GraphId, std::vector<std::pair<size_t, float>>> edge_targets_;
  std::vector<Path> paths_;
  std::vector<meili::Label> history_;
  std::vector<size_t> restriction_positions_;
  std::unordered_map<Arrival, std::vector<sif::Cost>, ArrivalHash> arrivals_;
  const float max_distance_;
  const float max_time_;
  float bound_;
  size_t remaining_;
  const bool use_dominance_;
  size_t prefixes_ = 0;
  size_t inherited_ = 0;

  graph_tile_ptr tile_for(GraphId id) {
    auto tile = reader_.GetGraphTile(id);
    if (!tile)
      throw std::runtime_error("missing audit tile");
    return tile;
  }

  GraphId endpoint(const PathEdge& edge) {
    graph_tile_ptr tile;
    const auto nodes = reader_.GetDirectedEdgeNodes(GraphId(edge.graph_id()), tile);
    const auto node = edge.begin_node() ? nodes.first : nodes.second;
    if (!node.is_valid())
      throw std::runtime_error("invalid audit endpoint");
    return node;
  }

  bool within(sif::Cost cost) const {
    return cost.cost < max_distance_ && cost.cost <= bound_ &&
           (max_time_ < 0.f || cost.secs < max_time_);
  }

  void push(const meili::Label& label) {
    if (use_dominance_ && label.on_complex_rest())
      restriction_positions_.push_back(history_.size());
    history_.push_back(label);
  }

  void pop() {
    history_.pop_back();
    if (!restriction_positions_.empty() && restriction_positions_.back() == history_.size())
      restriction_positions_.pop_back();
  }

  bool dominated() {
    if (!use_dominance_ || history_.empty())
      return false;
    const auto& last = history_.back();
    Arrival state{last.edgeid(), {}};
    // A future restriction can read at most 31 vias and one start edge.
    // Preserve the suffix from the earliest marked edge in that window.
    constexpr auto depth = baldr::kMaxViasPerRestriction + 1;
    const auto window = history_.size() > depth ? history_.size() - depth : 0;
    const auto start = std::lower_bound(restriction_positions_.begin(), restriction_positions_.end(), window);
    if (start != restriction_positions_.end()) {
      for (size_t i = *start; i < history_.size(); ++i)
        state.restriction_suffix.push_back(history_[i].edgeid());
    }
    auto& costs = arrivals_[std::move(state)];
    const auto dominates = [&](sif::Cost a, sif::Cost b) {
      return a.cost <= b.cost && (max_time_ < 0.f || a.secs <= b.secs);
    };
    for (const auto cost : costs) {
      if (dominates(cost, last.cost()))
        return true;
    }
    std::erase_if(costs, [&](sif::Cost cost) { return dominates(last.cost(), cost); });
    costs.push_back(last.cost());
    return false;
  }

  void record(size_t target, sif::Cost cost, float turns, GraphId tail = {}) {
    auto& best = paths_[target];
    if (cost.cost >= best.cost.cost)
      return;
    if (best.cost.cost == std::numeric_limits<float>::infinity())
      --remaining_;
    best = {cost, turns, {}, tail.is_valid() ? tail : history_.empty() ? GraphId{} : history_.back().edgeid()};
    for (size_t i = inherited_; i < history_.size(); ++i)
      best.edges.push_back(history_[i].edgeid().id());
    if (tail.is_valid())
      best.edges.push_back(tail.id());
    if (remaining_ == 0) {
      // Every remaining step has nonnegative length.
      bound_ = 0.f;
      for (const auto& path : paths_)
        bound_ = std::max(bound_, path.cost.cost);
    }
  }

  static uint16_t heading(const graph_tile_ptr& tile, const baldr::DirectedEdge* edge,
                          const baldr::NodeInfo* node) {
    const auto local = edge->localedgeidx();
    if (local < 8)
      return node->heading(local);
    const auto shape = tile->edgeinfo(edge).shape();
    if (shape.size() < 2)
      return 0;
    const float degrees = edge->forward() ? shape.front().Heading(shape[1])
                                          : shape.back().Heading(shape[shape.size() - 2]);
    return static_cast<uint16_t>(std::clamp(degrees, 0.f, 359.f));
  }

  std::optional<meili::Label> traverse(const graph_tile_ptr& tile,
                                       GraphId id,
                                       float begin,
                                       const baldr::NodeInfo* node = nullptr,
                                       uint16_t inbound = 0) {
    const auto* edge = tile->directededge(id);
    if (edge->is_shortcut() || edge->use() == baldr::Use::kTransitConnection)
      return std::nullopt;
    const bool from_origin = history_.empty();
    const auto previous = from_origin ? meili::Label{} : history_.back();
    uint8_t restriction = -1;
    uint8_t destination_only = 0;
    const bool allowed = costing_->Allowed(edge, previous, tile, id, 0, 0, restriction, destination_only);
    if (!(allowed || (from_origin && costing_->Allowed(edge, tile, id, sif::kDisallowShortcut)) ||
          id == previous.edgeid()) ||
        (!from_origin && costing_->Restricted(edge, previous, history_, tile, id, true)))
      return std::nullopt;

    const auto length = edge->length();
    const auto seconds = costing_->EdgeCost(edge, id, tile).secs;
    if (length == 0 || !(seconds >= 0.f))
      throw std::runtime_error("audit requires positive edge lengths and nonnegative travel times");
    float turn = from_origin ? 0.f : previous.turn_cost();
    if (!from_origin && node)
      turn += penalties_[midgard::get_turn_degree180(inbound, heading(tile, edge, node))];
    const auto paid = from_origin ? sif::Cost{} : previous.cost();
    const auto clipped = [&](float end) {
      const float fraction = end - begin;
      return sif::Cost{paid.cost + length * fraction, paid.secs + seconds * fraction};
    };
    const auto found = edge_targets_.find(id);
    if (found != edge_targets_.end()) {
      for (const auto& [target, end] : found->second) {
        if (end >= begin) {
          const auto cost = clipped(end);
          if (within(cost))
            record(target, cost, turn, id);
        }
      }
    }

    const auto cost = clipped(1.f);
    if (!within(cost))
      return std::nullopt;
    const uint32_t predecessor = from_origin ? baldr::kInvalidLabel : history_.size() - 1;
    return meili::Label(edge->endnode(), meili::kInvalidDestination, id, begin, 1.f, cost, turn,
                        cost.cost, predecessor, edge, costing_->travel_mode(), restriction);
  }

  Frame enter(GraphId node) {
    ++prefixes_;
    const auto tile = tile_for(node);
    const auto* info = tile->node(node);
    if (info->transition_count() != 0)
      throw std::runtime_error("audit requires single-level tiles");
    if (dominated())
      return {node, tile, info, info->edge_count()};
    const auto targets = node_targets_.find(node);
    if (targets != node_targets_.end()) {
      const auto cost = history_.empty() ? sif::Cost{} : history_.back().cost();
      const auto turn = history_.empty() ? 0.f : history_.back().turn_cost();
      if (within(cost)) {
        for (const auto target : targets->second)
          record(target, cost, turn);
      }
    }
    Frame frame{node, tile, info};
    if (!costing_->Allowed(info)) {
      frame.next = info->edge_count();
    } else if (!history_.empty()) {
      const auto opposing = reader_.GetOpposingEdgeId(history_.back().edgeid());
      frame.inbound = heading(tile, tile->directededge(opposing), info);
    }
    return frame;
  }

  void walk(GraphId node, bool consumed_start_edge) {
    // Keep full predecessor chains for costing and use the distance bound
    // even when state dominance is disabled.
    std::vector<Frame> frames{enter(node)};
    while (!frames.empty()) {
      auto& frame = frames.back();
      if (frame.next == frame.info->edge_count()) {
        frames.pop_back();
        if (!frames.empty() || consumed_start_edge)
          pop();
        continue;
      }
      const GraphId id(frame.node.tileid(), frame.node.level(), frame.info->edge_index() + frame.next++);
      if (auto label = traverse(frame.tile, id, 0.f, frame.info, frame.inbound)) {
        push(*label);
        frames.push_back(enter(label->nodeid()));
      }
    }
  }
};
} // namespace trace_audit
