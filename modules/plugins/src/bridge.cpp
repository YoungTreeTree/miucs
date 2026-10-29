#include "miucs_plugins.h"
#include "renderer.hpp"
#include <cstring>
namespace {
thread_local std::string openError;
struct Surface {
  miucs::Client* client;
  miucs::Renderer renderer;
  std::string output;
  std::unique_ptr<miucs::NativeSurface> native;
  uint64_t drawn=UINT64_MAX,pixelStamp=UINT64_MAX;uint32_t width=0,height=0,pixelWidth=0,pixelHeight=0;
  std::vector<uint8_t> pixelCache;
  Surface(miucs::Client* c,void* handle,const char* id):client(c),renderer(c->directory),output(id),native(miucs::nativeSurface(handle)){}
};
size_t copy(const std::string& s,char* into,size_t cap){if(into&&cap){size_t n=std::min(s.size(),cap-1);std::memcpy(into,s.data(),n);into[n]=0;}return s.size()+1;}
bool dimensions(uint32_t w,uint32_t h){return w>0&&h>0&&w<=8192&&h<=8192&&uint64_t(w)*h<=16*1024*1024;}
}
extern "C" {
uint32_t miucs_plugin_api_version(){return 1;}
void* miucs_plugin_open(const char* worker,const char* directory){try{openError.clear();return new miucs::Client(worker,directory);}catch(const std::exception& e){openError=e.what();return nullptr;}}
int miucs_plugin_post(void* h,const uint8_t* data,size_t n){try{if(!h)return 0;static_cast<miucs::Client*>(h)->post(miucs::decode(data,n));return 1;}catch(const std::exception& e){openError=e.what();return 0;}}
int miucs_plugin_ready(void* h){return h&&static_cast<miucs::Client*>(h)->isReady();}
uint64_t miucs_plugin_completed(void* h){return h?static_cast<miucs::Client*>(h)->completedCount():0;}
size_t miucs_plugin_error(void* h,char* out,size_t cap){return copy(h?static_cast<miucs::Client*>(h)->error():openError,out,cap);}
void miucs_plugin_close(void* h){if(!h)return;auto* client=static_cast<miucs::Client*>(h);try{std::thread([client]{client->shutdown();delete client;}).detach();}catch(...){delete client;}}
void* miucs_surface_create(void* h,void* native,const char* output){try{if(!h)return nullptr;return new Surface(static_cast<miucs::Client*>(h),native,output);}catch(const std::exception& e){openError=e.what();return nullptr;}}
int miucs_surface_draw(void* h,uint32_t w,uint32_t height,double scale){try{if(!h||!dimensions(w,height)||!std::isfinite(scale)||scale<=0)return -1;auto& s=*static_cast<Surface*>(h);s.client->snapshot(s.renderer.scene);if(s.renderer.scene.version==0)return 0;if(!s.native)return -1;
  auto stamp=s.renderer.stamp(s.output);
  if(s.drawn==stamp&&s.width==w&&s.height==height)return 0;
  if(!s.native->draw(s.renderer,s.output,w,height,scale))return 0;s.drawn=stamp;s.width=w;s.height=height;return 1;
}catch(const std::exception& e){openError=e.what();if(h)static_cast<Surface*>(h)->client->rejectRender(e.what());return -1;}}
int miucs_surface_pixels(void* h,uint32_t w,uint32_t height,uint8_t* dest,size_t n){try{if(!h||!dest||!dimensions(w,height)||n<uint64_t(w)*height*4)return 0;auto& s=*static_cast<Surface*>(h);s.client->snapshot(s.renderer.scene);if(s.renderer.scene.version==0)return 0;
  auto stamp=s.renderer.stamp(s.output);size_t size=size_t(w)*height*4;
  if(s.pixelStamp!=stamp || s.pixelWidth!=w || s.pixelHeight!=height){
    s.pixelCache.resize(size);auto info=SkImageInfo::Make(w,height,kBGRA_8888_SkColorType,kPremul_SkAlphaType);auto surface=SkSurfaces::WrapPixels(info,s.pixelCache.data(),w*4);if(!surface)return 0;
    s.renderer.paint(surface->getCanvas(),s.output,w,height);s.pixelStamp=stamp;s.pixelWidth=w;s.pixelHeight=height;
  }
  std::memcpy(dest,s.pixelCache.data(),size);return 1;
}catch(const std::exception& e){openError=e.what();if(h)static_cast<Surface*>(h)->client->rejectRender(e.what());return 0;}}
int miucs_surface_backend(void* h){auto* s=static_cast<Surface*>(h);return s&&s->native&&s->native->gpu()?1:0;}
void miucs_surface_destroy(void* h){delete static_cast<Surface*>(h);}
size_t miucs_plugin_catalog(const char* builtin,const char* user,char* out,size_t cap){try{return copy(miucs::catalog({std::filesystem::u8path(builtin),std::filesystem::u8path(user)}).dump(),out,cap);}catch(const std::exception& e){return copy(miucs::Json({{"plugins",miucs::Json::array()},{"errors",{{{"message",e.what()}}}}}).dump(),out,cap);}}
}
