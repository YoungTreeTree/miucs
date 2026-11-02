local I=miucs.require('ink.lua')
local K={keys=miucs.require('keys.lua'),positions={}}
for _,k in ipairs(K.keys) do K.positions[k.key]=k end
local modifiers={leftShift=1,rightShift=1,leftControl=2,rightControl=2,leftOption=4,rightOption=4,leftCommand=8,rightCommand=8,['function']=32}
local left={grave=true,digit1=true,digit2=true,digit3=true,digit4=true,digit5=true,
  tab=true,capsLock=true,leftShift=true,leftControl=true,leftOption=true,leftCommand=true,['function']=true}
for key in ('q w e r t a s d f g z x c v b'):gmatch('%S+') do left[key]=true end
local function keyFill(k)
  if #k.label<=1 then return '#FFF7E7' end
  return left[k.key] and '#B94D42' or '#8C9C73'
end
function K.scene()
  local nodes={}
  local function add(n)
    if n.fill and n.stroke then
      local fill={};for k,v in pairs(n) do fill[k]=v end
      fill.id=n.id..'-base';fill.stroke=nil;fill.strokeWidth=nil
      nodes[#nodes+1]=fill
    end
    nodes[#nodes+1]=n
  end
  for i,x in ipairs({100,660}) do add(I.box('hinge-'..i,x,163,38,29,'#405975',2.5)) end
  add(I.shape('monitor',I.rounded(24,4,752,172,7),'#293D59',3.5,44,6))
  add(I.shape('paper',I.rounded(36,16,728,148,3),'#FFF7E7',2.7,48,5.5))
  add(I.shape('case',{{28,188},{772,188},{793,399},{784,414},{16,414},{7,399}},'#2E4665',3.6,39,6))
  add(I.shape('deck',{{33,192},{767,192},{784,398},{16,398}},'#33485B',2.2,44,5))
  for _,k in ipairs(K.keys) do
    local fill=keyFill(k)
    add({type='rect',id='key-shadow-'..k.key,x=k.x+1,y=k.y+4,width=k.width-2,height=31,radius=5,fill='#46576C'})
    local key=I.box('key-'..k.key,0,0,k.width,30,fill,1.8)
    key.x=k.x;key.y=k.y;add(key)
    add({type='text',id='label-'..k.key,x=k.x+k.width/2-#k.label*(#k.label>3 and 2.5 or 3),y=k.y+5,
      text=k.label,font='assets/NotoSans-Regular.ttf',fontSize=#k.label>3 and 10 or 12,fill=(#k.label>1 and left[k.key]) and '#FFF2DD' or I.color})
  end
  -- Static bead, fang and woven corner ornaments; no moving overlay on keys.
  for _,x in ipairs({25,775}) do
    for i,y in ipairs({43,58,73,222,237,252}) do
      add({type='ellipse',id='bead-'..x..'-'..i,x=x-3.5,y=y,width=7,height=7,fill='#725486',stroke='#332C3B',strokeWidth=1})
      add({type='ellipse',id='bead-glint-'..x..'-'..i,x=x-1.5,y=y+1,width=2,height=2,fill='#EEE0D1'})
    end
    add({type='path',id='fang-'..x,path={{'M',x-3,82},{'Q',x-8,94,x,106},{'Q',x+3,91,x+3,82},{'Z'}},fill='#FFF3D9',stroke='#4A3B37',strokeWidth=1.2})
  end
  for i,v in ipairs({{27,7},{747,7},{19,401},{753,401}}) do
    add({type='rect',id='corner-'..i,x=v[1],y=v[2],width=24,height=10,fill='#B74D43',stroke='#E8CBA4',strokeWidth=1})
    add({type='path',id='diamond-'..i,path={{'M',v[1]+12,v[2]+2},{'L',v[1]+16,v[2]+5},{'L',v[1]+12,v[2]+8},{'L',v[1]+8,v[2]+5},{'Z'}},stroke='#F2DBB3',strokeWidth=1})
  end
  add({type='path',id='dog-ears',path={{'M',421,370},{'L',416,355},{'Q',423,356,429,362},{'Q',434,358,440,355},{'L',437,370}},stroke='#B94D42',strokeWidth=1.5})
  return nodes
end
function K.reset()
  K.state={session=nil,cursor=0,time=0,pressed={},observed={},modHeld={},flash={},lit={},spaceLeft=true}
  for _,side in ipairs({'left','right'}) do
    local key=side=='left' and 'f' or 'j';local p=K.positions[key]
    K.state[side]={key=key,x=p.x+p.width/2,y=p.y+15,down=0,age=10}
  end
end
K.reset()
function K.update(frame)
  local dt=math.max(0,frame.deltaTime or 0)
  local input=frame.keyboard
  local session=input and input.sessionID
  local changed=session~=K.state.session
  if changed then K.reset();K.state.session=session end
  local s=K.state;s.time=s.time+dt
  local hits={}
  local now=frame.now or 0
  local sampled=input and input.sampledAt or -1e9
  local live=input and input.state=='running' and now-sampled>=-.05 and now-sampled<=.4
  local through=input and input.sequence or 0
  for key,expiry in pairs(s.flash) do if expiry<=s.time then s.flash[key]=nil end end
  if not live or dt>.5 then
    s.flash={};s.pressed={};s.observed={};s.modHeld={};s.caps=false
  else
    local lost=(input.droppedEventCount or 0)>0
    if lost then s.flash={};s.observed={};s.modHeld={} end
    local cursor=s.cursor
    local function strike(key)
      local side=left[key] and 'left' or 'right'
      if key=='space' then side=s.spaceLeft and 'left' or 'right';s.spaceLeft=not s.spaceLeft end
      s[side].key=key;s[side].age=0;s.flash[key]=s.time+.12;hits[side]=true
    end
    for _,e in ipairs(input.events or {}) do
      local seq=e.sequence or 0
      if seq>cursor and seq<=through then
        cursor=seq
        local age=math.max(now,sampled)-(e.receivedAt or -1e9)
        local key=e.key
        if not lost and K.positions[key] and age>=0 and age<=.25 then
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
      miucs.set('key-'..k.key..'-fill',{fill=lit and '#EDB09A' or keyFill(k)})
      miucs.set('key-'..k.key,{y=k.y+(lit and 3 or 0)})
      miucs.set('label-'..k.key,{y=k.y+(lit and 8 or 5)})
    end
  end
  hits.live=not not live;hits.reset=changed or dt>.5 or not live or (input and (input.droppedEventCount or 0)>0)
  return hits
end
return K
