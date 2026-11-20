// Test-time grid and label reference for the pinned Valhalla image.
#include <boost/property_tree/json_parser.hpp>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <valhalla/loki/worker.h>
#include <valhalla/midgard/logging.h>
#include <valhalla/sif/costfactory.h>
#include <valhalla/thor/isochrone.h>

class ReferenceIsochrone : public valhalla::thor::Isochrone {
public:
  using Isochrone::Isochrone;

  void Trace(std::ostream& out, size_t request, bool reverse) const {
    for (size_t i = 0; i < bdedgelabels_.size(); ++i) {
      const auto& label = bdedgelabels_[i];
      const auto edge = reverse ? label.opp_edgeid() : label.edgeid();
      out << request << '\t' << i << '\t' << edge.value << '\t' << label.predecessor()
          << '\t' << label.cost().secs << '\t' << label.cost().cost << '\t'
          << label.path_distance() << '\n';
    }
  }
};

int main(int argc, const char** argv) {
  if (argc != 4 && argc != 5) {
    std::cerr << "usage: isochrone-reference CONFIG REQUESTS GRID_BIN [LABEL_TSV]\n";
    return 2;
  }
  using namespace valhalla;
  boost::property_tree::ptree config;
  boost::property_tree::read_json(argv[1], config);
  midgard::logging::Configure({{"type", "std_err"}});
  loki::loki_worker_t loki(config);
  baldr::GraphReader reader(config.get_child("mjolnir"));
  sif::CostFactory factory;
  ReferenceIsochrone engine(config);
  std::ifstream corpus(argv[2]);
  std::ofstream grids(argv[3], std::ios::binary);
  std::ofstream traces;
  if (argc == 5) {
    traces.open(argv[4]);
    traces << std::setprecision(17);
    if (!traces) return 2;
  }
  if (!corpus || !grids) return 2;

  std::cout << std::setprecision(17);
  std::string json;
  size_t index = 0;
  while (std::getline(corpus, json)) {
    if (json.empty()) continue;
    Api api;
    try {
      ParseApi(json, Options::isochrone, api);
      loki.isochrones(api);
      sif::TravelMode mode;
      const auto costings = factory.CreateModeCosting(api.options(), mode);
      const bool reverse = api.options().reverse();
      const auto direction = reverse ? thor::ExpansionType::reverse : thor::ExpansionType::forward;
      std::shared_ptr<const midgard::GriddedData<2>> grid;
      std::chrono::nanoseconds elapsed{};
      for (int run = 0; run < 2; ++run) {
        engine.Clear();
        const auto start = std::chrono::steady_clock::now();
        grid = engine.Expand(direction, api, reader, costings, mode);
        elapsed = std::chrono::steady_clock::now() - start;
      }
      const auto bounds = grid->TileBounds();
      std::cout << index << '\t' << elapsed.count() << '\t' << grid->ncolumns() << '\t'
                << grid->nrows() << '\t' << grid->TileSize() << '\t' << bounds.minx() << '\t'
                << bounds.miny() << '\t' << bounds.maxx() << '\t' << bounds.maxy() << '\n';
      for (size_t cell = 0; cell != size_t(grid->ncolumns()) * grid->nrows(); ++cell) {
        const float values[] = {grid->DataAt(cell, 0), grid->DataAt(cell, 1)};
        grids.write(reinterpret_cast<const char*>(values), sizeof values);
      }
      if (argc == 5) engine.Trace(traces, index, reverse);
      loki.cleanup();
    } catch (const valhalla_exception_t& error) {
      std::cerr << "request " << index << " error " << error.code << ": " << error.what() << '\n';
      return 1;
    }
    ++index;
  }
  return corpus.eof() && grids && (argc == 4 || traces.good()) ? 0 : 2;
}
