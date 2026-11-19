// Calls the costing kernels in the pinned Valhalla library for gate A.
#include <valhalla/baldr/graphreader.h>
#include <valhalla/baldr/rapidjson_utils.h>
#include <valhalla/sif/bicyclecost.h>
#include <valhalla/sif/pedestriancost.h>
#include <valhalla/tyr/actor.h>

#include <boost/property_tree/json_parser.hpp>

#include <algorithm>
#include <array>
#include <bit>
#include <charconv>
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace valhalla;
using namespace valhalla::baldr;
using namespace valhalla::sif;

namespace {

static_assert(std::endian::native == std::endian::little);
static_assert(sizeof(Cost) == 8);

struct Case {
  uint32_t incoming;
  uint32_t outgoing;
  Cost edge;
  Cost turn;
  Cost reverse_turn;
};
static_assert(sizeof(Case) == 32);

struct Segment {
  uint32_t edge;
  float begin;
  float end;
};
static_assert(sizeof(Segment) == 12);

struct Path {
  Cost cost;
  std::vector<Segment> segments;
  std::string request;
};

struct TurnCandidate {
  uint32_t from;
  uint32_t to;
  bool destination_only;
};

template <typename T> void write(std::ostream& out, const T& value) {
  out.write(reinterpret_cast<const char*>(&value), sizeof(value));
}

void write_string(std::ostream& out, const std::string& value) {
  if (value.size() > UINT32_MAX) {
    throw std::runtime_error("oversized string in costing reference");
  }
  write(out, static_cast<uint32_t>(value.size()));
  out.write(value.data(), value.size());
}

std::string json(const rapidjson::Value& value) {
  rapidjson::StringBuffer buffer;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
  value.Accept(writer);
  return {buffer.GetString(), buffer.GetSize()};
}

struct EdgeRef {
  GraphId id;
  graph_tile_ptr tile;
  const DirectedEdge* edge;
};

struct Graph {
  std::vector<EdgeRef> edges;
  std::vector<std::pair<uint32_t, uint32_t>> turns;
  std::unordered_map<uint64_t, uint32_t> dense;
  uint32_t nodes = 0;

  explicit Graph(GraphReader& reader) {
    auto keys = reader.GetTileSet(2);
    std::vector<GraphId> tiles(keys.begin(), keys.end());
    std::sort(tiles.begin(), tiles.end(), [](GraphId a, GraphId b) { return a.value < b.value; });
    for (const auto id : tiles) {
      auto tile = reader.GetGraphTile(id);
      if (!tile) {
        throw std::runtime_error("could not open local tile");
      }
      nodes += tile->header()->nodecount();
      for (uint32_t index = 0; index < tile->header()->directededgecount(); ++index) {
        const auto* edge = tile->directededge(index);
        if (edge->is_shortcut()) {
          continue;
        }
        const GraphId key(id.tileid(), id.level(), index);
        dense.emplace(key.value, static_cast<uint32_t>(edges.size()));
        edges.push_back({key, tile, edge});
      }
    }
    for (uint32_t i = 0; i < edges.size(); ++i) {
      const auto head = edges[i].edge->endnode();
      const auto tile = reader.GetGraphTile(head);
      const auto* node = tile->node(head);
      for (uint32_t offset = 0; offset < node->edge_count(); ++offset) {
        const auto next = dense.find(GraphId(head.tileid(), head.level(), node->edge_index() + offset).value);
        if (next != dense.end() && edges[i].edge->opp_local_idx() < 8) {
          turns.emplace_back(i, next->second);
        }
      }
    }
  }
};

std::vector<Path> paths(tyr::actor_t& actor,
                        const Graph& graph,
                        const rapidjson::Value& input,
                        const char* mode,
                        const rapidjson::Value& settings) {
  std::vector<Path> paths;
  for (const auto& request : input.GetArray()) {
    rapidjson::Document query;
    query.CopyFrom(request, query.GetAllocator());
    auto& a = query.GetAllocator();
    rapidjson::Value recost(settings, a);
    recost.AddMember("name", "same_graph", a);
    recost.AddMember("costing", rapidjson::Value(mode, a), a);
    rapidjson::Value recosts(rapidjson::kArrayType);
    recosts.PushBack(recost, a);
    query.RemoveMember("recostings");
    query.AddMember("recostings", recosts, a);
    const auto body = json(query);
    Api api;
    try {
      actor.route(body, nullptr, &api);
    } catch (const std::exception& error) {
      std::cerr << "route unavailable: " << error.what() << " " << body << "\n";
      continue;
    }
    for (const auto& route : api.trip().routes()) {
      for (const auto& leg : route.legs()) {
        if (leg.node_size() < 2) {
          continue;
        }
        const auto& end = leg.node(leg.node_size() - 1);
        if (end.recosts_size() != 1 || !end.recosts(0).has_elapsed_cost()) {
          std::cerr << "oracle recost unavailable: " << body << "\n";
          continue;
        }
        const auto& value = end.recosts(0).elapsed_cost();
        Path sample{{static_cast<float>(value.cost()), static_cast<float>(value.seconds())}, {}, body};
        for (int i = 0; i + 1 < leg.node_size(); ++i) {
          const auto& edge = leg.node(i).edge();
          const auto id = graph.dense.find(edge.id());
          if (id == graph.dense.end()) {
            sample.segments.clear();
            break;
          }
          sample.segments.push_back({id->second, edge.source_along_edge(), edge.target_along_edge()});
        }
        if (!sample.segments.empty()) {
          paths.push_back(std::move(sample));
        }
      }
    }
  }
  return paths;
}

void record(std::ostream& output,
            const rapidjson::Document& option,
            GraphReader& reader,
            tyr::actor_t& actor,
            const Graph& graph,
            uint32_t count,
            std::mt19937_64& random) {
  const char* mode = option["mode"].GetString();
  const bool pedestrian = std::string_view(mode) == "pedestrian";
  if (!pedestrian && std::string_view(mode) != "bicycle") {
    throw std::runtime_error("unsupported costing in reference options");
  }
  Costing config;
  google::protobuf::RepeatedPtrField<CodedDescription> warnings;
  if (pedestrian) {
    ParsePedestrianCostOptions(option, "/options", &config, warnings);
  } else {
    ParseBicycleCostOptions(option, "/options", &config, warnings);
  }
  if (!warnings.empty()) {
    throw std::runtime_error("out-of-range oracle costing options: " + json(option["options"]));
  }
  const auto cost = pedestrian ? CreatePedestrianCost(config) : CreateBicycleCost(config);
  std::vector<bool> allowed;
  allowed.reserve(graph.edges.size());
  for (const auto& ref : graph.edges) {
    allowed.push_back(cost->Allowed(ref.edge, ref.tile, ref.id) != 0);
  }
  std::vector<TurnCandidate> pairs;
  for (const auto& [from, to] : graph.turns) {
    if (!allowed[from] || !allowed[to]) {
      continue;
    }
    const auto& incoming = graph.edges[from];
    const auto& outgoing = graph.edges[to];
    const auto* node = outgoing.tile->node(incoming.edge->endnode());
    EdgeLabel previous(kInvalidLabel, incoming.id, incoming.edge, {}, 0, cost->travel_mode(),
                       0, kInvalidRestriction, false, false, InternalTurn::kNoTurn);
    previous.set_deadend(node->edge_count() == 1);
    uint8_t restriction = kInvalidRestriction;
    uint8_t destination_mask = 0;
    bool destination_only = false;
    // EdgeCost is evaluated after traversal admission. The overload used
    // during snapping has a different domain, notably for wheelchair surfaces.
    if (cost->Allowed(outgoing.edge, previous, outgoing.tile, outgoing.id, 0,
                      node->timezone(), restriction, destination_mask, &destination_only)) {
      pairs.push_back({from, to, destination_only});
    }
  }
  const uint32_t calls = pairs.empty() ? 0 : count;
  const auto routes = paths(actor, graph, option["paths"], mode, option["options"]);
  write(output, static_cast<uint32_t>(pedestrian ? 0 : 1));
  write(output, calls);
  write(output, static_cast<uint32_t>(routes.size()));
  write_string(output, json(option["options"]));
  const auto limited_reader = [&reader]() { return LimitedGraphReader(reader); };
  for (uint32_t i = 0; i < calls; ++i) {
    const auto [from, to, destination_only] = pairs[random() % pairs.size()];
    const auto& incoming = graph.edges[from];
    const auto& outgoing = graph.edges[to];
    const auto* node = outgoing.tile->node(incoming.edge->endnode());
    const EdgeLabel previous(kInvalidLabel, incoming.id, incoming.edge, {}, 0, cost->travel_mode(),
                             0, kInvalidRestriction, false, false, InternalTurn::kNoTurn);
    graph_tile_ptr reverse_tile;
    const DirectedEdge* reverse_edge = nullptr;
    const auto reverse_id = reader.GetOpposingEdgeId(outgoing.id, reverse_edge, reverse_tile);
    const EdgeLabel reverse(kInvalidLabel, reverse_id, reverse_edge, {}, 0, cost->travel_mode(), 0,
                            kInvalidRestriction, false, false, InternalTurn::kNoTurn, 0,
                            outgoing.edge->destonly());
    uint8_t sources = 0;
    const auto traversal = cost->EdgeCost(outgoing.edge, outgoing.id, outgoing.tile,
                                          TimeInfo::invalid(), sources);
    const auto forward = cost->TransitionCost(outgoing.edge, node, previous, outgoing.tile,
                                              limited_reader, destination_only);
    const auto backwards =
        cost->TransitionCostReverse(incoming.edge->opp_local_idx(), node, incoming.edge,
                                    outgoing.edge, reverse, incoming.tile, limited_reader,
                                    false, InternalTurn::kNoTurn, incoming.edge->destonly());
    write(output, Case{from, to, traversal, forward, backwards});
  }
  for (const auto& route : routes) {
    write(output, static_cast<uint32_t>(route.segments.size()));
    write(output, route.cost);
    write_string(output, route.request);
    for (const auto& segment : route.segments) {
      write(output, segment);
    }
  }
}

} // namespace

int main(int argc, char** argv) {
  if (argc != 6) {
    std::cerr << "usage: costing-reference CONFIG PROFILES CASES_PER_PROFILE BUNDLE_UUID OUTPUT\n";
    return 2;
  }
  try {
    uint32_t count = 0;
    const std::string_view count_arg(argv[3]);
    const auto parsed = std::from_chars(count_arg.begin(), count_arg.end(), count);
    const std::string_view uuid(argv[4]);
    if (parsed.ec != std::errc{} || parsed.ptr != count_arg.end() || count == 0 || uuid.size() != 32) {
      throw std::runtime_error("invalid sample count or bundle UUID");
    }
    boost::property_tree::ptree config;
    boost::property_tree::read_json(argv[1], config);
    GraphReader reader(config.get_child("mjolnir"));
    const Graph graph(reader);
    tyr::actor_t actor(config, true);
    std::ifstream input(argv[2]);
    std::ofstream out(argv[5], std::ios::binary);
    if (!input || !out || graph.edges.empty()) {
      throw std::runtime_error("could not open reference inputs or output");
    }
    out.exceptions(std::ios::badbit | std::ios::failbit);
    out.write("ZRCOST01", 8);
    out.write(uuid.data(), uuid.size());
    write(out, graph.nodes);
    write(out, static_cast<uint32_t>(graph.edges.size()));
    for (const auto& edge : graph.edges) {
      write(out, edge.id.value);
    }
    std::mt19937_64 random(0x7a52c057);
    std::string line;
    while (std::getline(input, line)) {
      rapidjson::Document option;
      option.Parse(line.c_str());
      if (option.HasParseError() || !option.IsObject() || !option.HasMember("mode") ||
          !option["mode"].IsString() || !option.HasMember("options") ||
          !option["options"].IsObject() || !option.HasMember("paths") || !option["paths"].IsArray()) {
        throw std::runtime_error("invalid costing option row");
      }
      record(out, option, reader, actor, graph, count, random);
    }
    out.close();
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
