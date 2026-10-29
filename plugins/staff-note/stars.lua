local C=miucs.require("common.lua")
local keys={};for _,k in ipairs(miucs.require("keys.lua"))do keys[k.key]=k end
local S={}
function S.clear()S.elapsed=0;S.bursts={};S.held={};S.session=nil;S.cursor=0;S.count=0;S.stars={};S.caps=nil end
S.clear()
local modifiers={leftShift=true,rightShift=true,leftControl=true,rightControl=true,leftOption=true,rightOption=true,leftCommand=true,rightCommand=true,["function"]=true,capsLock=true}
local function emit(key,born,small)
  if not keys[key] then return end
  if #S.bursts==16 then table.remove(S.bursts,1) end
  S.count=S.count+1;local count=small and 4 or 6;local phase=(S.count%17)*.37;local particles={}
  for i=0,count-1 do local angle=i*2*math.pi/count+phase
    local r=(3+((i*7+S.count%11)%5)*.5)*(small and .76 or 1);local d=(12+((i*11+S.count%13)%17))*(small and .78 or 1)
    particles[#particles+1]={radius=r,dx=math.cos(angle)*d,dy=math.sin(angle)*d,rotation=angle*.3,spin=i%2==0 and .7 or -.6}
  end
  S.bursts[#S.bursts+1]={key=key,born=born,small=small,particles=particles}
end
function S.update(dt,input)
  S.elapsed=S.elapsed+dt
  for i=#S.bursts,1,-1 do if S.elapsed-S.bursts[i].born>=.65 then table.remove(S.bursts,i) end end
  if input then
    if S.session~=input.sessionID then S.session=input.sessionID;S.cursor=0;S.caps=nil;S.held={} end
    if input.state~="running" then S.held={};S.cursor=input.sequence;S.caps=((input.modifiers or 0)&16)~=0
    else
      if (input.droppedEventCount or 0)>0 then S.held={} end
      for _,e in ipairs(input.events or {})do
        if C.fresh(e,input.sampledAt,S.cursor,input.sequence,.25) and keys[e.key] then
          local born=S.elapsed-(input.sampledAt-e.receivedAt)
          if e.kind=="pressed" and not modifiers[e.key] and not S.held[e.key] then emit(e.key,born,false);S.held[e.key]={next=born+.3}
          elseif e.kind=="released" then S.held[e.key]=nil
          elseif e.kind=="modifiersChanged" then
            if e.key=="capsLock" then
              local locked=e.modifierIsPressed;if locked==nil then locked=((e.modifiers or 0)&16)~=0 end
              if S.caps~=locked then emit(e.key,born,false) end;S.caps=locked
            elseif modifiers[e.key] and e.modifierIsPressed then emit(e.key,born,false) end
          end
        end
      end
      S.cursor=math.max(S.cursor,input.sequence);S.caps=((input.modifiers or 0)&16)~=0
      local held={};for _,k in ipairs(input.heldKeys or {})do if k.key then held[k.key]=true end end
      for k in pairs(S.held)do if not held[k] then S.held[k]=nil end end
    end
  else S.held={} end
  local sorted={};for k in pairs(S.held)do sorted[#sorted+1]=k end;table.sort(sorted)
  for _,k in ipairs(sorted)do if S.elapsed+1e-9>=S.held[k].next then emit(k,S.elapsed,true);S.held[k].next=S.elapsed+.18 end end
  S.stars={}
  for _,b in ipairs(S.bursts)do
    local age=math.max(0,S.elapsed-b.born);local t=math.min(1,age/.65);local origin=keys[b.key]
    if age<.1 then local p=age/.1;S.stars[#S.stars+1]={x=origin.sx,y=origin.sy,radius=(3.5+4.5*(1-(1-p)^3))*(b.small and .75 or 1),rotation=-.12+p*.24,opacity=.95*(1-p)} end
    local travel=1-(1-t)^3
    for _,p in ipairs(b.particles)do S.stars[#S.stars+1]={x=origin.sx+p.dx*travel,y=origin.sy+p.dy*travel,radius=p.radius*(.7+.3*math.min(1,age/.035))*(1-t*.15),rotation=p.rotation+p.spin*t,opacity=.9*(1-t)^1.4} end
  end
end
return S
