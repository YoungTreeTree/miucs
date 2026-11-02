local K={keys=miucs.require('keys.lua'),positions={}}
for _,k in ipairs(K.keys) do K.positions[k.key]=k end
local function base(k) return (#k.label>1 or k.key=='space') and '#B9CBB0' or '#F7F1E4' end
local function rect(id,x,y,w,h,fill)
  return {type='rect',id=id,x=x,y=y,width=w,height=h,fill=fill,antialias=false}
end
local function polygon(id,points,fill)
  local path={};for i,p in ipairs(points)do path[#path+1]={i==1 and "M" or "L",p[1],p[2]} end;path[#path+1]={"Z"}
  return {type="path",id=id,path=path,fill=fill,antialias=false}
end
local function box(id,x,y,w,h,color,s)
  s=s or 4
  return polygon(id,{{x+s,y},{x+w-s,y},{x+w-s,y+s},{x+w,y+s},{x+w,y+h-s},{x+w-s,y+h-s},{x+w-s,y+h},{x+s,y+h},{x+s,y+h-s},{x,y+h-s},{x,y+s},{x+s,y+s}},color)
end
function K.scene()
  local nodes={};local function add(n)nodes[#nodes+1]=n end
  for i,x in ipairs({100,660})do add(box("hinge"..i,x,164,40,28,"#202D43"));add(box("hinge-inner"..i,x+5,166,30,22,"#344763",2))end
  add(box("screen-outline",24,0,752,172,"#202D43",8));add(box("screen-side",28,4,744,164,"#344763",6));add(box("screen-dark",34,10,732,152,"#2A3A53",4));add(rect("screen-paper",40,14,720,144,"#F7F1E4"))
  add(polygon("keyboard-case",{{28,184},{772,184},{800,402},{790,418},{10,418},{0,402}},"#202D43"))
  add(polygon("keyboard-side",{{32,188},{768,188},{792,400},{784,412},{16,412},{8,400}},"#2A3A53"))
  add(polygon("keyboard-top",{{34,188},{766,188},{786,398},{14,398}},"#344763"));add(rect("keyboard-shine",38,188,724,3,"#687E99"))
  for _,k in ipairs(K.keys) do
    add(box("key-border-"..k.key,k.x,k.y,k.width,34,"#202D43",3))
    add(box("key-side-"..k.key,k.x+2,k.y+2,k.width-4,30,"#C4BFB2",2))
    local n=box("key-top-"..k.key,3,1,k.width-6,26,base(k),2);n.x=k.x;n.y=k.y;add(n)
    add {type="text",id="key-label-"..k.key,x=k.x+k.width/2-#k.label*3,y=k.y+5,text=k.label,font="assets/NotoSans-Regular.ttf",fontSize=#k.label>3 and 10 or 12,fill="#202D43"}
  end
  return nodes
end
local modifiers={leftShift=1,rightShift=1,leftControl=2,rightControl=2,leftOption=4,rightOption=4,leftCommand=8,rightCommand=8,['function']=32}
function K.reset()
  K.state={session=nil,cursor=0,time=0,pressed={},observed={},modHeld={},flash={},lit={},recent={}}
end
K.reset()
function K.update(frame)
  local dt=math.max(0,frame.deltaTime or 0)
  local input=frame.keyboard
  local session=input and input.sessionID
  local changed=session~=K.state.session
  if changed then K.reset();K.state.session=session end
  local s=K.state;s.time=s.time+dt
  local now=frame.now or 0
  local sampled=input and input.sampledAt or -1e9
  local live=input and input.state=='running' and now-sampled>=-.05 and now-sampled<=.4
  local lost=input and (input.droppedEventCount or 0)>0
  local through=input and input.sequence or 0
  local hits={count=0,reset=changed or not live or lost or dt>.5}
  for key,expiry in pairs(s.flash) do if expiry<=s.time then s.flash[key]=nil end end
  while #s.recent>0 and s.recent[1]<s.time-1 do table.remove(s.recent,1) end
  if not live or dt>.5 or lost then
    s.flash={};s.pressed={};s.observed={};s.modHeld={};s.recent={};s.caps=false
  else
    local cursor=s.cursor
    local function strike(key)
      s.flash[key]=s.time+.10;hits.count=hits.count+1
      s.recent[#s.recent+1]=s.time
      if #s.recent>32 then table.remove(s.recent,1) end
    end
    for _,e in ipairs(input.events or {}) do
      local seq=e.sequence or 0
      if seq>cursor and seq<=through then
        cursor=seq
        local age=math.max(now,sampled)-(e.receivedAt or -1e9)
        local key=e.key
        if K.positions[key] and age>=0 and age<=.25 then
          if e.kind=='pressed' and not modifiers[key] and key~='capsLock' then
            if not s.observed[key] then strike(key) end;s.observed[key]=true
          elseif e.kind=='released' then s.observed[key]=nil;s.flash[key]=nil
          elseif e.kind=='modifiersChanged' then
            if key=='capsLock' then strike(key)
            elseif modifiers[key] then
              if e.modifierIsPressed and not s.modHeld[key] then strike(key) end
              s.modHeld[key]=e.modifierIsPressed or nil
              if e.modifierIsPressed==false then s.flash[key]=nil end
            end
          end
        end
      end
    end
    s.pressed={}
    for _,held in ipairs(input.heldKeys or {}) do if K.positions[held.key] then s.pressed[held.key]=true end end
    for key in pairs(s.observed) do if not s.pressed[key] then s.observed[key]=nil end end
    local bits=input.modifiers or 0
    for key in pairs(s.modHeld) do
      if (bits&modifiers[key])~=0 then s.pressed[key]=true else s.modHeld[key]=nil end
    end
    s.caps=(bits&16)~=0
  end
  s.cursor=math.max(s.cursor,through)
  for _,k in ipairs(K.keys) do
    local lit=not not(s.pressed[k.key] or s.flash[k.key] or (k.key=='capsLock' and s.caps))
    if s.lit[k.key]~=lit then
      s.lit[k.key]=lit
      miucs.set('key-side-'..k.key,{fill=lit and '#B77D87' or ((#k.label>1 or k.key=='space') and '#8EAA8A' or '#C4BFB2')})
      miucs.set('key-top-'..k.key,{fill=lit and '#E9A6AA' or base(k),y=k.y+(lit and 3 or 0)})
      miucs.set('key-label-'..k.key,{y=k.y+(lit and 8 or 5)})
    end
  end
  hits.rate=#s.recent
  return hits
end
return K
