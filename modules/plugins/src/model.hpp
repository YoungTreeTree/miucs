#pragma once
#include "json.hpp"
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <vector>
namespace miucs {
using Json = nlohmann::json;
constexpr size_t MaxPacket = 2 * 1024 * 1024, MaxNodes = 4096, MaxPath = 16384;
constexpr size_t MaxSceneBytes = 16 * 1024 * 1024;
constexpr size_t MaxAsset = 16 * 1024 * 1024;
struct Error : std::runtime_error { using runtime_error::runtime_error; };
std::filesystem::path contained(const std::filesystem::path& root, const std::string& relative);
std::string readFile(const std::filesystem::path&, size_t limit = MaxAsset);
std::string readResource(const std::filesystem::path& root,const std::string& relative,size_t limit=MaxAsset);
Json manifest(const std::filesystem::path& root);
Json catalog(const std::vector<std::filesystem::path>& roots);
void validateNode(const Json& node);
void validateProperties(const Json&);
Json patchedNode(const Json&,const Json&);
size_t valueCost(const Json&);
size_t patchedCost(size_t before,const Json& current,const Json& changes);
struct Scene {
  std::map<std::string, std::shared_ptr<const Json>> nodes;
  std::map<std::string,size_t> costs;
  size_t bytes=0;
  uint64_t version = 0;
  void put(const std::string& id,Json node,size_t cost);
  // False only for an unchanged, empty delta; full snapshots are always applied.
  bool apply(const Json& packet);
};
std::vector<uint8_t> encode(const Json&);
Json decode(const uint8_t*, size_t);
bool readPacket(std::istream&, Json&);
void writePacket(std::ostream&, const Json&);
}
