#include "model.hpp"
#include <atomic>
#include <cstdlib>
#include <cstdio>
#include <thread>

// Closing a client is asynchronous. Its reader may still validate a packet
// during process teardown, after function-local static destructors have run.
static std::atomic<bool> exiting{false};
static std::thread* reader=nullptr;

int main() {
  // Registered BEFORE the first validation, so this runs AFTER any destructors
  // registered by validateNode. No sleeps or scheduling luck are required.
  if(std::atexit([] {
    exiting.store(true);
    reader->join();
    delete reader;
  })!=0)return 1;
  miucs::validateNode({{"id","warmup"},{"type","group"}});
  reader=new std::thread([] {
    while(!exiting.load())std::this_thread::yield();
    try {
      for(auto type:{"group","path","image","text","rect","ellipse"})
        miucs::validateNode({{"id","late-packet"},{"type",type}});
      bool rejected=false;
      try{miucs::validateNode({{"id","bad"},{"type","unsupported"}});}
      catch(const miucs::Error&){rejected=true;}
      if(!rejected)std::_Exit(1);
      std::fputs("PASS scene validation during process teardown\n",stderr);
    }catch(const std::exception& e){std::fprintf(stderr,"Exit validation: %s\n",e.what());std::_Exit(1);}
  });
  return 0;
}
