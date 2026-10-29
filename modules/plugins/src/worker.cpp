#include "runtime.hpp"
#include <iostream>
#include <cstdlib>
#include <thread>
#ifndef _WIN32
#include <unistd.h>
#endif
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#endif
int run(int argc,char** argv) {
#ifdef _WIN32
  _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
#endif
  try {
    if(argc<2)throw miucs::Error("Usage: miucs-plugin-worker PLUGIN_DIRECTORY [--validate]");
    bool validate=false;uint64_t seed=1,parent=0;
    for(int i=2;i<argc;++i){std::string option=argv[i];if(option=="--validate")validate=true;else if(option=="--seed" && i+1<argc)seed=std::stoull(argv[++i]);else if(option=="--parent-pid" && i+1<argc)parent=std::stoull(argv[++i]);else throw miucs::Error("Unknown worker option");}
    if(parent) {
#ifdef _WIN32
      HANDLE host=OpenProcess(SYNCHRONIZE,FALSE,DWORD(parent));
      if(!host)throw miucs::Error("Plugin host is unavailable");
      std::thread([host]{WaitForSingleObject(host,INFINITE);CloseHandle(host);std::_Exit(1);}).detach();
#else
      if(uint64_t(getppid())!=parent)throw miucs::Error("Plugin host is unavailable");
      std::thread([parent]{while(uint64_t(getppid())==parent)std::this_thread::sleep_for(std::chrono::milliseconds(100));std::_Exit(1);}).detach();
#endif
    }
    miucs::Runtime runtime(std::filesystem::u8path(argv[1]),seed);
    if(validate) {
      std::cout<<"Plugin valid: "<<runtime.scene.nodes.size()<<" nodes, "<<runtime.memory()<<" Lua bytes\n";return 0;
    }
    miucs::writePacket(std::cout,{{"ok",true},{"scene",runtime.packet(UINT64_MAX)}});
    miucs::Json request;
    while(miucs::readPacket(std::cin,request)) {
      auto response=runtime.handle(request);
      miucs::writePacket(std::cout,{{"ok",true},{"scene",response},{"updateMs",runtime.lastUpdateMs},{"luaBytes",runtime.memory()}});
      if(request.value("op","")=="dispose")break;
    }
    return 0;
  }catch(const std::exception& e){
    try{miucs::writePacket(std::cout,{{"ok",false},{"error",e.what()}});}catch(...){}
    std::cerr<<e.what()<<'\n';return 1;
  }
}

#ifdef _WIN32
int wmain(int argc,wchar_t** argv) {
  std::vector<std::string> strings;std::vector<char*> pointers;
  for(int i=0;i<argc;++i){int n=WideCharToMultiByte(CP_UTF8,0,argv[i],-1,nullptr,0,nullptr,nullptr);std::string value(n,'\0');WideCharToMultiByte(CP_UTF8,0,argv[i],-1,value.data(),n,nullptr,nullptr);strings.push_back(std::move(value));}
  for(auto& value:strings)pointers.push_back(value.data());return run(argc,pointers.data());
}
#else
int main(int argc,char** argv){return run(argc,argv);}
#endif
