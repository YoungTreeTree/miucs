#include "runtime.hpp"
#include <cstdlib>
#include <cstring>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif
namespace miucs {
void* Runtime::allocate(void* ud,void* ptr,size_t old,size_t size) {
  auto* self=static_cast<Runtime*>(ud); if(!ptr)old=0;
  if(size==0){self->allocated-=old;std::free(ptr);return nullptr;}
  if(size>32*1024*1024 || self->allocated-old>32*1024*1024-size)return nullptr;
  void* p=std::realloc(ptr,size);if(p)self->allocated=self->allocated-old+size;return p;
}
uint64_t Runtime::cpuTime() {
#ifdef _WIN32
  FILETIME created,exited,kernel,user;
  if(!GetThreadTimes(GetCurrentThread(),&created,&exited,&kernel,&user))throw Error("Cannot read worker CPU clock");
  return ((uint64_t(kernel.dwHighDateTime)<<32|kernel.dwLowDateTime)+(uint64_t(user.dwHighDateTime)<<32|user.dwLowDateTime))*100;
#else
  timespec value{};if(clock_gettime(CLOCK_THREAD_CPUTIME_ID,&value))throw Error("Cannot read worker CPU clock");return uint64_t(value.tv_sec)*1000000000+value.tv_nsec;
#endif
}
void Runtime::hook(lua_State* L,lua_Debug*) {
  auto* self=*static_cast<Runtime**>(lua_getextraspace(L));
  if(cpuTime()>self->deadline)luaL_error(L,"Script execution budget exceeded");
}
Json Runtime::fromLua(int index,int depth) {
  if(depth>24)throw Error("Lua table nesting limit exceeded");
  switch(lua_type(L,index)) {
    case LUA_TNIL:return nullptr;
    case LUA_TBOOLEAN:return bool(lua_toboolean(L,index));
    case LUA_TNUMBER:if(lua_isinteger(L,index))return lua_tointeger(L,index);else {double v=lua_tonumber(L,index);if(!std::isfinite(v))throw Error("Non-finite Lua number");return v;}
    case LUA_TSTRING:{size_t n;const char* s=lua_tolstring(L,index,&n);if(n>65536)throw Error("String limit exceeded");return std::string(s,n);}
    case LUA_TTABLE:{
      int absolute=lua_absindex(L,index);size_t n=lua_rawlen(L,absolute);Json v=n?Json::array():Json::object();
      size_t count=0;lua_pushnil(L);
      while(lua_next(L,absolute)) {
        if(++count>MaxPath)throw Error("Table size limit exceeded");
        if(n){if(!lua_isinteger(L,-2)||lua_tointeger(L,-2)<1||size_t(lua_tointeger(L,-2))>n)throw Error("Mixed Lua table");}
        else {if(lua_type(L,-2)!=LUA_TSTRING)throw Error("Object keys must be strings");v[lua_tostring(L,-2)]=fromLua(-1,depth+1);}
        lua_pop(L,1);
      }
      if(n){if(n>MaxPath)throw Error("Array limit exceeded");for(size_t i=1;i<=n;++i){lua_rawgeti(L,absolute,i);v.push_back(fromLua(-1,depth+1));lua_pop(L,1);}}
      return v;
    }
    default:throw Error("Unsupported Lua value");
  }
}
void Runtime::toLua(const Json& j) {
  if(j.is_null())lua_pushnil(L);
  else if(j.is_boolean())lua_pushboolean(L,j.get<bool>());
  else if(j.is_number_integer())lua_pushinteger(L,j.get<lua_Integer>());
  else if(j.is_number())lua_pushnumber(L,j.get<double>());
  else if(j.is_string()){auto& s=j.get_ref<const std::string&>();lua_pushlstring(L,s.data(),s.size());}
  else {lua_createtable(L,j.is_array()?int(j.size()):0,j.is_object()?int(j.size()):0);
    if(j.is_array()){int i=1;for(auto& value:j){toLua(value);lua_rawseti(L,-2,i++);}}
    else for(auto& [key,value]:j.items()){toLua(value);lua_setfield(L,-2,key.c_str());}
  }
}
int Runtime::loadSource(const std::string& file) {
  if(std::filesystem::path(file).extension()!=".lua")throw Error("Only Lua source modules are allowed");
  auto text=readResource(root,file,1024*1024);
  if(luaL_loadbufferx(L,text.data(),text.size(),file.c_str(),"t")!=LUA_OK)throw Error(lua_tostring(L,-1));
  return 1;
}
void Runtime::addTree(Json node,const std::string& parent,int depth) {
  if(depth>24 || scene.nodes.size()>=MaxNodes)throw Error("Scene size limit exceeded");
  auto children=node.value("children",Json::array());node.erase("children");node["parent"]=parent;
  if(node.contains("path") && node["path"].empty())node["path"]=Json::array();
  validateNode(node);std::string id=node["id"];
  if(scene.nodes.contains(id))throw Error("Duplicate node id: "+id);
  node["order"]=scene.nodes.size();scene.put(id,node,valueCost(node));dirty.insert(id);patches[id]=node;
  for(auto& child:children)addTree(child,id,depth+1);
}
int Runtime::api(lua_State*) {
  std::string op=lua_tostring(L,lua_upvalueindex(2));
  if(op=="load"){addTree(fromLua(1));return 0;}
  if(op=="set") {
    if(lua_type(L,1)!=LUA_TSTRING)throw Error("Expected node id");std::string id=lua_tostring(L,1);
    if(!scene.nodes.contains(id))throw Error("Unknown node: "+id);
    auto p=fromLua(2);if(!p.is_object()||p.contains("id")||p.contains("type")||p.contains("parent"))throw Error("Cannot mutate node identity or hierarchy");
    if(p.contains("path") && p["path"].empty())p["path"]=Json::array();
    const auto& current=*scene.nodes.at(id);
    Json changes=Json::object();for(auto& [key,value]:p.items())if(!current.contains(key)||current[key]!=value)changes[key]=value;
    if(changes.empty())return 0;
    validateProperties(changes);
    Json next=patchedNode(current,changes);
    auto cost=patchedCost(scene.costs.at(id),current,changes);scene.put(id,std::move(next),cost);dirty.insert(id);
    if(!patches.contains(id))patches[id]=Json::object();patches[id].update(changes);patches[id]["id"]=id;
    return 0;
  }
  if(op=="random") {rng=rng*6364136223846793005ULL+1442695040888963407ULL;lua_pushnumber(L,double(rng>>11)/9007199254740992.0);return 1;}
  if(op=="require") {
    if(lua_type(L,1)!=LUA_TSTRING)throw Error("Expected module path");std::string file=lua_tostring(L,1);
    if(file.size()>200)throw Error("Module name too long");
    lua_getfield(L,LUA_REGISTRYINDEX,"miucs.modules");lua_getfield(L,-1,file.c_str());
    if(!lua_isnil(L,-1))return 1;lua_pop(L,1);
    loadSource(file);if(lua_pcall(L,0,1,0)!=LUA_OK)throw Error(lua_tostring(L,-1));
    lua_pushvalue(L,-1);lua_setfield(L,-3,file.c_str());return 1;
  }
  throw Error("Unknown context operation");
}
int Runtime::callApi(lua_State* L) {
  auto* self=static_cast<Runtime*>(lua_touserdata(L,lua_upvalueindex(1)));
  // Never longjmp across a live C++ exception or local RAII object.
  try{return self->api(L);}catch(const std::exception& e){lua_pushstring(L,e.what());}
  return lua_error(L);
}
Runtime::Runtime(const std::filesystem::path& folder,uint64_t seed):root(std::filesystem::canonical(folder)),metadata(manifest(root)),rng(seed) {
  L=lua_newstate(allocate,this);if(!L)throw Error("Cannot allocate Lua state");
  *static_cast<Runtime**>(lua_getextraspace(L))=this;
  try {
    for(auto [name,open]:std::initializer_list<std::pair<const char*,lua_CFunction>>{{"_G",luaopen_base},{LUA_MATHLIBNAME,luaopen_math},{LUA_TABLIBNAME,luaopen_table},{LUA_STRLIBNAME,luaopen_string},{LUA_UTF8LIBNAME,luaopen_utf8}}){luaL_requiref(L,name,open,1);lua_pop(L,1);}
    for(auto name:{"dofile","loadfile","load","collectgarbage","print"}){lua_pushnil(L);lua_setglobal(L,name);}
    lua_getglobal(L,"math");for(auto name:{"random","randomseed"}){lua_pushnil(L);lua_setfield(L,-2,name);}lua_pop(L,1);
    lua_newtable(L);lua_setfield(L,LUA_REGISTRYINDEX,"miucs.modules");
    lua_newtable(L);
    for(auto name:{"load","set","random","require"}){lua_pushlightuserdata(L,this);lua_pushstring(L,name);lua_pushcclosure(L,callApi,2);lua_setfield(L,-2,name);}
    lua_setglobal(L,"miucs");
    deadline=cpuTime()+250000000;lua_sethook(L,hook,LUA_MASKCOUNT,1000);
    loadSource(metadata["entry"]);if(lua_pcall(L,0,1,0)!=LUA_OK)throw Error(lua_tostring(L,-1));
    if(!lua_istable(L,-1))throw Error("Plugin entry must return lifecycle table");callbacks=luaL_ref(L,LUA_REGISTRYINDEX);
    invoke("create",{{"api",1},{"seed",seed}},250);
    // Check the entire hierarchy before publishing the first frame.
    auto first=packet(0);Scene checked;checked.apply(first);
  }catch(...){lua_close(L);L=nullptr;throw;}
}
Runtime::~Runtime(){if(L)lua_close(L);}
void Runtime::invoke(const char* name,const Json& argument,int budgetMs) {
  int top=lua_gettop(L);deadline=cpuTime()+uint64_t(budgetMs)*1000000;
  lua_rawgeti(L,LUA_REGISTRYINDEX,callbacks);lua_getfield(L,-1,name);
  if(lua_isnil(L,-1)){lua_settop(L,top);return;}
  if(!lua_isfunction(L,-1)){lua_settop(L,top);throw Error("Lifecycle callback is not a function");}
  toLua(argument);
  if(lua_pcall(L,1,0,0)!=LUA_OK){std::string error=lua_tostring(L,-1)?lua_tostring(L,-1):"Lua callback failed";lua_settop(L,top);throw Error(error);}
  lua_settop(L,top);
}
Json Runtime::packet(uint64_t ack) {
  uint64_t base=scene.version;
  bool full=ack!=base || base==0;
  Json nodes=Json::array();
  if(full)for(auto& [id,n]:scene.nodes)nodes.push_back(*n);
  else for(auto& id:dirty)nodes.push_back(patches.at(id));
  if(!dirty.empty() || base==0)++scene.version;
  Json p={{"full",full},{"base",base},{"version",scene.version},{"nodes",nodes},{"removed",removed}};
  dirty.clear();removed.clear();patches.clear();return p;
}
Json Runtime::handle(const Json& request) {
  auto op=request.at("op").get<std::string>();if(disposed && op!="dispose")throw Error("Plugin disposed");
  if(op=="sync")return packet(UINT64_MAX);
  if(op!="update" && op!="activate" && op!="resize" && op!="appearanceChanged" && op!="deactivate" && op!="dispose")throw Error("Unknown lifecycle operation");
  Json value=request.value("value",Json::object());
  if(op=="update") {
    auto& inputs=metadata["inputs"];
    for(auto name:{"audio","keyboard"})if(std::find(inputs.begin(),inputs.end(),name)==inputs.end())value.erase(name);
  }
  auto started=std::chrono::steady_clock::now();
  if(!disposed)invoke(op.c_str(),value,op=="activate"?100:50);
  lastUpdateMs=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();
  if(op=="dispose")disposed=true;
  return packet(request.value("ack",uint64_t(0)));
}
}
