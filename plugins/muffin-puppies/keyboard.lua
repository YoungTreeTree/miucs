local I=miucs.require('ink.lua')
local K={keys=miucs.require('keys.lua'),positions={}}
for _,k in ipairs(K.keys) do K.positions[k.key]=k end
local modifiers={leftShift=1,rightShift=1,leftControl=2,rightControl=2,leftOption=4,rightOption=4,leftCommand=8,rightCommand=8,['function']=32}
local left={grave=true,digit1=true,digit2=true,digit3=true,digit4=true,digit5=true,
  tab=true,capsLock=true,leftShift=true,leftControl=true,leftOption=true,leftCommand=true,['function']=true}
for key in ('q w e r t a s d f g z x c v b'):gmatch('%S+') do left[key]=true end
local function approach(v,t,dt) return v+(t-v)*(1-math.exp(-dt*38)) end
function K.scene()
  local nodes={}
  local function add(n) nodes[#nodes+1]=n end
  for i,x in ipairs({100,660}) do add(I.box('hinge-'..i,x,163,38,29,'#B0CFB8',2.5)) end
  add(I.shape('monitor',I.rounded(24,4,752,172,7),'#ACCCB5',3.5,44,6))
  add(I.shape('paper',I.rounded(36,16,728,148,3),'#FFF9EE',2.7,48,5.5))
  add(I.shape('case',{{28,188},{772,188},{793,399},{784,414},{16,414},{7,399}},'#96BCA6',3.6,39,6))
  add(I.shape('deck',{{33,192},{767,192},{784,398},{16,398}},'#B1CFB8',2.2,44,5))
  for _,k in ipairs(K.keys) do
    local fill=#k.label>1 and '#E7DFEF' or '#FFF9EE'
    add({type='rect',id='key-shadow-'..k.key,x=k.x+1,y=k.y+4,width=k.width-2,height=31,radius=5,fill='#7D918A'})
    local key=I.box('key-'..k.key,0,0,k.width,30,fill,1.8)
    key.x=k.x;key.y=k.y;add(key)
    add({type='text',id='label-'..k.key,x=k.x+k.width/2-#k.label*(#k.label>3 and 2.5 or 3),y=k.y+5,
      text=k.label,font='assets/NotoSans-Regular.ttf',fontSize=#k.label>3 and 10 or 12,fill=I.color})
  end
  for _,side in ipairs({'left','right'}) do
    local points={{8,1},{13,-1},{17,2},{22,0},{26,4},{31,5},{32,11},{36,16},{33,23},
      {34,29},{29,34},{26,39},{19,38},{14,40},{9,36},{4,35},{2,29},{3,22},{0,17},{3,12},{2,6}}
    local paw=I.shape(side..'-paw',I.smooth(points),side=='left' and '#FFFDF5' or '#F7D29B',2.4,16,4.7)
    paw.width=36;paw.height=40;paw.pivot={.5,.2};paw.rotation=side=='left' and -.12 or .12;paw.z=20
    add(paw)
  end
  return nodes
end
function K.reset()
  K.state={session=nil,cursor=0,time=0,pressed={},observed={},modHeld={},flash={},lit={},spaceLeft=true}
  for _,side in ipairs({'left','right'}) do
    local key=side=='left' and 'f' or 'j';local p=K.positions[key]
    K.state[side]={key=key,x=p.x+p.width/2,y=p.y+15,down=0}
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
      s[side].key=key;s.flash[key]=s.time+.10;hits[side]=true
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
      miucs.set('key-'..k.key..'-fill',{fill=lit and '#F0AF96' or (#k.label>1 and '#E7DFEF' or '#FFF9EE')})
      miucs.set('key-'..k.key,{y=k.y+(lit and 3 or 0)})
      miucs.set('label-'..k.key,{y=k.y+(lit and 8 or 5)})
    end
  end
  for _,side in ipairs({'left','right'}) do
    local p=s[side]
    if not live then p.key=side=='left' and 'f' or 'j' end
    local k=K.positions[p.key]
    local down=(s.pressed[p.key] or s.flash[p.key]) and 1 or 0
    p.x=approach(p.x,k.x+k.width/2,dt);p.y=approach(p.y,k.y+15,dt);p.down=approach(p.down,down,dt)
    miucs.set(side..'-paw',{x=p.x-18,y=p.y-(1-p.down)*8,scaleY=1-p.down*.09})
  end
  hits.live=not not live;hits.reset=changed or dt>.5 or not live or (input and (input.droppedEventCount or 0)>0)
  return hits
end
return K
