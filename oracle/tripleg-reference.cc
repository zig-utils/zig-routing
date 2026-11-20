// Test-only capture of the pinned Valhalla actor's trip legs.
#include <boost/property_tree/json_parser.hpp>
#include <valhalla/proto/api.pb.h>
#include <valhalla/tyr/actor.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <string_view>

int main(int argc, char** argv) {
  if (argc != 5) {
    std::cerr << "usage: tripleg-reference CONFIG CORPUS OUTPUT_DIR CASES\n";
    return 2;
  }
  boost::property_tree::ptree config;
  boost::property_tree::read_json(argv[1], config);
  valhalla::tyr::actor_t actor(config, true);
  std::ifstream rows(argv[2]);
  if (!rows) return 2;
  const auto limit = std::stoul(argv[4]);
  const std::filesystem::path output(argv[3]);
  std::filesystem::create_directories(output);
  std::string line;
  bool failed = false;
  for (size_t index = 0; index < limit && std::getline(rows, line); ++index) {
    constexpr auto route = std::string_view("/route\t");
    if (!line.starts_with(route)) return 2;
    valhalla::Api api;
    try {
      actor.route(line.substr(route.size()), nullptr, &api);
    } catch (const std::exception& error) {
      std::cerr << "route " << index << ": " << error.what() << '\n';
      failed = true;
      continue;
    }
    std::ofstream wire(output / (std::to_string(index) + ".bin"), std::ios::binary);
    if (!api.SerializeToOstream(&wire)) return 2;
  }
  return failed ? 1 : 0;
}
