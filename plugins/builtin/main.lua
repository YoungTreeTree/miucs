local head=miucs.require("head.lua")
local tail=miucs.require("tail.lua")
local keyboard=miucs.require("keyboard.lua")
local staff=miucs.require("staff.lua")
local flight=miucs.require("flight.lua")
local active=nil
local lastTail=-1
return {
  create=function(context)
    miucs.load(keyboard.scene());miucs.load(staff.scene());miucs.load(flight.scene())
    miucs.load {type="group",id="tray",width=64,height=64,children={
      {type="image",id="tray-head",source="assets/cat-head.png",x=1,y=1,width=62,height=62,pivot={.5,.88},sampling="nearest"}
    }}
  end,
  activate=function(viewport)
    active=viewport.id
    if active=="pixel-keyboard" then keyboard.reset();tail.reset();lastTail=-1
    elseif active=="staff-note" then staff.reset()
    elseif active=="pencil-flight" then flight.reset()end
  end,
  update=function(frame)
    local angle=head.update(frame.deltaTime,frame.keyboard)
    miucs.set("keyboard-head",{rotation=angle});miucs.set("tray-head",{rotation=angle})
    if active=="pixel-keyboard" then
      keyboard.update(frame.deltaTime,frame.keyboard)
      local index=tail.update(frame.deltaTime,frame.audio)
      if index~=lastTail then miucs.set("keyboard-tail",{sourceRect={(index%16)*96,math.floor(index/16)*88,96,88}});lastTail=index end
    elseif active=="staff-note" then staff.update(frame)
    elseif active=="pencil-flight" then flight.update(frame)end
  end,
  appearanceChanged=function(appearance)
    local ink=appearance.ink or "#3d3d3d";staff.appearance(ink);flight.appearance(ink)
    local opacity=appearance.opacity or 1
    for _,id in ipairs({"staff-note","pixel-keyboard","pencil-flight"})do miucs.set(id,{opacity=opacity})end
  end,
  resize=function(viewport)end,
  deactivate=function()active=nil;staff.reset();keyboard.reset();tail.reset()end,
  dispose=function()active=nil;head.reset();staff.reset();keyboard.reset();tail.reset();flight.reset()end
}
