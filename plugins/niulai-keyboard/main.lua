local keyboard=miucs.require("keyboard.lua")
local motion=miucs.require("motion.lua")
local rider=miucs.require("rider.lua")
local active=false
local state=motion.new({})
local pose=rider.new()
local lastSource,lastIndex
local function reset()
 state=motion.new({});pose=rider.new();keyboard.reset();lastSource=nil;lastIndex=nil
end
local function draw()
 local source="assets/"..pose.mode..".png"
 if source~=lastSource or pose.frame~=lastIndex then
  miucs.set("niulai-rider",{source=source,sourceRect={(pose.frame%4)*220,math.floor(pose.frame/4)*220,220,220}})
  lastSource=source;lastIndex=pose.frame
 end
 -- No rotating/stretching the entire cow. Poses supply actual joint movement.
 -- Quiet inputs leave a neutral pose; only snow translates while input is active.
 local live=state.activity>.02
 for i=1,10 do
  local t=(state.drift/95+i/10)%1
  miucs.set("snow-"..i,{x=70+(1-t)*650,y=129+(i%3)*5,opacity=live and .22*(1-t) or 0})
 end
end
return {
 create=function()
  local root={type="group",id="niulai-keyboard",width=800,height=460,children=keyboard.scene()}
  root.children[#root.children+1]={type="group",id="snow-screen",clip={40,14,720,144},z=8,children={}}
  local n=root.children[#root.children].children
  n[#n+1]={type="rect",id="snow-ground",x=49,y=143,width=702,height=3,fill="#E8DCC6"}
  for i=1,10 do n[#n+1]={type="rect",id="snow-"..i,x=0,y=0,width=4,height=2,fill="#C5B8D1",opacity=0,antialias=false} end
  n[#n+1]={type="image",id="niulai-rider",source="assets/carve.png",sourceRect={660,0,220,220},x=322,y=0,width=155,height=155,sampling="nearest"}
  miucs.load(root);reset();draw()
 end,
 activate=function(viewport) active=true;reset();draw() end,
 update=function(frame)
  if not active then return end
  keyboard.update(frame)
  motion.update(state,frame)
  if (frame.deltaTime or 0)>.5 then pose=rider.new() else rider.update(pose,state,frame.deltaTime or 0) end
  draw()
 end,
 appearanceChanged=function(a) miucs.set("niulai-keyboard",{opacity=a.opacity or 1}) end,
 resize=function() end,
 deactivate=function() active=false;reset() end,
 dispose=function() active=false;reset() end,
}
