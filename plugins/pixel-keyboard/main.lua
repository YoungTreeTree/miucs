local head=miucs.require("head.lua")
local tail=miucs.require("tail.lua")
local keyboard=miucs.require("keyboard.lua")
local active=false
local lastTail=-1
local function reset() head.reset();keyboard.reset();tail.reset();lastTail=-1 end
return {
  create=function() miucs.load(keyboard.scene()) end,
  activate=function() active=true;reset() end,
  update=function(frame)
    if not active then return end
    miucs.set("keyboard-head",{rotation=head.update(frame.deltaTime,frame.keyboard)})
    keyboard.update(frame.deltaTime,frame.keyboard)
    local index=tail.update(frame.deltaTime,frame.audio)
    if index~=lastTail then miucs.set("keyboard-tail",{sourceRect={(index%16)*96,math.floor(index/16)*88,96,88}});lastTail=index end
  end,
  appearanceChanged=function(appearance) miucs.set("pixel-keyboard",{opacity=appearance.opacity or 1}) end,
  resize=function(viewport) end,
  deactivate=function() active=false;reset() end,
  dispose=function() active=false;reset() end
}
