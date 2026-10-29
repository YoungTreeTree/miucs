#include "model.hpp"
#include <fstream>
#include <set>
#include <cmath>
#include <regex>
namespace miucs {
std::filesystem::path contained(const std::filesystem::path& root, const std::string& relative) {
  auto rel=std::filesystem::u8path(relative);
  if(relative.empty() || relative.find('\0')!=std::string::npos || rel.is_absolute() || rel.has_root_name()) throw Error("Invalid relative path");
  for(const auto& part:rel) if(part=="..") throw Error("Parent traversal denied");
  auto base=std::filesystem::canonical(root), path=std::filesystem::canonical(base/rel);
  auto a=base.begin(), b=path.begin();
  for(;a!=base.end();++a,++b) if(b==path.end() || *a!=*b) throw Error("Resource escapes plugin directory");
  if(!std::filesystem::is_regular_file(path)) throw Error("Expected regular file");
  return path;
}
std::string readFile(const std::filesystem::path& path, size_t limit) {
  if(std::filesystem::file_size(path)>limit) throw Error("File size limit exceeded");
  std::ifstream stream(path,std::ios::binary);
  if(!stream) throw Error("Cannot open file");
  std::string value((std::istreambuf_iterator<char>(stream)),{});
  if(value.size()>limit) throw Error("File grew beyond size limit");
  return value;
}
static bool identifier(const std::string& id) {
  return !id.empty() && id.size()<=128 && std::all_of(id.begin(),id.end(),[](unsigned char c){return std::isalnum(c)||c=='.'||c=='-'||c=='_';});
}
static void finite(const Json& j, int depth=0) {
  if(depth>24) throw Error("Value nesting limit exceeded");
  if(j.is_number_float() && !std::isfinite(j.get<double>())) throw Error("Non-finite number");
  if(j.is_string() && j.get_ref<const std::string&>().size()>65536) throw Error("String too long");
  if(j.is_structured()) for(auto& v:j) finite(v,depth+1);
}
Json manifest(const std::filesystem::path& root) {
  auto m=Json::parse(readResource(std::filesystem::canonical(root),"manifest.json",65536));
  if(m.at("api").get<int>()!=1 || !identifier(m.at("id").get<std::string>())) throw Error("Unsupported API or invalid plugin id");
  if(!m.at("name").is_string() || !m.at("version").is_string()) throw Error("Invalid plugin metadata");
  auto entry=m.at("entry").get<std::string>();
  if(std::filesystem::path(entry).extension()!=".lua") throw Error("Entry must be Lua source");
  contained(root,entry);
  if(m.contains("visualizations") || m.contains("tray")) throw Error("One UI per plugin: use top-level layout; tray belongs to the application");
  auto& l=m.at("layout");
  double w=l.at("width"), h=l.at("height"), lo=l.at("minimumWidth"), hi=l.at("maximumWidth");
  if(!(lo>0 && lo<=w && w<=hi && hi<=4096 && h>0 && h<=4096)) throw Error("Invalid layout");
  if(!m.at("inputs").is_array() || m["inputs"].size()>2)throw Error("Invalid input capability list");
  for(auto& capability:m.at("inputs")) if(capability!="audio" && capability!="keyboard") throw Error("Unknown input capability");
  finite(m); return m;
}
Json catalog(const std::vector<std::filesystem::path>& roots) {
  Json result={{"plugins",Json::array()},{"errors",Json::array()}};
  std::set<std::string> ids;
  for(auto& root:roots) {
    if(!std::filesystem::exists(root)) continue;
    std::vector<std::filesystem::path> folders;
    try {for(auto& f:std::filesystem::directory_iterator(root)) if(f.is_directory()) folders.push_back(f.path());}
    catch(const std::exception& e){result["errors"].push_back({{"directory",root.string()},{"message",e.what()}});continue;}
    std::sort(folders.begin(),folders.end());
    for(auto& f:folders) try {
      auto m=manifest(f); auto id=m["id"].get<std::string>();
      if(ids.contains(id)) throw Error("Duplicate plugin id: "+id);
      ids.insert(id);
      auto path=std::filesystem::canonical(f).u8string();m["directory"]=std::string(path.begin(),path.end()); result["plugins"].push_back(m);
    } catch(const std::exception& e) {result["errors"].push_back({{"directory",f.string()},{"message",e.what()}});}
  } return result;
}
void validateNode(const Json& n) {
  if(!n.is_object() || !identifier(n.at("id").get<std::string>())) throw Error("Invalid node id");
  static const std::set<std::string> types={"group","path","image","text","rect","ellipse"};
  if(!types.contains(n.at("type").get<std::string>())) throw Error("Unsupported node type");
  validateProperties(n);
}
void validateProperties(const Json& n) {
  finite(n);
  if(n.contains("path")) {
    if(!n["path"].is_array() || n["path"].size()>MaxPath) throw Error("Path limit exceeded");
    for(auto& p:n["path"]) {
      if(!p.is_array() || p.empty() || !p[0].is_string()) throw Error("Invalid path command");
      std::string op=p[0]; size_t count=op=="M"||op=="L"?3:op=="Q"?5:op=="C"?7:op=="Z"?1:0;
      if(count==0 || p.size()!=count) throw Error("Invalid path command arity");
      for(size_t i=1;i<p.size();++i) if(!p[i].is_number() || std::abs(p[i].get<double>())>1e6) throw Error("Invalid path coordinate");
    }
  }
  for(auto key:{"x","y","width","height","rotation","scaleX","scaleY","opacity","strokeWidth","fontSize","z"})
    if(n.contains(key) && (!n[key].is_number() || std::abs(n[key].get<double>())>1e6)) throw Error("Invalid numeric node property");
  if(n.contains("pathRef") && (!n["pathRef"].is_string() || !identifier(n["pathRef"].get<std::string>())))throw Error("Invalid path reference");
  if(n.contains("children")) throw Error("Use parent handles, not nested mutations");
}
Json patchedNode(const Json& current,const Json& changes) {
  Json result=Json::object();
  for(auto& [key,value]:current.items())if(!changes.contains(key))result[key]=value;
  result.update(changes);return result;
}
size_t valueCost(const Json& value) {
  size_t cost=32;
  if(value.is_string())cost+=value.get_ref<const std::string&>().size();
  else if(value.is_object())for(auto& [key,item]:value.items())cost+=64+key.size()+valueCost(item);
  else if(value.is_array())for(auto& item:value)cost+=valueCost(item);
  return cost;
}
size_t patchedCost(size_t before,const Json& current,const Json& changes) {
  for(auto& [key,value]:changes.items()) {
    before+=valueCost(value);
    if(current.contains(key))before-=valueCost(current[key]);else before+=64+key.size();
  }
  return before;
}
void Scene::put(const std::string& id,Json node,size_t cost) {
  size_t old=costs.contains(id)?costs.at(id):0;
  if(cost>MaxSceneBytes || bytes-old>MaxSceneBytes-cost)throw Error("Scene memory budget exceeded");
  nodes[id]=std::make_shared<const Json>(std::move(node));costs[id]=cost;bytes=bytes-old+cost;
}
void Scene::apply(const Json& p) {
  if(p.at("base").get<uint64_t>()!=version && !p.value("full",false)) throw Error("Scene revision mismatch");
  Scene candidate=p.value("full",false)?Scene{}:*this;
  for(auto& id:p.value("removed",Json::array())) {auto key=id.get<std::string>();candidate.bytes-=candidate.costs[key];candidate.costs.erase(key);candidate.nodes.erase(key);}
  for(auto& n:p.at("nodes")) {
    std::string id=n.at("id");Json value=n;size_t cost;
    if(!p.value("full",false) && candidate.nodes.contains(id)){
      validateProperties(n);
      if(n.contains("type") && n["type"]!=candidate.nodes.at(id)->at("type"))throw Error("Node type mutation denied");
      if(n.contains("parent") && n["parent"]!=candidate.nodes.at(id)->value("parent",std::string{}))throw Error("Node parent mutation denied");
      cost=patchedCost(candidate.costs.at(id),*candidate.nodes.at(id),n);
      value=patchedNode(*candidate.nodes.at(id),n);
    } else {validateNode(value);cost=valueCost(value);}
    candidate.put(id,std::move(value),cost);
  }
  if(candidate.nodes.size()>MaxNodes) throw Error("Node limit exceeded");
  for(auto& [id,n]:candidate.nodes) {
    if(n->contains("pathRef")){
      std::string ref=n->at("pathRef");
      if(!candidate.nodes.contains(ref)||candidate.nodes.at(ref)->value("type","")!="path"||candidate.nodes.at(ref)->contains("pathRef"))throw Error("Path reference must name a concrete path node");
    }
    auto parent=n->value("parent",std::string{}); int depth=0;
    while(!parent.empty()) {
      if(parent==id || ++depth>24 || !candidate.nodes.contains(parent)) throw Error("Invalid scene hierarchy");
      parent=candidate.nodes.at(parent)->value("parent",std::string{});
    }
  }
  candidate.version=p.at("version");*this=std::move(candidate);
}
std::vector<uint8_t> encode(const Json& j) {auto b=Json::to_msgpack(j);if(b.size()>MaxPacket)throw Error("Packet too large");return b;}
namespace {
// Validate MessagePack lengths/depth before nlohmann constructs recursively nested values.
struct PacketCheck {
  const uint8_t* data; size_t size, pos=0;
  uint64_t read(size_t n) { if(n>size-pos)throw Error("Truncated MessagePack");uint64_t v=0;while(n--)v=(v<<8)|data[pos++];return v; }
  void skip(uint64_t n) { if(n>size-pos)throw Error("Truncated MessagePack");pos+=size_t(n); }
  void value(unsigned depth=0) {
    if(depth>24)throw Error("MessagePack nesting limit");auto t=read(1);uint64_t count=0;
    if(t<=0x7f||t>=0xe0||t==0xc0||t==0xc2||t==0xc3)return;
    if((t&0xe0)==0xa0){skip(t&31);return;}
    if((t&0xf0)==0x90)count=t&15;
    else if((t&0xf0)==0x80)count=(t&15)*2;
    else switch(t) {
      case 0xcc:case 0xd0:skip(1);return;
      case 0xcd:case 0xd1:skip(2);return;
      case 0xce:case 0xd2:case 0xca:skip(4);return;
      case 0xcf:case 0xd3:case 0xcb:skip(8);return;
      case 0xd9:skip(read(1));return;case 0xda:skip(read(2));return;case 0xdb:skip(read(4));return;
      case 0xdc:count=read(2);break;case 0xdd:count=read(4);break;
      case 0xde:count=read(2)*2;break;case 0xdf:count=read(4)*2;break;
      default:throw Error("Unsupported MessagePack type");
    }
    if(count>32768||count>size-pos)throw Error("MessagePack container limit");while(count--)value(depth+1);
  }
};
}
Json decode(const uint8_t* data,size_t size) {
  if(!data||size==0||size>MaxPacket)throw Error("Packet size invalid");
  PacketCheck check{data,size};check.value();if(check.pos!=size)throw Error("Trailing MessagePack data");
  auto j=Json::from_msgpack(data,data+size,true,true);finite(j);return j;
}

bool readPacket(std::istream& in,Json& out) {
  uint8_t header[4];in.read(reinterpret_cast<char*>(header),4);
  if(in.gcount()==0)return false;if(in.gcount()!=4)throw Error("Truncated packet header");
  uint32_t n=header[0]|uint32_t(header[1])<<8|uint32_t(header[2])<<16|uint32_t(header[3])<<24;
  if(n>MaxPacket)throw Error("Packet too large");std::vector<uint8_t> data(n);
  in.read(reinterpret_cast<char*>(data.data()),n);if(size_t(in.gcount())!=n)throw Error("Truncated packet");out=decode(data.data(),n);return true;
}
void writePacket(std::ostream& out,const Json& j) {
  auto data=encode(j);uint32_t n=uint32_t(data.size());uint8_t h[]={uint8_t(n),uint8_t(n>>8),uint8_t(n>>16),uint8_t(n>>24)};
  out.write(reinterpret_cast<char*>(h),4);out.write(reinterpret_cast<char*>(data.data()),data.size());out.flush();
}
}
