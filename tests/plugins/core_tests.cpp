#include "runtime.hpp"
#include <iostream>
#include <fstream>
#include <sstream>
using namespace miucs;
static int checks=0;
static void check(bool value,const char* label){++checks;if(!value)throw Error(label);}
template<class F>void rejects(F f,const char* label){bool rejected=false;try{f();}catch(...){rejected=true;}check(rejected,label);}
int main(int argc,char**argv){try{
  auto root=std::filesystem::path(argv[1]);auto m=manifest(root);check(m["api"]==1,"manifest");
  rejects([&]{contained(root,"../builtin/manifest.json");},"traversal");
  rejects([&]{contained(root,"/etc/passwd");},"absolute path");
  Runtime runtime(root);Scene scene;auto full=runtime.packet(0);scene.apply(full);check(!scene.nodes.empty(),"initial scene");
  auto changed=runtime.handle({{"op","activate"},{"value",{{"id","staff-note"}}},{"ack",scene.version}});scene.apply(changed);
  auto idle=runtime.handle({{"op","update"},{"value",{{"now",1},{"deltaTime",.016}}},{"ack",scene.version}});scene.apply(idle);
  auto resync=runtime.handle({{"op","sync"}});check(resync["full"]==true,"resync");
  auto bytes=encode(resync);check(decode(bytes.data(),bytes.size())==resync,"MessagePack roundtrip");
  std::stringstream wire;writePacket(wire,resync);Json read;check(readPacket(wire,read)&&read==resync,"framing");
  Json bad=resync;bad["nodes"][0]["parent"]=bad["nodes"][0]["id"];auto previous=scene.nodes;
  rejects([&]{scene.apply(bad);},"cycle denied");check(previous==scene.nodes,"atomic scene application");
  {
    Scene unchanged;
    Json initial={{"full",true},{"base",0},{"version",1},{"nodes",Json::array({{{"id","root"},{"type","rect"},{"width",100}}})}};
    check(unchanged.apply(initial),"full snapshot applied");
    Json noop={{"full",false},{"base",1},{"version",1},{"nodes",Json::array()},{"removed",Json::array()}};
    auto node=unchanged.nodes.at("root");auto cost=unchanged.bytes;
    check(!unchanged.apply(noop)&&unchanged.nodes.at("root")==node&&unchanged.bytes==cost,"empty delta preserves scene");
    Json invalid=noop;invalid["base"]=0;
    rejects([&]{unchanged.apply(invalid);},"empty delta still validates base");
    invalid=noop;invalid["version"]="invalid";
    rejects([&]{unchanged.apply(invalid);},"empty delta still validates version");
    invalid=noop;invalid["nodes"]=Json::object();
    rejects([&]{unchanged.apply(invalid);},"empty object is not a node array");
    invalid=noop;invalid["removed"]=nullptr;
    rejects([&]{unchanged.apply(invalid);},"null is not a removal array");
    auto patch=noop;patch["nodes"]={{{"id","root"},{"width",200}}};
    check(unchanged.apply(patch)&&unchanged.nodes.at("root")->at("width")==200,"same-version nonempty delta is applied");
    check(unchanged.apply(initial)&&unchanged.nodes.at("root")->at("width")==100,"same-version full resync is applied");
    auto removal=noop;removal["removed"]={"root"};
    check(unchanged.apply(removal)&&unchanged.nodes.empty()&&unchanged.bytes==0,"removal-only delta is applied");
    unchanged.apply(initial);auto emptyFull=noop;emptyFull["full"]=true;
    check(unchanged.apply(emptyFull)&&unchanged.nodes.empty(),"empty full snapshot clears scene");
    auto advance=noop;advance["version"]=2;
    check(unchanged.apply(advance)&&unchanged.version==2,"empty delta can advance version");
  }
  rejects([&]{validateNode({{"id","x"},{"type","path"},{"path",{{"C",1,2}}}});},"path arity");
  const std::set<std::string> builtinIDs={"pencil-flight","staff-note","pixel-keyboard","niulai-keyboard","muffin-puppies","heiji-kazuha"};
  auto list=catalog({root.parent_path()});std::set<std::string> actualIDs;
  for(auto& item:list["plugins"])actualIDs.insert(item.at("id").get<std::string>());
  check(list["errors"].empty()&&actualIDs==builtinIDs,"independent built-in plugins");
  for(auto& item:list["plugins"]) {
    auto id=item["id"].get<std::string>();Runtime single(root.parent_path()/id);
    check(single.scene.nodes.contains(id),"plugin owns its named output");
    check(!single.scene.nodes.contains("tray")&&!single.scene.nodes.contains("tray-head"),"application tray is not a plugin output");
    for(const auto& other:builtinIDs)
      if(id!=other)check(!single.scene.nodes.contains(other),"plugin creates only its own UI");
  }
  auto tmp=std::filesystem::temp_directory_path()/std::filesystem::path("miucs-plugin-tests-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));std::filesystem::create_directory(tmp);
  std::ofstream(tmp/"manifest.json")<<m.dump();
  auto invalid=m;invalid["tray"]="tray";std::ofstream(tmp/"main.lua")<<"return {}";
  std::ofstream(tmp/"manifest.json")<<invalid.dump();rejects([&]{manifest(tmp);},"plugins cannot own the app tray");
  invalid=m;invalid["visualizations"]=Json::array();std::ofstream(tmp/"manifest.json")<<invalid.dump();
  rejects([&]{manifest(tmp);},"multiple-output manifest rejected with migration error");
  std::ofstream(tmp/"manifest.json")<<m.dump();
  auto source=[&](const std::string& text){std::ofstream(tmp/"main.lua")<<text;};
  source("assert(io == nil and os == nil and debug == nil and package == nil and load == nil); return {}");{Runtime safe(tmp);++checks;}
  source("return {create=function() while true do end end}");rejects([&]{Runtime loop(tmp);},"infinite loop interrupted");
  source("return {create=function() local s=string.rep('x',40*1024*1024) end}");rejects([&]{Runtime oom(tmp);},"memory limit");
  source("return {create=function() miucs.require('../outside.lua') end}");rejects([&]{Runtime escape(tmp);},"module escape");
  source(std::string("\x1bLua",4));rejects([&]{Runtime bytecode(tmp);},"bytecode rejected");
  source("return {create=function() miucs.load{type='path',id='root',path={{'M',0,0},{'L',1,1}}} end,update=function() miucs.set('root',{x=8,path={}}) end}");
  {Runtime paths(tmp);Scene out;out.apply(paths.packet(0));out.apply(paths.handle({{"op","update"},{"ack",out.version}}));check(out.nodes.at("root")->at("path").is_array()&&out.nodes.at("root")->at("path").empty(),"empty path delta clears geometry");paths.handle({{"op","dispose"}});paths.handle({{"op","dispose"}});++checks;}
  source("return {create=function() miucs.load{type='rect',id='root',x=miucs.random()} end}");
  {Runtime a(tmp,42),b(tmp,42),c(tmp,43);check(*a.scene.nodes.at("root")==*b.scene.nodes.at("root"),"fixed seed replay");check(*a.scene.nodes.at("root")!=*c.scene.nodes.at("root"),"different seed");}
  source("return {create=function() for i=1,4097 do miucs.load{type='rect',id='n'..i} end end}");rejects([&]{Runtime count(tmp);},"node count budget");
  Scene bounded;Json huge={{"full",true},{"base",0},{"version",1},{"nodes",Json::array()}};
  for(int i=0;i<300;++i)huge["nodes"].push_back({{"id","n"+std::to_string(i)},{"type","text"},{"text",std::string(65536,'x')}});
  rejects([&]{bounded.apply(huge);},"aggregate retained scene budget");check(bounded.nodes.empty(),"over-budget scene is atomic");
  std::filesystem::remove_all(tmp);
  std::cout<<checks<<" plugin core checks passed\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
