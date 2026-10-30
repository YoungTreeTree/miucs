#include <windows.h>
#include "miucs_plugins.h"
#include "model.hpp"
#include <chrono>
#include <thread>
#include <iostream>
int main(int argc,char**argv){
  if(argc<4)return 2;CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
  WNDCLASSW cls{};cls.lpfnWndProc=DefWindowProcW;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"MiucsPluginProbe";RegisterClassW(&cls);
  HWND window=CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TRANSPARENT,cls.lpszClassName,L"Miucs plugin probe",WS_POPUP,100,100,800,460,nullptr,nullptr,cls.hInstance,nullptr);
  ShowWindow(window,SW_SHOWNOACTIVATE);void* plugin=nullptr;void* surface=nullptr;int code=0;
  try {
    auto post=[&](const miucs::Json& m){auto b=miucs::encode(m);if(!miucs_plugin_post(plugin,b.data(),b.size()))throw miucs::Error("post failed");};
    auto fixture=miucs::Json::parse(miucs::readFile(argv[3],32*1024*1024));
    for(auto id:{"pixel-keyboard","muffin-puppies","niulai-keyboard","heiji-kazuha"}) {
      auto folder=(std::filesystem::path(argv[2])/id).string();
      plugin=miucs_plugin_open(argv[1],folder.c_str());if(!plugin)throw miucs::Error("Cannot open worker");
      post({{"op","activate"},{"value",{{"id",id},{"width",800},{"height",460},{"scale",1}}}});
      surface=miucs_surface_create(plugin,window,id);if(!surface)throw miucs::Error("Cannot create native surface");int rendered=0;
      for(size_t i=0;i<180;++i){
        post({{"op","update"},{"value",fixture[i%fixture.size()]}});
        MSG message;while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}
        int width=i<90?800:1000,height=i<90?460:575;SetWindowPos(window,nullptr,100,100,width,height,SWP_NOZORDER|SWP_NOACTIVATE);
        std::this_thread::sleep_for(std::chrono::milliseconds(17));int result=miucs_surface_draw(surface,width,height,i<90?1:1.25);
        if(result<0)throw miucs::Error("Native render failed");rendered+=result>0;
      }
      char error[2048]={};miucs_plugin_error(plugin,error,sizeof(error));
      std::cout<<id<<": backend="<<miucs_surface_backend(surface)<<" frames="<<rendered<<" error="<<error<<'\n';
      if(rendered<30||error[0])throw miucs::Error("Insufficient frames or worker failure");
      if(std::getenv("MIUCS_FORCE_CPU")&&miucs_surface_backend(surface)!=0)throw miucs::Error("CPU fallback not selected");
      miucs_surface_destroy(surface);surface=nullptr;miucs_plugin_close(plugin);plugin=nullptr;
    }
  }catch(const std::exception& e){std::cerr<<e.what()<<'\n';code=1;}
  if(surface)miucs_surface_destroy(surface);if(plugin)miucs_plugin_close(plugin);DestroyWindow(window);CoUninitialize();return code;
}
