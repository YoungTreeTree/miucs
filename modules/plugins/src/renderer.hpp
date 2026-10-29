#pragma once
#include "client.hpp"
#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkSurface.h"
#include "include/core/SkImage.h"
#include "include/core/SkFont.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
namespace miucs {
class Renderer {
  std::filesystem::path root;
  std::map<std::string,sk_sp<SkImage>> images;
  std::map<std::string,sk_sp<SkTypeface>> fonts;
  struct CachedPath {Json source;SkPath path;SkPathBuilder builder;};
  std::map<std::string,CachedPath> paths;
  std::map<std::string,std::vector<std::string>> children;
  size_t assetBytes=0;
  uint64_t treeVersion=UINT64_MAX;
  void syncTree();
  uint64_t stampNode(const std::string&);
  void drawNode(SkCanvas*,const std::string&,int);
  sk_sp<SkImage> image(const std::string&);
  sk_sp<SkTypeface> font(const std::string&);
public:
  Scene scene;
  explicit Renderer(const std::filesystem::path& p):root(p){}
  uint64_t stamp(const std::string& output);
  void paint(SkCanvas*,const std::string& output,int width,int height);
};
class NativeSurface {
public:
  virtual ~NativeSurface()=default;
  virtual bool draw(Renderer&,const std::string&,int,int,double)=0;
  virtual bool gpu()const=0;
};
std::unique_ptr<NativeSurface> nativeSurface(void*);
}
