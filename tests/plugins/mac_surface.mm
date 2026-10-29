#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include "miucs_plugins.h"
#include "model.hpp"
#include <iostream>
#include <thread>
int main(int argc,char**argv){@autoreleasepool {
  if(argc<3)return 2;
  [NSApplication sharedApplication];
  NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,500,320) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  window.opaque=NO;window.backgroundColor=NSColor.clearColor;window.ignoresMouseEvents=YES;
  window.contentView.wantsLayer=YES;auto layer=[CAMetalLayer layer];layer.opaque=NO;window.contentView.layer=layer;
  [window orderFrontRegardless];
  void* plugin=miucs_plugin_open(argv[1],argv[2]);
  auto post=[&](const miucs::Json& message){auto b=miucs::encode(message);if(!miucs_plugin_post(plugin,b.data(),b.size()))throw std::runtime_error("post failed");};
  auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
  while(!miucs_plugin_ready(plugin)&&std::chrono::steady_clock::now()<deadline)std::this_thread::sleep_for(std::chrono::milliseconds(2));
  post({{"op","activate"},{"value",{{"id","pixel-keyboard"},{"width",500},{"height",320},{"scale",1}}}});
  void* surface=miucs_surface_create(plugin,(__bridge void*)layer,"pixel-keyboard");
  auto fixtures=argc>3?miucs::Json::parse(miucs::readFile(argv[3],16*1024*1024)):miucs::Json::array();
  if(!fixtures.empty()){miucs_surface_destroy(surface);post({{"op","activate"},{"value",{{"id","staff-note"}}}});surface=miucs_surface_create(plugin,(__bridge void*)layer,"staff-note");}
  int rendered=0;std::vector<double> timings;
  for(int i=0;i<180;++i){
    post({{"op","update"},{"value",fixtures.empty()?miucs::Json{{"now",i/60.0},{"deltaTime",1.0/60}}:fixtures[i%fixtures.size()]}});
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0/60]];
    auto start=std::chrono::steady_clock::now();int result=miucs_surface_draw(surface,1000,640,2);
    if(result<0)break;if(result>0){++rendered;if(i>30)timings.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());}
  }
  char error[4096]={};miucs_plugin_error(plugin,error,sizeof(error));
  std::sort(timings.begin(),timings.end());
  std::cout<<"backend="<<miucs_surface_backend(surface)<<" rendered="<<rendered<<" submitP95Ms="<<(timings.empty()?0:timings[timings.size()*95/100])<<" error="<<error<<"\n";
  miucs_surface_destroy(surface);miucs_plugin_close(plugin);[window orderOut:nil];
  return rendered>0&&error[0]==0?0:1;
}}
