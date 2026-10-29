local C=miucs.require("common.lua")
local R={}
function R.clear(cursor)R.pulses={};R.elapsed=0;R.cursor=cursor or 0;R.previousX=nil;R.rings={} end
R.clear()
function R.update(dt,events,now,through)
  R.elapsed=R.elapsed+dt
  for i=#R.pulses,1,-1 do if R.elapsed-R.pulses[i].born>=.89 then table.remove(R.pulses,i) end end
  for _,e in ipairs(events or {})do
    if e.sequence>R.cursor and e.sequence<=through then
      R.cursor=e.sequence;local age=now-e.receivedAt
      if age>=0 and age<=.15 and e.strength>=0 and e.strength<=1 and e.confidence>=.45 and e.confidence<=1 and e.bpm>=50 and e.bpm<=200 then
        if #R.pulses==4 then table.remove(R.pulses,1) end
        local x=112+miucs.random()*600
        if R.previousX and math.abs(x-R.previousX)<120 then x=112+(x-112+300)%600 end
        R.previousX=x;local y=48+miucs.random()*64;local phase=miucs.random()*2*math.pi
        R.pulses[#R.pulses+1]={born=R.elapsed-age,strength=e.strength,x=x,y=y,phase=phase}
      end
    end
  end
  R.cursor=math.max(R.cursor,through);R.rings={}
  for _,p in ipairs(R.pulses)do
    local age=R.elapsed-p.born
    for layer=0,1 do
      local a=age-layer*.09
      if a>=0 and a<.8 then local t=a/.8
        R.rings[#R.rings+1]={x=p.x,y=p.y,radius=4+(layer==0 and 28 or 20)*(1-(1-t)^3),opacity=math.min(1,a/.035)*(1-t)^1.1*(layer==0 and .73 or .48)*(.85+.15*p.strength),width=layer==0 and 1.05 or .72,rotation=p.phase+layer*.2,kind="main"}
      end
    end
    for i=0,2 do
      local a=age-.10-i*.055
      if a>=0 and a<.58 then
        local t=a/.58;local expansion=1-(1-t)^3;local travel=.7+.3*expansion
        local angle=p.phase*1.31+({.4,2.5,4.55})[i+1];local distance=28+i*6
        R.rings[#R.rings+1]={x=p.x+math.cos(angle)*distance*travel,y=p.y+math.sin(angle)*distance*.8*travel,radius=1.5+(({6.2,8.3,5.3})[i+1]-1.5)*expansion,opacity=math.min(1,a/.06)*.55*(1-t)^1.2*(.85+.15*p.strength),width=.65,rotation=angle,kind="satellite"}
      end
    end
  end
end
function R.arc(kind,band)
  local pieces=kind=="main" and {{.05,1.30},{1.88,3.57},{4.15,5.72}} or {{-.65,1.55}}
  local intervals=({{{0,.07},{.93,1}},{{.07,.22},{.78,.93}},{{.22,.78}}})[band]
  local path={}
  for _,piece in ipairs(pieces)do for _,interval in ipairs(intervals)do
    for i=0,24 do
      local a=piece[1]+(piece[2]-piece[1])*(interval[1]+(interval[2]-interval[1])*i/24)
      local r=10*(1+.016*math.sin(3*a));path[#path+1]={i==0 and "M" or "L",math.cos(a)*r,math.sin(a)*r}
    end
  end end
  return path
end
return R
