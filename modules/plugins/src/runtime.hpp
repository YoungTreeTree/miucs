#pragma once
#include "model.hpp"
#include <chrono>
#include <set>
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}
namespace miucs {
class Runtime {
  lua_State* L=nullptr;
  size_t allocated=0;
  uint64_t deadline=0;
  static uint64_t cpuTime();
  std::filesystem::path root;
  Json metadata;
  int callbacks=LUA_NOREF;
  uint64_t rng=1;
  bool disposed=false;
  std::set<std::string> dirty, removed;
  std::map<std::string,Json> patches;
  static void* allocate(void*,void*,size_t,size_t);
  static void hook(lua_State*,lua_Debug*);
  static int callApi(lua_State*);
  int api(lua_State*);
  Json fromLua(int,int depth=0);
  void toLua(const Json&);
  void addTree(Json node,const std::string& parent="",int depth=0);
  void invoke(const char*,const Json&,int budgetMs=50);
  int loadSource(const std::string&);
public:
  Scene scene;
  double lastUpdateMs=0;
  Runtime(const std::filesystem::path&,uint64_t seed=1);
  ~Runtime();
  Runtime(const Runtime&)=delete;
  Json handle(const Json&);
  Json packet(uint64_t ack);
  size_t memory() const {return allocated;}
};
}
