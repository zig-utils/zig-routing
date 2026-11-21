// Test-time path and endpoint reference for the pinned Valhalla image.
#include <algorithm>
#include <boost/property_tree/json_parser.hpp>
#include <chrono>
#include <fstream>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <rapidjson/document.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#include <valhalla/baldr/time_info.h>
#include <valhalla/loki/worker.h>
#include <valhalla/midgard/logging.h>
#include <valhalla/thor/triplegbuilder.h>
#include <valhalla/thor/worker.h>

#include "transit-itinerary-audit.h"

using namespace valhalla;
using Json = rapidjson::Writer<rapidjson::StringBuffer>;

class ObservedTransit : public thor::MultiModalPathAlgorithm {
public:
  using MultiModalPathAlgorithm::MultiModalPathAlgorithm;

  void WriteLabels(Json& out, const std::vector<transit_audit::Movement>& path) const {
    out.Key("stock_labels");
    out.StartArray();
    for (const auto& step : path) {
      const auto state = edgestatus_.Get(step.edge);
      if (state.set() != thor::EdgeSet::kTemporary && state.set() != thor::EdgeSet::kPermanent) {
        out.Null();
        continue;
      }
      const auto& label = edgelabels_.at(state.index());
      out.StartObject();
      out.Key("settled");
      out.Bool(state.set() == thor::EdgeSet::kPermanent);
      out.Key("cost");
      out.Double(label.cost().cost);
      out.Key("elapsed");
      out.Double(label.cost().secs);
      out.Key("walking_distance");
      out.Uint(label.walking_distance());
      out.Key("trip");
      out.Uint(label.tripid());
      if (label.predecessor() != baldr::kInvalidLabel) {
        out.Key("predecessor");
        out.Uint64(edgelabels_.at(label.predecessor()).edgeid().value);
      }
      out.EndObject();
    }
    out.EndArray();
  }
};

class TransitReference : public thor::thor_worker_t {
public:
  explicit TransitReference(const boost::property_tree::ptree& config)
      : thor_worker_t(config), observed(config.get_child("thor")) {
  }

  std::vector<thor::PathInfo> Search(Api& api, bool audit = false) {
    adjust_locations(api);
    const auto costing = parse_costing(api);
    auto& locations = *api.mutable_options()->mutable_locations();
    if (locations.size() != 2)
      throw std::runtime_error("expected two locations");
    auto* algorithm = get_path_algorithm(costing, locations[0], locations[1], api);
    if (audit) {
      if (algorithm != &multi_modal_transit)
        throw std::runtime_error("expected the scheduled multimodal algorithm");
      algorithm = &observed;
    }
    algorithm->Clear();
    auto paths = get_path(algorithm, locations[0], locations[1], costing, api);
    if (paths.empty())
      throw valhalla_exception_t{442};
    return std::move(paths.front());
  }

  TripLeg Describe(Api& api, const std::vector<thor::PathInfo>& path) {
    TripLeg leg;
    auto& opts = *api.mutable_options();
    baldr::AttributesController attributes(opts);
    thor::TripLegBuilder::Build(opts, attributes, *reader, mode_costing, path.begin(), path.end(),
                                *opts.mutable_locations(0), *opts.mutable_locations(1), leg,
                                {"multimodal"}, nullptr);
    return leg;
  }

  std::vector<std::optional<int64_t>> BoardingTimes(Api& api,
                                                  const std::vector<thor::PathInfo>& path) {
    auto& origin = *api.mutable_options()->mutable_locations(0);
    baldr::DateTime::tz_sys_info_cache_t cache;
    const auto start = baldr::TimeInfo::make(origin, *reader, &cache);
    std::vector<std::optional<int64_t>> times(path.size());
    for (size_t i = 0; i < path.size(); ++i) {
      if (path[i].mode != sif::TravelMode::kPublicTransit)
        continue;
      if (i == 0)
        throw std::runtime_error("expected a walking origin before boarding");
      const auto ride = RideAt(path[i - 1], path[i], start);
      const auto* departure =
          ride.tile->GetTransitDeparture(ride.edge->lineid(), path[i].trip_id, ride.ready.day_seconds());
      if (!departure)
        continue;
      // GraphTile owns fixed rows and returns a new row for a frequency occurrence.
      std::unique_ptr<const baldr::TransitDeparture> frequency;
      if (departure->type() == baldr::kFrequencySchedule)
        frequency.reset(departure);
      const auto* zone = baldr::DateTime::get_tz_db().from_index(ride.ready.timezone_index);
      if (!zone)
        continue;
      const date::sys_seconds instant{std::chrono::seconds{ride.ready.unix_time}};
      const auto local = date::make_zoned(zone, instant).get_local_time();
      const auto boarding = date::floor<date::days>(local) +
                            std::chrono::seconds{departure->departure_time()};
      times[i] = baldr::DateTime::get_ldt(boarding, zone).get_sys_time().time_since_epoch().count();
    }
    return times;
  }

  void Audit(Json& out, Api& api, const std::vector<thor::PathInfo>& path,
             const std::vector<std::optional<int64_t>>& boarding, const rapidjson::Value& native) {
    std::vector<transit_audit::Movement> stock, other;
    for (size_t i = 0; i < path.size(); ++i) {
      transit_audit::Movement step;
      step.edge = path[i].edgeid;
      step.expected = path[i].elapsed_cost;
      if (path[i].mode == sif::TravelMode::kPublicTransit) {
        step.trip = path[i].trip_id;
        step.board = boarding[i];
      }
      stock.push_back(step);
    }
    for (const auto& item : native.GetArray()) {
      transit_audit::Movement step;
      step.edge = baldr::GraphId(item["edge"].GetUint64());
      step.expected.cost = item["cost"].GetFloat();
      step.expected.secs = item["elapsed"].GetFloat();
      if (item.HasMember("trip")) {
        step.trip = item["trip"].GetUint();
        step.board = item["board_time"].GetInt64();
      } else {
        step.begin = item["begin"].GetFloat();
        step.end = item["end"].GetFloat();
      }
      other.push_back(step);
    }
    out.Key("stock_audit");
    WriteAudit(out, transit_audit::replay(*reader, mode_costing, *api.mutable_options(), stock));
    out.Key("native_audit");
    WriteAudit(out, transit_audit::replay(*reader, mode_costing, *api.mutable_options(), other));
    observed.WriteLabels(out, other);
  }

  void Offers(Json& out, Api& api, const std::vector<thor::PathInfo>& path) {
    const auto ride = std::find_if(path.begin(), path.end(), [](const auto& step) {
      return step.mode == sif::TravelMode::kPublicTransit;
    });
    if (ride == path.begin() || ride == path.end() ||
        std::any_of(ride + 1, path.end(), [](const auto& step) {
          return step.mode == sif::TravelMode::kPublicTransit;
        }))
      throw std::runtime_error("expected one ride with preceding walking access");
    auto& origin = *api.mutable_options()->mutable_locations(0);
    baldr::DateTime::tz_sys_info_cache_t cache;
    const auto start = baldr::TimeInfo::make(origin, *reader, &cache);
    const auto at = RideAt(*(ride - 1), *ride, start);
    const auto& tile = at.tile;
    const auto* edge = at.edge;
    const auto ready = at.ready.day_seconds();
    const auto date = baldr::DateTime::days_from_pivot_date(baldr::DateTime::get_formatted_date(origin.date_time()));
    const auto creation = tile->header()->date_created();
    const auto dow = baldr::DateTime::day_of_week_mask(origin.date_time());
    const auto& cost = mode_costing[static_cast<unsigned>(sif::TravelMode::kPublicTransit)];
    const auto selected = tile->GetTransitDeparture(edge->lineid(), ride->trip_id, ready);
    if (!selected || selected->type() != baldr::kFixedSchedule)
      throw std::runtime_error("expected a selected fixed departure");
    const auto other_cost = path.back().elapsed_cost.cost - cost->EdgeCost(edge, selected, ready).cost;
    out.Key("offers");
    out.StartArray();
    for (auto seek = ready;;) {
      const auto* offer = tile->GetNextDeparture(edge->lineid(), seek, date < creation ? 0 : date - creation,
                                                dow, date < creation, cost->wheelchair(), cost->bicycle());
      if (!offer)
        break;
      if (offer->type() != baldr::kFixedSchedule)
        throw std::runtime_error("expected a fixed departure");
      out.StartObject();
      out.Key("trip");
      out.Uint(offer->tripid());
      out.Key("start");
      out.Uint(offer->departure_time());
      out.Key("duration");
      out.Uint(offer->elapsed_time());
      out.Key("cost");
      out.Double(other_cost + cost->EdgeCost(edge, offer, ready).cost);
      out.EndObject();
      seek = offer->departure_time() + 1;
    }
    out.EndArray();
  }

private:
  ObservedTransit observed;

  static void WriteAudit(Json& out, const transit_audit::Result& result) {
    out.StartObject();
    out.Key("walking_limit");
    out.Uint(result.walking_limit);
    if (result.blocked) {
      out.Key("blocked_at");
      out.Uint64(result.steps.size());
      out.Key("reason");
      out.String(result.blocked);
    } else {
      out.Key("cost");
      out.Double(result.steps.back().total.cost);
      out.Key("elapsed");
      out.Double(result.steps.back().total.secs);
    }
    if (result.first_cost_difference) {
      out.Key("first_cost_difference");
      out.Uint64(*result.first_cost_difference);
    }
    if (result.terminal_gate) {
      out.Key("terminal_gate");
      out.StartObject();
      out.Key("step");
      out.Uint64(result.terminal_gate->step);
      out.Key("full_walk");
      out.Uint(result.terminal_gate->full_walk);
      out.Key("clipped_walk");
      out.Uint(result.terminal_gate->clipped_walk);
      out.Key("limit");
      out.Uint(result.terminal_gate->limit);
      out.EndObject();
    }
    out.Key("steps");
    out.StartArray();
    for (const auto& step : result.steps) {
      out.StartObject();
      out.Key("cost");
      out.Double(step.total.cost);
      out.Key("elapsed");
      out.Double(step.total.secs);
      out.Key("walking_distance");
      out.Uint(step.walking_distance);
      if (step.ready) {
        out.Key("ready");
        out.Uint64(*step.ready);
        out.Key("exact_second");
        out.Uint(step.exact_second);
        out.Key("stock_second");
        out.Uint(step.stock_second);
        out.Key("boarding_transition");
        out.Double(step.boarding_transition);
      }
      if (step.stock_next) {
        out.Key("stock_next");
        out.StartObject();
        out.Key("trip");
        out.Uint(step.stock_next->trip);
        out.Key("departure");
        out.Uint(step.stock_next->departure);
        out.Key("elapsed");
        out.Uint(step.stock_next->elapsed);
        out.EndObject();
      }
      out.EndObject();
    }
    out.EndArray();
    out.EndObject();
  }

  struct TimedRide {
    baldr::graph_tile_ptr tile;
    const baldr::DirectedEdge* edge;
    baldr::TimeInfo ready;
  };

  TimedRide RideAt(const thor::PathInfo& previous, const thor::PathInfo& ride,
                   const baldr::TimeInfo& start) {
    baldr::graph_tile_ptr tile, preceding_tile, node_tile;
    const auto* edge = reader->directededge(ride.edgeid, tile);
    const auto* preceding = reader->directededge(previous.edgeid, preceding_tile);
    if (!edge || !preceding)
      throw std::runtime_error("cannot resolve ride edges");
    const auto* node = reader->GetEndNode(preceding, node_tile);
    if (!node)
      throw std::runtime_error("cannot resolve the boarding platform");
    return {tile, edge, start.forward(previous.elapsed_cost.secs, node->timezone())};
  }
};

template <class Edges> void write_candidates(Json& out, const Edges& edges) {
  out.StartArray();
  for (const auto& edge : edges) {
    out.StartObject();
    out.Key("edge");
    out.Uint64(edge.graph_id());
    out.Key("fraction");
    out.Double(edge.percent_along());
    out.Key("distance");
    out.Double(edge.distance());
    out.Key("lng");
    out.Double(edge.ll().lng());
    out.Key("lat");
    out.Double(edge.ll().lat());
    out.Key("begin");
    out.Bool(edge.begin_node());
    out.Key("end");
    out.Bool(edge.end_node());
    out.EndObject();
  }
  out.EndArray();
}

void write_cuts(Json& out, const Options& opts) {
  out.Key("cuts");
  out.StartArray();
  for (const auto& location : opts.locations()) {
    out.StartObject();
    out.Key("edges");
    write_candidates(out, location.correlation().edges());
    out.Key("filtered");
    write_candidates(out, location.correlation().filtered_edges());
    out.Key("rank");
    out.Bool(!location.skip_ranking_candidates());
    out.EndObject();
  }
  out.EndArray();
}

void write_path(Json& out, const std::vector<thor::PathInfo>& path, const TripLeg& leg,
                const std::vector<std::optional<int64_t>>& boarding_times) {
  if (leg.node_size() != path.size() + 1)
    throw std::runtime_error("trip leg and path have different edge counts");
  out.Key("cost");
  out.Double(path.back().elapsed_cost.cost);
  out.Key("elapsed");
  out.Double(path.back().elapsed_cost.secs);
  out.Key("steps");
  out.StartArray();
  for (size_t i = 0; i < path.size(); ++i) {
    out.StartObject();
    out.Key("edge");
    out.Uint64(path[i].edgeid.value);
    out.Key("cost");
    out.Double(path[i].elapsed_cost.cost);
    out.Key("elapsed");
    out.Double(path[i].elapsed_cost.secs);
    if (path[i].mode == sif::TravelMode::kPublicTransit) {
      const auto& from = leg.node(i);
      const auto& to = leg.node(i + 1);
      const auto& route = from.edge().transit_route_info();
      out.Key("trip");
      out.Uint(path[i].trip_id);
      out.Key("route");
      out.String(route.onestop_id().c_str());
      out.Key("origin");
      out.String(from.transit_platform_info().onestop_id().c_str());
      out.Key("destination");
      out.String(to.transit_platform_info().onestop_id().c_str());
      out.Key("board");
      out.String(from.transit_platform_info().departure_date_time().c_str());
      if (boarding_times[i]) {
        out.Key("board_time");
        out.Int64(*boarding_times[i]);
      }
    }
    out.EndObject();
  }
  out.EndArray();
}

int main(int argc, const char** argv) {
  const bool offers = argc == 4 && std::string(argv[3]) == "--offers";
  const bool audit = argc == 5 && std::string(argv[3]) == "--audit";
  if (argc != 3 && !offers && !audit) {
    std::cerr << "usage: transit-itinerary-reference CONFIG CORPUS.tsv [--offers | --audit NATIVE.jsonl]\n";
    return 2;
  }
  boost::property_tree::ptree config;
  boost::property_tree::read_json(argv[1], config);
  midgard::logging::Configure({{"type", "std_err"}});
  loki::loki_worker_t loki(config);
  TransitReference thor(config);
  std::ifstream corpus(argv[2]);
  if (!corpus)
    return 2;
  std::ifstream audit_input;
  if (audit) {
    audit_input.open(argv[4]);
    if (!audit_input)
      return 2;
  }
  std::string row;
  for (size_t index = 0; std::getline(corpus, row); ++index) {
    if (row.rfind("/route\t", 0) != 0)
      return 2;
    rapidjson::Document native;
    if (audit) {
      std::string input;
      if (!std::getline(audit_input, input) || native.Parse(input.c_str()).HasParseError() ||
          !native.IsObject() || !native.HasMember("index") || !native["index"].IsUint64() ||
          native["index"].GetUint64() != index || !native.HasMember("steps") || !native["steps"].IsArray())
        return 2;
    }
    rapidjson::StringBuffer buffer;
    Json out(buffer);
    out.StartObject();
    out.Key("index");
    out.Uint64(index);
    Api api;
    try {
      ParseApi(row.substr(7), Options::route, api);
      loki.route(api);
      write_cuts(out, api.options());
      const auto path = thor.Search(api, audit);
      const auto boarding_times = thor.BoardingTimes(api, path);
      const auto leg = thor.Describe(api, path);
      write_path(out, path, leg, boarding_times);
      if (offers)
        thor.Offers(out, api, path);
      if (audit)
        thor.Audit(out, api, path, boarding_times, native["steps"]);
    } catch (const valhalla_exception_t& error) {
      out.Key("error_code");
      out.Uint(error.code);
    } catch (const std::exception& error) {
      std::cerr << "request " << index << ": " << error.what() << '\n';
      return 1;
    }
    out.EndObject();
    std::cout << buffer.GetString() << '\n';
    thor.cleanup();
    loki.cleanup();
  }
  return corpus.eof() && std::cout && (!audit || audit_input.peek() == EOF) ? 0 : 2;
}
