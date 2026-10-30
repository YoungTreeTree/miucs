#include "runtime.hpp"
#include <iostream>
#include <algorithm>
int main(int argc,char**argv){try{
  if(argc<3)return 2;
  auto frames=miucs::Json::parse(miucs::readFile(argv[2],32*1024*1024));
  miucs::Json reports=miucs::Json::array();
  for(auto id:{"pixel-keyboard","muffin-puppies","niulai-keyboard","heiji-kazuha","zelda-guardian","yuru-camp"}) {
    miucs::Runtime runtime(std::filesystem::path(argv[1])/id);miucs::Scene host;host.apply(runtime.packet(0));
    host.apply(runtime.handle({{"op","activate"},{"value",{{"id",id}}},{"ack",host.version}}));
    std::vector<double> update,apply;size_t bytes=0,memory=0;
    for(size_t i=0;i<frames.size();++i){
      auto p=runtime.handle({{"op","update"},{"value",frames[i]},{"ack",host.version}});
      auto wire=miucs::encode(p);auto start=std::chrono::steady_clock::now();
      host.apply(miucs::decode(wire.data(),wire.size()));
      if(i>=60){update.push_back(runtime.lastUpdateMs);apply.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());}
      bytes+=wire.size();memory=std::max(memory,runtime.memory());
    }
    auto percentile=[](std::vector<double>& values){std::sort(values.begin(),values.end());return values.at(values.size()*95/100);};
    reports.push_back({{"output",id},{"frames",frames.size()},{"scriptP95Ms",percentile(update)},{"decodeApplyP95Ms",percentile(apply)},{"meanPacketBytes",bytes/frames.size()},{"peakLuaBytes",memory}});
  }
  std::cout<<reports.dump(2)<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
