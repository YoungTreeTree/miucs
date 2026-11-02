#include "renderer.hpp"
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include "include/gpu/ganesh/mtl/SkSurfaceMetal.h"
namespace miucs {
// Skia fills this handle lazily with a __bridge_retained drawable during drawing/flush.
// Keep it alive through presentation and release it even if rendering throws.
struct RetainedDrawable {
  GrMTLHandle handle=nullptr;
  ~RetainedDrawable(){if(handle)CFRelease(handle);}
};
class MacSurface final:public NativeSurface {
  CALayer* layer;
  CALayer* cpuLayer;
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  sk_sp<GrDirectContext> context;
public:
  explicit MacSurface(void* native):layer((__bridge CALayer*)native) {
    if(!std::getenv("MIUCS_FORCE_CPU") && [layer isKindOfClass:[CAMetalLayer class]]) {
      device=MTLCreateSystemDefaultDevice();queue=[device newCommandQueue];
      if(device&&queue){GrMtlBackendContext backend;backend.fDevice.retain((__bridge const void*)device);backend.fQueue.retain((__bridge const void*)queue);context=GrDirectContexts::MakeMetal(backend);
        auto metal=(CAMetalLayer*)layer;metal.device=device;metal.pixelFormat=MTLPixelFormatBGRA8Unorm;metal.framebufferOnly=NO;metal.opaque=NO;metal.maximumDrawableCount=2;
        if(context)context->setResourceCacheLimit(64*1024*1024);
      }
    }
  }
  ~MacSurface() override {
    [CATransaction begin];[CATransaction setDisableActions:YES];
    cpuLayer.contents=nil;[cpuLayer removeFromSuperlayer];
    [CATransaction commit];
  }
  bool gpu()const override{return bool(context);}
  bool draw(Renderer& renderer,const std::string& output,int w,int h,double scale) override {
    @autoreleasepool {
      if(context && context->abandoned())context.reset();
      if(context){auto metal=(CAMetalLayer*)layer;metal.contentsScale=scale;metal.drawableSize=CGSizeMake(w,h);
        RetainedDrawable drawable;auto surface=SkSurfaces::WrapCAMetalLayer(context.get(),(__bridge const void*)metal,kTopLeft_GrSurfaceOrigin,1,kBGRA_8888_SkColorType,nullptr,nullptr,&drawable.handle);
        if(!surface)return false;renderer.paint(surface->getCanvas(),output,w,h);context->flushAndSubmit();
        if(drawable.handle){id<MTLCommandBuffer> command=[queue commandBuffer];[command presentDrawable:(__bridge id<CAMetalDrawable>)drawable.handle];[command commit];}
        return true;
      }
      auto surface=SkSurfaces::Raster(SkImageInfo::MakeN32Premul(w,h));if(!surface)return false;renderer.paint(surface->getCanvas(),output,w,h);
      SkPixmap pixels;if(!surface->peekPixels(&pixels))return false;
      CFDataRef data=CFDataCreate(nullptr,static_cast<const UInt8*>(pixels.addr()),pixels.computeByteSize());auto provider=CGDataProviderCreateWithCFData(data);auto cs=CGColorSpaceCreateDeviceRGB();
      CGImageRef image=CGImageCreate(w,h,8,32,pixels.rowBytes(),cs,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,nullptr,false,kCGRenderingIntentDefault);
      [CATransaction begin];[CATransaction setDisableActions:YES];
      if(!cpuLayer){cpuLayer=[CALayer layer];[layer addSublayer:cpuLayer];}
      cpuLayer.frame=layer.bounds;cpuLayer.contentsScale=scale;cpuLayer.contents=(__bridge id)image;[CATransaction commit];CGImageRelease(image);CGColorSpaceRelease(cs);CGDataProviderRelease(provider);CFRelease(data);return true;
    }
  }
};
std::unique_ptr<NativeSurface> nativeSurface(void* p){return p?std::make_unique<MacSurface>(p):nullptr;}
}
