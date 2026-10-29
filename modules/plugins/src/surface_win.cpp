#include "renderer.hpp"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <dcomp.h>
#include <wrl/client.h>
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/d3d/GrD3DBackendContext.h"
#include "include/gpu/ganesh/d3d/GrD3DDirectContext.h"
#include "include/gpu/ganesh/d3d/GrD3DBackendSurface.h"
namespace miucs {
using Microsoft::WRL::ComPtr;
static void hr(HRESULT h){if(FAILED(h))throw Error("DirectComposition/D3D12 initialization or presentation failed");}
class WinSurface final:public NativeSurface {
  HWND window;
  ComPtr<IDXGIFactory4> factory;ComPtr<ID3D12Device> device;ComPtr<ID3D12CommandQueue> queue;
  ComPtr<IDXGISwapChain3> swap;ComPtr<IDCompositionDevice> composition;ComPtr<IDCompositionTarget> target;ComPtr<IDCompositionVisual> visual;
  ComPtr<ID3D12Fence> fence;uint64_t serial=0, completed[2]={};
  ComPtr<ID3D12CommandAllocator> allocators[2];ComPtr<ID3D12GraphicsCommandList> lists[2];
  sk_sp<GrDirectContext> context;GrBackendRenderTarget backends[2];sk_sp<SkSurface> surfaces[2];
  int width=0,height=0;
  void initialize(){
    hr(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));ComPtr<IDXGIAdapter1> adapter;
    for(UINT i=0;factory->EnumAdapters1(i,&adapter)!=DXGI_ERROR_NOT_FOUND;++i){if(SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))break;adapter.Reset();}
    if(!device)throw Error("No D3D12 device");D3D12_COMMAND_QUEUE_DESC desc{};hr(device->CreateCommandQueue(&desc,IID_PPV_ARGS(&queue)));
    GrD3DBackendContext backend;backend.fAdapter.reset(adapter.Get());adapter->AddRef();backend.fDevice.reset(device.Get());device->AddRef();backend.fQueue.reset(queue.Get());queue->AddRef();
    context=GrDirectContexts::MakeD3D(backend);if(!context)throw Error("Skia D3D12 unavailable");context->setResourceCacheLimit(64*1024*1024);
    hr(DCompositionCreateDevice(nullptr,IID_PPV_ARGS(&composition)));hr(composition->CreateTargetForHwnd(window,TRUE,&target));hr(composition->CreateVisual(&visual));hr(target->SetRoot(visual.Get()));
    hr(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));
    for(int i=0;i<2;++i){hr(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocators[i])));hr(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocators[i].Get(),nullptr,IID_PPV_ARGS(&lists[i])));hr(lists[i]->Close());}
  }
  void resize(int w,int h){
    context->flushAndSubmit(GrSyncCpu::kYes);for(auto& s:surfaces)s.reset();for(auto& b:backends)b=GrBackendRenderTarget();
    if(swap)hr(swap->ResizeBuffers(2,w,h,DXGI_FORMAT_B8G8R8A8_UNORM,0));
    else {DXGI_SWAP_CHAIN_DESC1 d{};d.Width=w;d.Height=h;d.Format=DXGI_FORMAT_B8G8R8A8_UNORM;d.SampleDesc.Count=1;d.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;d.BufferCount=2;d.SwapEffect=DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;d.AlphaMode=DXGI_ALPHA_MODE_PREMULTIPLIED;
      ComPtr<IDXGISwapChain1> initial;hr(factory->CreateSwapChainForComposition(queue.Get(),&d,nullptr,&initial));hr(initial.As(&swap));hr(visual->SetContent(swap.Get()));hr(composition->Commit());}
    for(int i=0;i<2;++i){GrD3DTextureResourceInfo info;hr(swap->GetBuffer(i,IID_PPV_ARGS(&info.fResource)));info.fFormat=DXGI_FORMAT_B8G8R8A8_UNORM;info.fResourceState=D3D12_RESOURCE_STATE_PRESENT;
      backends[i]=GrBackendRenderTargets::MakeD3D(w,h,info);surfaces[i]=SkSurfaces::WrapBackendRenderTarget(context.get(),backends[i],kTopLeft_GrSurfaceOrigin,kBGRA_8888_SkColorType,nullptr,nullptr);if(!surfaces[i])throw Error("Cannot wrap composition buffer");}
    width=w;height=h;
  }
  bool cpu(Renderer& r,const std::string& output,int w,int h){
    auto surface=SkSurfaces::Raster(SkImageInfo::Make(w,h,kBGRA_8888_SkColorType,kPremul_SkAlphaType));if(!surface)return false;r.paint(surface->getCanvas(),output,w,h);SkPixmap pixels;if(!surface->peekPixels(&pixels))return false;
    SetWindowLongPtrW(window,GWL_EXSTYLE,(GetWindowLongPtrW(window,GWL_EXSTYLE)&~WS_EX_NOREDIRECTIONBITMAP)|WS_EX_LAYERED);
    HDC screen=GetDC(nullptr),dc=CreateCompatibleDC(screen);BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=w;info.bmiHeader.biHeight=-h;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;
    void* bits=nullptr;HBITMAP bitmap=CreateDIBSection(dc,&info,DIB_RGB_COLORS,&bits,nullptr,0);if(!bitmap){DeleteDC(dc);ReleaseDC(nullptr,screen);return false;}
    for(int y=0;y<h;++y)std::memcpy(static_cast<uint8_t*>(bits)+size_t(y)*w*4,pixels.addr(0,y),w*4);
    auto old=SelectObject(dc,bitmap);RECT rect;GetWindowRect(window,&rect);POINT at{rect.left,rect.top},zero{};SIZE size{w,h};BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};BOOL ok=UpdateLayeredWindow(window,screen,&at,&size,dc,&zero,0,&blend,ULW_ALPHA);
    SelectObject(dc,old);DeleteObject(bitmap);DeleteDC(dc);ReleaseDC(nullptr,screen);return ok;
  }
public:
  explicit WinSurface(void* h):window(static_cast<HWND>(h)){try{if(!std::getenv("MIUCS_FORCE_CPU"))initialize();}catch(...){context.reset();}}
  ~WinSurface(){if(context)context->flushAndSubmit(GrSyncCpu::kYes);}
  bool gpu()const override{return bool(context);}
  bool draw(Renderer& r,const std::string& output,int w,int h,double)override{
    if(!context)return cpu(r,output,w,h);
    try {
      if(w!=width||h!=height)resize(w,h);UINT i=swap->GetCurrentBackBufferIndex();if(fence->GetCompletedValue()<completed[i])return false;
      r.paint(surfaces[i]->getCanvas(),output,w,h);context->flushAndSubmit();
      auto info=GrBackendRenderTargets::GetD3DTextureResourceInfo(backends[i]);hr(allocators[i]->Reset());hr(lists[i]->Reset(allocators[i].Get(),nullptr));
      if(info.fResourceState!=D3D12_RESOURCE_STATE_PRESENT){D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition.pResource=info.fResource.get();b.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;b.Transition.StateBefore=info.fResourceState;b.Transition.StateAfter=D3D12_RESOURCE_STATE_PRESENT;lists[i]->ResourceBarrier(1,&b);}
      hr(lists[i]->Close());ID3D12CommandList* list=lists[i].Get();queue->ExecuteCommandLists(1,&list);GrBackendRenderTargets::SetD3DResourceState(&backends[i],D3D12_RESOURCE_STATE_PRESENT);
      hr(swap->Present(0,0));completed[i]=++serial;hr(queue->Signal(fence.Get(),serial));return true;
    }catch(...){context->abandonContext();context.reset();for(auto& s:surfaces)s.reset();if(visual){visual->SetContent(nullptr);composition->Commit();}return cpu(r,output,w,h);}
  }
};
std::unique_ptr<NativeSurface> nativeSurface(void* p){return p?std::make_unique<WinSurface>(p):nullptr;}
}
