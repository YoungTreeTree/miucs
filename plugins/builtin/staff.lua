local C=miucs.require("common.lua")
local State=miucs.require("staff_state.lua")
local Rings=miucs.require("rings.lua")
local Stars=miucs.require("stars.lua")
local M={ink="#3d3d3d",kinds={}}
local function pencil(id,geometry,extra)
  local node=C.path(id,geometry,extra);node.halo=true;return node
end
local function stem(down)
  local x=down and -4.8 or 4.8;local tip=down and 26 or -26
  return {{"M",x,0},{"Q",x-.14,tip/2,x+.12,tip},{"M",x,tip},
    {"C",x+3,tip+(down and -4 or 4),x+11,tip+(down and -2 or 7),x+8,tip+(down and -10 or 11)},
    {"Q",x+9,tip+(down and -14 or 15),x+6,tip+(down and -17 or 18)}}
end
local upStem,downStem=stem(false),stem(true)
local sharp,hatch={},{}
for _,x in ipairs({-17,-13.4})do sharp[#sharp+1]={"M",x,-7};sharp[#sharp+1]={"L",x-.5,7}end
for _,y in ipairs({-2.8,2.8})do sharp[#sharp+1]={"M",-20,y+1};sharp[#sharp+1]={"L",-10.6,y-1}end
for i=0,3 do local x=-3.8+i*2;hatch[#hatch+1]={"M",x,1.5};hatch[#hatch+1]={"L",x+1.4,-1.6}end
local arcs={main={},satellite={}}
for _,kind in ipairs({"main","satellite"})do for band=1,3 do arcs[kind][band]=Rings.arc(kind,band) end end
local star={};for i=0,9 do local angle=-math.pi/2+i*math.pi/5;local radius=i%2==0 and 1 or .42;star[#star+1]={i==0 and "M" or "L",math.cos(angle)*radius,math.sin(angle)*radius} end;star[#star+1]={"Z"}
function M.scene()
  miucs.load {type="path",id="staff-star-geometry",visible=false,path=star}
  for _,kind in ipairs({"main","satellite"})do for band=1,3 do
    miucs.load {type="path",id="ring-geometry-"..kind.."-"..band,visible=false,path=arcs[kind][band]}
  end end
  local nodes={};local function add(n)nodes[#nodes+1]=n end
  for i=0,4 do add(pencil("staff-line-"..i,{{"M",20,58+i*8},{"C",240,58+i*8+(i%2==0 and .14 or -.14),570,58+i*8-.12,780,58+i*8}},{opacity=.48,strokeWidth=.72}))end
  add(pencil("staff-clef",{{"M",41,86},{"C",35,87,31,81,36,78},{"C",42,72,50,77,48,83},{"C",47,95,30,97,29,89},{"C",19,78,34,67,39,61},{"C",46,54,45,46,41,43},{"C",32,45,34,56,36,63},{"C",39,79,43,93,44,103},{"C",47,117,31,115,33,108},{"C",31,104,34,102,36,105}},{opacity=.8,strokeWidth=1.35}))
  add {type="group",id="staff-trace-clip",clip={80,0,560,160},mask={from={80,0},to={640,0},stops={{0,"#ffffff00"},{1,"#ffffffff"}}},children={pencil("staff-trace",{{"M",0,0}},{opacity=.52,strokeWidth=1.05})}}
  for i=1,112 do add(pencil("staff-star-"..i,nil,{pathRef="staff-star-geometry",opacity=0,z=2,strokeWidth=.17,haloWidth=.25}))end
  local rings={}
  for i=1,20 do
    local children={}
    for band=1,3 do
      local taper=({.48,.78,1})[band]
      children[#children+1]=C.path("ring-halo-"..i.."-"..band,nil,{pathRef="ring-geometry-main-"..band,stroke="#ffffff",strokeWidth=1.9,opacity=taper*.8,z=band*2})
      children[#children+1]=C.path("ring-ink-"..i.."-"..band,nil,{pathRef="ring-geometry-main-"..band,strokeWidth=1.05,opacity=taper,z=band*2+1})
    end
    rings[#rings+1]={type="group",id="ring-"..i,opacity=0,children=children}
  end
  add {type="group",id="staff-rings",clip={0,0,800,160},mask={from={0,0},to={0,160},stops={{0,"#ffffff00"},{.05,"#ffffffff"},{.95,"#ffffffff"},{1,"#ffffff00"}}},children=rings,z=3}
  local function head(id,fill,stroke,width)
    return {type="ellipse",id=id,x=-5.7,y=-3.8,width=11.4,height=7.6,pivot={.5,.5},rotation=-.32,fill=fill,stroke=stroke,strokeWidth=width}
  end
  add {type="group",id="staff-marker",x=640,y=74,opacity=0,z=4,children={head("staff-marker-fill","#f5f5f5cc"),head("staff-marker-stroke",nil,M.ink,.65)}}
  add {type="group",id="staff-note-body",x=640,y=74,z=5,children={
    {type="group",id="staff-note-sway",children={pencil("staff-note-stem",upStem,{strokeWidth=1.35})}},
    head("staff-note-outline",nil,M.ink,1.5),head("staff-note-head",M.ink),
    C.path("staff-note-hatch",hatch,{stroke="#cccccc38",strokeWidth=.35}),
    pencil("staff-sharp",sharp,{strokeWidth=1,opacity=0})
  }}
  add {type="text",id="staff-label",x=664,y=66,font="assets/NotoSans-Regular.ttf",fontSize=14,text="",fill=M.ink,z=6}
  add {type="text",id="staff-placeholder",x=664,y=66,font="assets/NotoSans-Regular.ttf",fontSize=14,text="—",fill=M.ink,z=6,opacity=.4}
  return {type="group",id="staff-note",width=800,height=160,children=nodes}
end
function M.reset()State.reset();Stars.clear();Rings.clear()end
function M.appearance(color)
  M.ink=color
  for i=0,4 do miucs.set("staff-line-"..i,{stroke=color})end
  for _,id in ipairs({"staff-clef","staff-trace","staff-note-stem","staff-sharp","staff-note-outline","staff-marker-stroke"})do miucs.set(id,{stroke=color})end
  for _,id in ipairs({"staff-note-head","staff-label","staff-placeholder"})do miucs.set(id,{fill=color})end
  for i=1,112 do miucs.set("staff-star-"..i,{stroke=color})end
  for i=1,20 do for b=1,3 do miucs.set("ring-ink-"..i.."-"..b,{stroke=color})end end
end
function M.update(frame)
  local dt=frame.deltaTime;Stars.update(dt,frame.keyboard)
  local reset=State.update(dt,frame.audio);local audio,af=C.audio(frame.audio)
  if reset then Rings.clear(State.ringClearCursor or 0) end
  if audio then Rings.update(dt,frame.audio.beats,af.receivedAt+frame.audio.frameAge,af.sequence) else Rings.clear((frame.audio and frame.audio.frame or {}).sequence or 0) end
  miucs.set("staff-trace",{path=State.path()})
  miucs.set("staff-note-body",{y=State.y,scaleX=State.scale,scaleY=State.scale,opacity=State.opacity})
  miucs.set("staff-note-sway",{rotation=State.angle})
  miucs.set("staff-note-stem",{path=State.y<74 and downStem or upStem})
  miucs.set("staff-marker",{y=State.target,opacity=State.pitch and .28+.2*State.labelOpacity or 0})
  local p=State.pitch;local names={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  local labelY=C.clamp(State.target-8,5,139)
  miucs.set("staff-label",{y=labelY,text=p and names[p%12+1]..(math.floor(p/12)-1) or "",opacity=State.labelOpacity*.85})
  miucs.set("staff-placeholder",{y=labelY,opacity=(1-State.labelOpacity)*.4})
  local sharp=p and ({[1]=true,[3]=true,[6]=true,[8]=true,[10]=true})[p%12]
  miucs.set("staff-sharp",{opacity=sharp and .9 or 0})
  for i=1,112 do local s=Stars.stars[i];miucs.set("staff-star-"..i,s and {x=s.x,y=s.y,scaleX=s.radius,scaleY=s.radius,rotation=s.rotation,opacity=s.opacity} or {opacity=0})end
  for i=1,20 do
    local r=Rings.rings[i];miucs.set("ring-"..i,r and {x=r.x,y=r.y,scaleX=r.radius/10,scaleY=r.radius/10*.9,rotation=r.rotation,opacity=r.opacity} or {opacity=0})
    if r then
      local scale=r.radius/10;local cosine,sine=math.cos(r.rotation),math.sin(r.rotation)
      miucs.set("ring-"..i,{matrix={scale*cosine,scale*.9*sine,-scale*sine,scale*.9*cosine,0,0}})
      for band=1,3 do
      miucs.set("ring-halo-"..i.."-"..band,{strokeWidth=(r.width+.85)/(r.radius/10)})
      miucs.set("ring-ink-"..i.."-"..band,{strokeWidth=r.width/(r.radius/10)})
      if M.kinds[i]~=r.kind then
        miucs.set("ring-halo-"..i.."-"..band,{pathRef="ring-geometry-"..r.kind.."-"..band})
        miucs.set("ring-ink-"..i.."-"..band,{pathRef="ring-geometry-"..r.kind.."-"..band})
      end
    end; M.kinds[i]=r.kind end
  end
end
return M
