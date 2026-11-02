local C=miucs.require('common.lua')
local H=miucs.require('hoof.lua')
local K={keys=miucs.require('keys.lua'),positions={}}
for _,key in ipairs(K.keys)do K.positions[key.key]=key end
local modifier={leftShift=1,rightShift=1,leftControl=2,rightControl=2,leftOption=4,rightOption=4,leftCommand=8,rightCommand=8,['function']=32}
function K.scene()
 local n={};local function add(v)n[#n+1]=v end
 for i,x in ipairs({100,660})do add(C.box('hinge'..i,x,164,40,28,'#69503D'));add(C.box('hinge-inner'..i,x+5,166,30,22,'#E1B84D',2))end
 add(C.box('screen-outline',24,0,752,172,'#69503D',8));add(C.box('screen-side',28,4,744,164,'#E1B84D',6));add(C.box('screen-dark',34,10,732,152,'#FFE6A3',4));add(C.rect('screen-paper',40,14,720,144,'#FBF7EF'))
 add(C.polygon('keyboard-case',{{28,184},{772,184},{800,402},{790,418},{10,418},{0,402}},'#69503D'))
 add(C.polygon('keyboard-side',{{32,188},{768,188},{792,400},{784,412},{16,412},{8,400}},'#BB852E'))
 add(C.polygon('keyboard-top',{{34,188},{766,188},{786,398},{14,398}},'#EDC44B'));add(C.rect('keyboard-shine',38,188,724,3,'#FFE994'))
 for _,k in ipairs(K.keys)do
  add(C.box('key-border-'..k.key,k.x,k.y,k.width,34,'#A47B38',3))
  add(C.box('key-side-'..k.key,k.x+2,k.y+2,k.width-4,30,'#DBB85D',2))
  local top=C.box('key-top-'..k.key,3,1,k.width-6,26,#k.label>1 and '#E8CCE1' or '#FFF6D8',2);top.x=k.x;top.y=k.y;add(top)
  add{type='text',id='key-label-'..k.key,x=k.x+k.width/2-#k.label*3,y=k.y+5,text=k.label,font='assets/DejaVuSans.ttf',fontSize=#k.label>3 and 10 or 12,fill='#72513E'}
 end
 add(H.node('left'));add(H.node('right'));return n
end
function K.reset()
 K.state={session=nil,cursor=0,time=0,pressed={},modHeld={},flash={},rank={},assigned={},serial=0,spaceLeft=true,lit={},strikes=0}
 for _,side in ipairs({'left','right'})do local key=side=='left' and 'f' or 'j';local p=K.positions[key];K.state[side]={key=key,x=p.x+p.width/2,y=p.y+15,down=0}end
end
K.reset()
local function sideFor(s,key,newStrike)
 if key=='space' then
  if newStrike then s.assigned[key]=s.spaceLeft and 'left' or 'right';s.spaceLeft=not s.spaceLeft end
  return s.assigned[key] or 'left'
 end
 local p=K.positions[key];return p.x+p.width/2<400 and 'left' or 'right'
end
function K.update(frame)
 frame=type(frame)=='table' and frame or {};local dt=C.clamp(C.number(frame.deltaTime,0),0,60)
 local input=type(frame.keyboard)=='table' and frame.keyboard or nil
 local s=K.state
 if (input and input.sessionID or nil)~=s.session then K.reset();s=K.state;s.session=input and input.sessionID or nil end
 s.time=s.time+dt
 for key,expiry in pairs(s.flash)do if expiry<=s.time then s.flash[key]=nil end end
 local now=C.number(frame.now,0);local sample=input and C.number(input.sampledAt,-1e9) or -1e9
 local live=input and input.state=='running' and now-sample>=-.05 and now-sample<=.4
 local through=input and C.number(input.sequence,0) or 0
 local reference=math.max(now,sample)
 if not live or dt>.5 then s.pressed={};s.modHeld={};s.flash={};s.rank={}
 else
  if C.number(input.droppedEventCount,0)>0 then s.modHeld={};s.flash={};s.rank={} end
  local function strike(key)
   s.serial=s.serial+1;s.rank[key]=s.serial;s.flash[key]=s.time+.10;s.strikes=s.strikes+1;s[sideFor(s,key,true)].key=key
  end
  local cursor=s.cursor
  for _,e in ipairs(input.events or {})do
   local seq=C.number(e.sequence,0);local age=reference-C.number(e.receivedAt,-1e9);local key=e.key
   if seq>cursor and seq<=through then
    cursor=seq
    if key and K.positions[key] and age>=0 and age<=.25 then
     if e.kind=='pressed' and not modifier[key] and key~='capsLock' then strike(key)
     elseif e.kind=='released' then s.flash[key]=nil
     elseif e.kind=='modifiersChanged' then
      if key=='capsLock' then strike(key)
      elseif modifier[key] then
       if e.modifierIsPressed==true then if not s.modHeld[key] then strike(key)end;s.modHeld[key]=true
       elseif e.modifierIsPressed==false then s.modHeld[key]=nil;s.flash[key]=nil end
      end
     end
    end
   end
  end
  -- Snapshots, not event lifetime, own physical hold/release state. Existing holds light
  -- on new subscriptions without synthesizing a strike, typing rate, or jump.
  s.pressed={}
  for _,held in ipairs(input.heldKeys or {})do
   if held.key and K.positions[held.key] and not modifier[held.key] and held.key~='capsLock' then s.pressed[held.key]=true end
  end
  local bits=math.floor(C.number(input.modifiers,0))
  for key in pairs(s.modHeld)do if (bits&modifier[key])~=0 then s.pressed[key]=true else s.modHeld[key]=nil end end
  s.caps=(bits&16)~=0
 end
 if not live or dt>.5 then s.caps=false end
 s.cursor=math.max(s.cursor,through)
 for _,k in ipairs(K.keys)do
  local lit=not not(s.pressed[k.key] or s.flash[k.key] or (k.key=='capsLock' and s.caps))
  if s.lit[k.key]~=lit then
   s.lit[k.key]=lit
   miucs.set('key-side-'..k.key,{fill=lit and '#AC6B28' or '#DBB85D'})
   miucs.set('key-top-'..k.key,{fill=lit and '#FFDE68' or (#k.label>1 and '#E8CCE1' or '#FFF6D8'),y=k.y+(lit and 4 or 0)})
   miucs.set('key-label-'..k.key,{y=k.y+(lit and 9 or 5)})
  end
 end
 for _,side in ipairs({'left','right'})do
  local p=s[side]
  -- Match pixel-keyboard: only a new strike moves the target. Releasing a key
  -- lifts this hoof in place, even if another same-side key remains held.
  -- Running-idle does not return to F/J; unavailable input does.
  if not live then p.key=side=='left' and 'f' or 'j' end
  local key=K.positions[p.key];local down=(s.pressed[p.key] or s.flash[p.key]) and 1 or 0
  p.x=C.approach(p.x,key.x+key.width/2,math.min(dt,.5),1/38);p.y=C.approach(p.y,key.y+15,math.min(dt,.5),1/38);p.down=C.approach(p.down,down,math.min(dt,.5),1/38)
  miucs.set(side..'-hoof',{x=p.x-24,y=p.y-8*(1-p.down),scaleY=1-p.down*.06})
 end
 return s
end
return K
