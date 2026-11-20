// Test-time measurement correlation reference for the pinned Valhalla image.
#include <boost/property_tree/json_parser.hpp>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <valhalla/meili/candidate_search.h>
#include <valhalla/meili/config.h>
#include <valhalla/midgard/logging.h>
#include <valhalla/sif/costfactory.h>

struct Measurement {
  valhalla::midgard::PointLL point;
  float square_radius;
};

int main(int argc, const char** argv) {
  if (argc != 4) {
    std::cerr << "usage: trace-candidates-reference CONFIG MEASUREMENTS CANDIDATES_TSV\n";
    return 2;
  }
  using namespace valhalla;
  boost::property_tree::ptree config;
  boost::property_tree::read_json(argv[1], config);
  midgard::logging::Configure({{"type", "std_err"}});
  baldr::GraphReader reader(config.get_child("mjolnir"));
  sif::CostFactory factory;
  const auto costing = factory.Create(Costing::auto_);
  const meili::Config meili_config(config.get_child("meili"));
  const float cell = baldr::TileHierarchy::levels().back().tiles.TileSize() /
                     meili_config.candidate_search.grid_size;
  meili::CandidateGridQuery query(reader, cell, cell);
  std::ifstream input(argv[2]);
  std::ofstream candidates(argv[3]);
  if (!input || !candidates) return 2;
  candidates << std::setprecision(17);
  std::vector<Measurement> measurements;
  double lat, lon;
  float radius, accuracy;
  while (input >> lat >> lon >> radius >> accuracy) {
    const auto effective = std::min(meili_config.candidate_search.max_search_radius_meters,
                                    std::max(radius, accuracy));
    measurements.push_back({{lon, lat}, effective * effective});
  }
  if (!input.eof()) return 2;
  for (const auto& row : measurements)
    query.Query(row.point, Location_Type_kVia, row.square_radius, costing);
  for (size_t i = 0; i < measurements.size(); ++i) {
    const auto& row = measurements[i];
    const auto start = std::chrono::steady_clock::now();
    const auto found = query.Query(row.point, Location_Type_kVia, row.square_radius, costing);
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - start);
    std::cout << i << '\t' << elapsed.count() << '\t' << found.size() << '\n';
    for (const auto& candidate : found) {
      for (const auto& edge : candidate.correlation().edges()) {
        const baldr::GraphId id(edge.graph_id());
        int64_t node = -1;
        if (edge.begin_node()) {
          const auto opposing = reader.GetOpposingEdgeId(id);
          if (const auto* arc = reader.directededge(opposing)) node = arc->endnode().value;
        } else if (edge.end_node()) {
          if (const auto* arc = reader.directededge(id)) node = arc->endnode().value;
        }
        candidates << i << '\t' << node << '\t' << id.value << '\t' << edge.percent_along() << '\t'
                   << edge.ll().lat() << '\t' << edge.ll().lng() << '\t' << edge.distance() << '\n';
      }
    }
  }
  return candidates.good() ? 0 : 2;
}
