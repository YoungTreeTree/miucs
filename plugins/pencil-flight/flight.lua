local C=miucs.require("common.lua")
local W=miucs.require("flight_state.lua")
local M={ink="#3d3d3d",ids={}}
local cloud={{"M",-24,9},{"C",-27,1,-20,-5,-14,-1},{"C",-13,-18,8,-19,9,-4},{"C",23,-11,31,2,25,9},{"C",5,12,-10,7,-24,9}}
local puff={{"M",.8,.3},{"C",.8,.8,.5,1,.2,.8},{"C",-.2,1.1,-.8,1,-.7,.5},{"C",-1.2,.5,-1.3,-.3,-.8,-.4},{"C",-.8,-1,-.1,-1.1,.1,-.6},{"C",.7,-.8,.9,-.2,.6,-.1},{"C",.3,.3,-.4,-.2,-.15,.15}}
local function path(id,p,extra)
  local n=C.path(id,p,extra);n.halo=true;n.haloWidth=1.05;n.haloOpacity=.62;M.ids[#M.ids+1]=id;return n
end
local function sketch(points,seed)
  local result={{"M",points[1][1],points[1][2]}};local index=0
  for i=2,#points do local a,b=points[i-1],points[i];local steps=math.max(1,math.floor(math.sqrt((b[1]-a[1])^2+(b[2]-a[2])^2)/7))
    for step=1,steps do local t=step/steps;local jitter=step==steps and 0 or W.noise(index,seed)*.27
      result[#result+1]={"L",a[1]+(b[1]-a[1])*t+jitter,a[2]+(b[2]-a[2])*t+jitter*.7};index=index+1
    end
  end;return result
end
function M.scene()
  local nodes={};local function add(n)nodes[#nodes+1]=n end
  for i=0,2 do add(path("flight-cloud-"..i,cloud,{opacity=.36}))end
  add(path("flight-ground",sketch({{8,247},{130,247.4},{266,246.8},{391,247}},401),{strokeWidth=.9,opacity=.44}))
  for i=0,12 do add(path("flight-grass-"..i,sketch({{0,0},{3+i%3,-1}},i+600),{opacity=.33,strokeWidth=.65}))end
  local gates={};for i=1,8 do gates[#gates+1]=path("flight-gate-"..i,{{"M",0,0}},{opacity=0})end
  add {type="group",id="flight-gates",z=1,clip={96,0,304,260},mask={from={96,0},to={400,0},stops={{0,"#ffffff00"},{1,"#ffffffff"}}},children=gates}
  for i=1,80 do add(path("flight-particle-"..i,{{"M",0,0},{"L",1.6,-.8}},{opacity=0,strokeWidth=.7,z=2}))end
  for i=1,6 do add(path("flight-puff-"..i,puff,{opacity=0,strokeWidth=.8,constantStroke=true,z=3}))end
  add {type="group",id="flight-bird",x=96,y=126,z=4,children={
    path("flight-body",{{"M",-15,0},{"C",-14,-14,0,-15,7,-10},{"C",14,-9,15,-4,15,1},{"C",16,15,-14,17,-15,0}},{strokeWidth=1.55,opacity=.96}),
    path("flight-beak",sketch({{14,-1},{23,2},{14,5}},31),{strokeWidth=1.35}),
    path("flight-feathers",sketch({{-14,2},{-23,-1},{-18,7},{-12,8}},32),{strokeWidth=1.3}),
    {type="ellipse",id="flight-eye",x=7,y=-5,width=2.8,height=3.1,fill="#3d3d3d",z=2},
    path("flight-wing",{{"M",-7,3},{"C",-15,6,-9,17,1,7}},{strokeWidth=1.4,opacity=.94,z=3}),
    path("flight-motion",{{"M",-13,-5},{"L",-17,-8}},{strokeWidth=.7,opacity=0,z=4})
  }}
  add {type="text",id="flight-label",x=40,y=114,text="-",font="assets/NotoSans-Regular.ttf",fontSize=17,z=5,opacity=.3}
  add {type="text",id="flight-score",x=354,y=9,text="0",font="assets/NotoSans-Regular.ttf",fontSize=21,z=5,opacity=.75}
  return {type="group",id="pencil-flight",width=400,height=260,children=nodes}
end
function M.reset()W.reset()end
function M.appearance(color)M.ink=color;for _,id in ipairs(M.ids)do miucs.set(id,{stroke=color})end;for _,id in ipairs({"flight-eye","flight-label","flight-score"})do miucs.set(id,{fill=color})end end
function M.update(frame)
  W.update(frame)
  for i=0,2 do local raw=i*171+38-W.distance*(.10+i*.025);local x=raw-math.modf(raw/510)*510;if x< -65 then x=x+510 end
    miucs.set("flight-cloud-"..i,{x=x,y=34+(i%2)*38,strokeWidth=.85-W.brightness*.22})end
  for i=0,12 do miucs.set("flight-grass-"..i,{x=(i*37-W.distance*.65)%440,y=250+math.abs(W.noise(i,9))*5})end
  for i=1,8 do local g=W.gates[i];local x=g and 96+g.x-W.distance or 0
    if g and x>96 and x<440 then
      local body=17+W.bass*W.flap*1.5;local cap=24+W.bass*W.flap*2;local pathData={}
      local function add(points,seed)for _,cmd in ipairs(sketch(points,seed))do pathData[#pathData+1]=cmd end end
      for _,side in ipairs({-1,1})do add({{side*body,-3},{side*body,g.top-9}},g.id*11+side+1000);add({{side*body,g.bottom+9},{side*body,246}},g.id*11+side+1100)end
      for index,pair in ipairs({{g.top,-1},{g.bottom,1}})do local edge,d=pair[1],pair[2]
        add({{-cap,edge+d*9},{-cap,edge},{cap,edge},{cap,edge+d*9},{-cap,edge+d*9}},g.id*17+index-1+1700)
        for h=0,3 do local hx=-cap+5+h*5;add({{hx,edge+d*2},{hx+3,edge+d*6}},g.id+h+1500)end
      end
      miucs.set("flight-gate-"..i,{x=x,path=pathData,strokeWidth=1.15+W.bass*.5,opacity=g.passed and .64 or .87})
    else miucs.set("flight-gate-"..i,{opacity=0})end
  end
  local stretch=1+W.flap*W.loudness*.06;miucs.set("flight-bird",{y=W.y,rotation=W.angle,scaleX=W.scale/stretch,scaleY=W.scale*stretch})
  local lift=W.flap*(10+W.loudness*9);miucs.set("flight-wing",{path={{"M",-7,3},{"C",-15,6-lift,-9,17-lift,1,7-lift}}})
  miucs.set("flight-motion",{path=sketch({{-13,-5-lift*.35},{-17,-8-lift*.45}},42),opacity=W.flap>.35 and W.flap*.45 or 0})
  for i=1,80 do local p=W.particles[i]
    miucs.set("flight-particle-"..i,p and {x=p.x,y=p.y,path=p.feather and {{"M",-4,2},{"C",-5,-5,1,-6,4,-2}} or sketch({{0,0},{1.6,-.8}},p.id),opacity=p.life/p.lifetime*(p.feather and .5 or .62),strokeWidth=p.feather and .8 or .7} or {opacity=0})
  end
  for i=1,6 do local p=W.puffs[i]
    if p then local t=math.min(p.age/p.lifetime,1);local r=(5+p.strength*10)*(.55+t*.85)
      miucs.set("flight-puff-"..i,{x=p.x,y=p.y,scaleX=r,scaleY=r*.72,strokeWidth=.75+p.strength*.25,opacity=math.min(p.age/.05,1)*(1-t)*(.2+p.strength*.65)*math.min(p.strength/.15,1)})
    else miucs.set("flight-puff-"..i,{opacity=0})end
  end
  local note="-";local opacity=.3
  if W.audio and not W.audio.isSilent and W.audioAge<.4 and W.noteAge<.24 and W.note then local names={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};note=names[W.note%12+1]..(math.floor(W.note/12)-1);opacity=.88*C.clamp((.24-W.noteAge)/.12,0,1)end
  miucs.set("flight-label",{x=math.max(6,96-(W.halfWidth or 20)-10-#note*9),y=W.y-12,text=note,opacity=opacity});miucs.set("flight-score",{text=tostring(W.score)})
end
return M
