local C=miucs.require("common.lua")
local K={keys=miucs.require("keys.lua"),positions={}}
for _,key in ipairs(K.keys) do K.positions[key.key]=key end
local palette={"#272330","#FFF9EE","#DCD6D9","#30303D","#484657"}
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
  for i,x in ipairs({100,660})do add(box("hinge"..i,x,164,40,28,"#393044"));add(box("hinge-inner"..i,x+5,166,30,22,"#9A8FA8",2))end
  add(box("screen-outline",24,0,752,172,"#393044",8));add(box("screen-side",28,4,744,164,"#9A8FA8",6));add(box("screen-dark",34,10,732,152,"#62576F",4));add(C.rect("screen-paper",40,14,720,144,"#FBF7EF"))
  add(polygon("keyboard-case",{{28,184},{772,184},{800,402},{790,418},{10,418},{0,402}},"#393044"))
  add(polygon("keyboard-side",{{32,188},{768,188},{792,400},{784,412},{16,412},{8,400}},"#62576F"))
  add(polygon("keyboard-top",{{34,188},{766,188},{786,398},{14,398}},"#9A8FA8"));add(C.rect("keyboard-shine",38,188,724,3,"#BFB5CA"))
  for _,k in ipairs(K.keys) do
    add(box("key-border-"..k.key,k.x,k.y,k.width,34,"#393044",3))
    add(box("key-side-"..k.key,k.x+2,k.y+2,k.width-4,30,"#A49AAF",2))
    local n=box("key-top-"..k.key,3,1,k.width-6,26,#k.label>1 and "#DBD3E4" or "#FBF7EF",2);n.x=k.x;n.y=k.y;add(n)
    add {type="text",id="key-label-"..k.key,x=k.x+k.width/2-#k.label*3,y=k.y+5,text=k.label,font="assets/NotoSans-Regular.ttf",fontSize=#k.label>3 and 10 or 12,fill="#393044"}
  end
  local rows=miucs.require("paw.lua")
  for _,side in ipairs({"left","right"}) do
    local children={}
    for color=1,5 do
      local path={}
      for y,row in ipairs(rows)do for x=1,#row do if tonumber(row:sub(x,x))==color then
        local xx,yy=(x-1)*2+2,(y-1)*2+2
        for _,cmd in ipairs({{"M",xx,yy},{"L",xx+2,yy},{"L",xx+2,yy+2},{"L",xx,yy+2},{"Z"}})do path[#path+1]=cmd end
      end end end
      children[#children+1]={type="path",id=side.."-paw-"..color,path=path,fill=palette[color],antialias=false}
    end
    add {type="group",id=side.."-paw",x=0,y=0,width=48,height=68,pivot={.5,0},rotation=side=="left" and -.12 or .12,z=10,children=children}
  end
  add {type="image",id="keyboard-head",x=44,y=54,width=64,height=64,source="assets/cat-head.png",sampling="nearest",pivot={.5,.88},z=10}
  add {type="image",id="keyboard-tail",x=640,y=42,width=96,height=88,source="assets/tail-atlas.png",sourceRect={0,0,96,88},sampling="nearest",z=10}
  return {type="group",id="pixel-keyboard",width=800,height=460,children=nodes}
end
function K.reset()
  K.session=nil;K.cursor=0;K.elapsed=0;K.flashes={};K.pressed={};K.observed={};K.spaceLeft=true;K.litCache={}
  K.left={key="f",x=K.positions.f.x+K.positions.f.width/2,y=K.positions.f.y+15,down=0}
  K.right={key="j",x=K.positions.j.x+K.positions.j.width/2,y=K.positions.j.y+15,down=0}
end
K.reset()
local modifier={leftShift=1,rightShift=1,leftControl=2,rightControl=2,leftOption=4,rightOption=4,leftCommand=8,rightCommand=8,["function"]=32}
function K.update(dt,input)
  K.elapsed=K.elapsed+dt
  for key,expiry in pairs(K.flashes)do if expiry<=K.elapsed then K.flashes[key]=nil end end
  local function strike(key)
    local p=K.positions[key];if not p then return end
    K.flashes[key]=K.elapsed+.12
    local left=key=="space" and K.spaceLeft or (key~="space" and p.x+p.width/2<400)
    if key=="space" then K.spaceLeft=not K.spaceLeft end
    if left then K.left.key=key else K.right.key=key end
  end
  if input then
    if K.session~=input.sessionID then K.reset();K.session=input.sessionID end
    if input.state~="running" or (input.droppedEventCount or 0)>0 then K.observed={};K.pressed={};K.flashes={} end
    if input.state=="running" then
      for _,e in ipairs(input.events or {})do
        local key=e.key
        if key and K.positions[key] and C.fresh(e,input.sampledAt,K.cursor,input.sequence,.25) then
          if e.kind=="pressed" and not K.observed[key] then K.observed[key]=true;strike(key)
          elseif e.kind=="released" then K.observed[key]=nil
          elseif e.kind=="modifiersChanged" then
            if key=="capsLock" then strike(key)
            elseif e.modifierIsPressed then K.observed[key]=true;strike(key)
            elseif e.modifierIsPressed==false then K.observed[key]=nil end
          end
        end
      end
      local held={};for _,k in ipairs(input.heldKeys or {})do if k.key then held[k.key]=true end end
      K.pressed={}
      for key in pairs(K.observed)do
        local down=modifier[key] and ((input.modifiers or 0)&modifier[key])~=0 or (not modifier[key] and held[key])
        if down then K.pressed[key]=true else K.observed[key]=nil end
      end
    end
    K.cursor=math.max(K.cursor,input.sequence)
  else K.observed={};K.pressed={} end
  if not input or input.state~="running" then K.left.key="f";K.right.key="j" end
  for _,k in ipairs(K.keys)do
    local lit=not not (K.pressed[k.key] or K.flashes[k.key])
    if K.litCache[k.key]~=lit then
    K.litCache[k.key]=lit
    miucs.set("key-side-"..k.key,{fill=lit and "#B85863" or "#A49AAF"})
    miucs.set("key-top-"..k.key,{fill=lit and "#EF958C" or (#k.label>1 and "#DBD3E4" or "#FBF7EF"),y=k.y+(lit and 4 or 0)})
    miucs.set("key-label-"..k.key,{y=k.y+(lit and 9 or 5)})
    end
  end
  for _,side in ipairs({"left","right"})do
    local p=K[side];local key=K.positions[p.key];local down=(K.pressed[p.key] or K.flashes[p.key]) and 1 or 0
    p.x=C.approach(p.x,key.x+key.width/2,dt,1/38);p.y=C.approach(p.y,key.y+15,dt,1/38);p.down=C.approach(p.down,down,dt,1/38)
    if math.abs(p.down-down)<.01 then p.down=down end
    if math.abs(p.x-key.x-key.width/2)<.02 then p.x=key.x+key.width/2 end
    if math.abs(p.y-key.y-15)<.02 then p.y=key.y+15 end
    miucs.set(side.."-paw",{x=p.x-24,y=p.y-(1-p.down)*8,scaleY=1-p.down*.06})
  end
end
return K
