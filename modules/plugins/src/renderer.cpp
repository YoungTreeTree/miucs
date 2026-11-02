#include "renderer.hpp"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkData.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkFontMgr.h"
#include "include/codec/SkCodec.h"
#include "include/effects/SkGradient.h"
#ifdef __APPLE__
#include "include/ports/SkFontMgr_mac_ct.h"
#else
#include "include/ports/SkTypeface_win.h"
#endif
namespace miucs {
static SkColor color(const Json& j,SkColor fallback=0xff3d3d3d) {
  if(j.is_null())return fallback;
  if(!j.is_string())throw Error("Color must be #RRGGBB or #RRGGBBAA");
  std::string s=j; if((s.size()!=7&&s.size()!=9)||s[0]!='#'||s.find_first_not_of("0123456789abcdefABCDEF",1)!=s.npos)throw Error("Invalid color");
  auto v=std::stoul(s.substr(1),nullptr,16);
  return s.size()==7?SkColor(0xff000000|v):SkColor((v>>8)|((v&255)<<24));
}
static sk_sp<SkShader> gradient(const Json& g) {
  auto a=g.at("from"),b=g.at("to");if(a.size()!=2||b.size()!=2)throw Error("Invalid gradient points");
  std::vector<SkColor4f> colors;std::vector<float> positions;
  if(g.at("stops").size()<2||g["stops"].size()>16)throw Error("Gradient stop limit");
  float previous=-1;
  for(auto& stop:g["stops"]){float t=stop.at(0);if(t<0||t>1||t<previous)throw Error("Invalid gradient stop");previous=t;positions.push_back(t);colors.push_back(SkColor4f::FromColor(color(stop.at(1))));}
  SkPoint points[]={{a[0].get<float>(),a[1].get<float>()},{b[0].get<float>(),b[1].get<float>()}};
  return SkShaders::LinearGradient(points,SkGradient(SkGradient::Colors(colors,positions,SkTileMode::kClamp),{}));
}
sk_sp<SkImage> Renderer::image(const std::string& source) {
  if(images.contains(source))return images[source];
  auto bytes=readResource(root,source);auto data=SkData::MakeWithCopy(bytes.data(),bytes.size());
  auto codec=SkCodec::MakeFromData(data);if(!codec)throw Error("Unsupported or corrupt image");
  auto info=codec->getInfo().makeColorType(kBGRA_8888_SkColorType).makeAlphaType(kPremul_SkAlphaType);
  if(info.width()>4096||info.height()>4096||info.width()<=0||info.height()<=0||info.computeMinByteSize()>64*1024*1024-assetBytes)throw Error("Decoded image budget exceeded");
  SkBitmap bitmap;if(!bitmap.tryAllocPixels(info))throw Error("Image allocation failed");
  if(codec->getPixels(info,bitmap.getPixels(),bitmap.rowBytes())!=SkCodec::kSuccess)throw Error("Image decode failed");
  bitmap.setImmutable();assetBytes+=info.computeMinByteSize();auto result=SkImages::RasterFromBitmap(bitmap);images[source]=result;return result;
}
sk_sp<SkTypeface> Renderer::font(const std::string& source) {
  if(fonts.contains(source))return fonts[source];if(fonts.size()>=16)throw Error("Font limit exceeded");
  auto bytes=readResource(root,source,4*1024*1024);
#ifdef __APPLE__
  auto manager=SkFontMgr_New_CoreText(nullptr);
#else
  auto manager=SkFontMgr_New_DirectWrite();
#endif
  auto typeface=manager->makeFromData(SkData::MakeWithCopy(bytes.data(),bytes.size()));if(!typeface)throw Error("Invalid font");fonts[source]=typeface;return typeface;
}
void Renderer::drawNode(SkCanvas* c,const std::string& id,int depth) {
  if(depth>24)throw Error("Scene hierarchy too deep");auto& n=*scene.nodes.at(id);
  float opacity=n.value("opacity",1.0f);if(opacity<=0||!n.value("visible",true))return;
  c->save();c->translate(n.value("x",0.0f),n.value("y",0.0f));
  float w=n.value("width",0.0f),h=n.value("height",0.0f);auto pivot=n.value("pivot",Json::array({0,0}));
  float px=pivot.at(0).get<float>()*w,py=pivot.at(1).get<float>()*h;
  c->translate(px,py);
  if(n.contains("matrix")){auto& m=n["matrix"];if(m.size()!=6)throw Error("Affine matrix needs six values");c->concat(SkMatrix::MakeAll(m.at(0),m.at(2),m.at(4),m.at(1),m.at(3),m.at(5),0,0,1));}
  else {c->rotate(n.value("rotation",0.0f)*180.0f/3.141592653589793f);c->scale(n.value("scaleX",1.0f),n.value("scaleY",1.0f));}
  c->translate(-px,-py);
  if(n.contains("clip")){auto r=n["clip"];c->clipRect(SkRect::MakeXYWH(r.at(0),r.at(1),r.at(2),r.at(3)));}
  auto type=n.at("type").get<std::string>();
  bool layer=(type=="group" && opacity<1)||n.contains("mask");
  if(layer)c->saveLayerAlphaf(nullptr,std::clamp(opacity,0.0f,1.0f));
  float alpha=layer?1.0f:std::clamp(opacity,0.0f,1.0f);
  SkPaint paint;paint.setAntiAlias(n.value("antialias",true));paint.setColor(color(n.value("fill",Json())));paint.setAlphaf(paint.getAlphaf()*alpha);
  auto rect=SkRect::MakeWH(w,h);
  if(type=="image"){auto img=image(n.at("source"));auto sampling=SkSamplingOptions(n.value("sampling","")=="nearest"?SkFilterMode::kNearest:SkFilterMode::kLinear);
    if(n.contains("sourceRect")){auto s=n["sourceRect"];c->drawImageRect(img,SkRect::MakeXYWH(s.at(0),s.at(1),s.at(2),s.at(3)),rect,sampling,&paint,SkCanvas::kStrict_SrcRectConstraint);}else c->drawImageRect(img,rect,sampling,&paint);}
  else if(type=="text") {auto text=n.value("text",std::string{});SkFont f(font(n.at("font")),n.value("fontSize",12.0f));f.setEdging(SkFont::Edging::kAntiAlias);c->drawSimpleText(text.data(),text.size(),SkTextEncoding::kUTF8,0,n.value("baseline",12.0f),f,paint);}
  else if(type!="group") {
    if(n.contains("gradient"))paint.setShader(gradient(n["gradient"]));
    if(n.contains("stroke")){paint.setColor(color(n["stroke"]));paint.setAlphaf(paint.getAlphaf()*alpha);paint.setStyle(SkPaint::kStroke_Style);float width=n.value("strokeWidth",1.0f);if(n.value("constantStroke",false))width/=std::max(.001f,std::abs(n.value("scaleX",1.0f)));paint.setStrokeWidth(std::clamp(width,0.0f,128.0f));paint.setStrokeCap(SkPaint::kRound_Cap);paint.setStrokeJoin(SkPaint::kRound_Join);}
    if(type=="rect")c->drawRoundRect(rect,n.value("radius",0.0f),n.value("radius",0.0f),paint);
    else if(type=="ellipse")c->drawOval(rect,paint);
    else {
      auto geometryID=n.value("pathRef",id);const auto& geometry=*scene.nodes.at(geometryID);
      auto& cache=paths[geometryID];static const Json emptyPath=Json::array();const auto& p=geometry.contains("path")?geometry.at("path"):emptyPath;
      if(cache.source!=p){auto& builder=cache.builder;builder.reset();builder.incReserve(int(p.size()*3),int(p.size()),0);for(auto& v:p){std::string op=v[0];if(op=="M")builder.moveTo(v[1],v[2]);else if(op=="L")builder.lineTo(v[1],v[2]);else if(op=="Q")builder.quadTo(v[1],v[2],v[3],v[4]);else if(op=="C")builder.cubicTo(v[1],v[2],v[3],v[4],v[5],v[6]);else builder.close();}cache.source=p;cache.path=builder.snapshot();}
      if(n.value("halo",false)){SkPaint halo=paint;halo.setColor(0xfffafafa);halo.setAlphaf(paint.getAlphaf()*n.value("haloOpacity",.8f));halo.setStrokeWidth(paint.getStrokeWidth()+n.value("haloWidth",1.25f)/(n.value("constantStroke",false)?std::max(.001f,std::abs(n.value("scaleX",1.0f))):1.0f));c->drawPath(cache.path,halo);}
      c->drawPath(cache.path,paint);
    }
  }
  for(auto& child:children[id])drawNode(c,child,depth+1);
  if(n.contains("mask")){SkPaint mask;mask.setBlendMode(SkBlendMode::kDstIn);mask.setShader(gradient(n["mask"]));c->drawPaint(mask);}
  if(layer)c->restore();c->restore();
}
void Renderer::syncTree() {
  if(treeVersion==scene.treeRevision)return;
  children.clear();for(auto& [id,n]:scene.nodes)children[n->value("parent",std::string{})].push_back(id);
  for(auto& [parent,list]:children)std::stable_sort(list.begin(),list.end(),[&](auto& a,auto& b){auto& na=*scene.nodes.at(a);auto& nb=*scene.nodes.at(b);double za=na.value("z",0.0),zb=nb.value("z",0.0);return za==zb?na.value("order",0)<nb.value("order",0):za<zb;});
  for(auto it=paths.begin();it!=paths.end();)if(!scene.nodes.contains(it->first))it=paths.erase(it);else ++it;
  treeVersion=scene.treeRevision;
}
uint64_t Renderer::stampNode(const std::string& id) {
  uint64_t value=uint64_t(reinterpret_cast<uintptr_t>(scene.nodes.at(id).get()));
  const auto& node=*scene.nodes.at(id);if(node.contains("pathRef"))value^=uint64_t(reinterpret_cast<uintptr_t>(scene.nodes.at(node.at("pathRef").get<std::string>()).get()));
  for(auto& child:children[id])value^=stampNode(child)+0x9e3779b97f4a7c15ULL+(value<<6)+(value>>2);
  return value;
}
uint64_t Renderer::stamp(const std::string& output) {
  syncTree();if(!scene.nodes.contains(output))throw Error("Output root missing: "+output);
  if(stampRevision!=scene.revision){stamps.clear();stampRevision=scene.revision;}
  auto found=stamps.find(output);if(found!=stamps.end())return found->second;
  auto value=stampNode(output);stamps.emplace(output,value);return value;
}
void Renderer::paint(SkCanvas* c,const std::string& output,int width,int height) {
  c->clear(SK_ColorTRANSPARENT);syncTree();if(!scene.nodes.contains(output))throw Error("Output root missing: "+output);
  auto& rootNode=*scene.nodes.at(output);double w=rootNode.value("width",double(width)),h=rootNode.value("height",double(height));
  if(w<=0||h<=0)return;float scale=float(std::min(width/w,height/h));c->save();c->scale(scale,scale);drawNode(c,output,0);c->restore();
}
}
