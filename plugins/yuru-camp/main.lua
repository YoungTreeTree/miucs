local K=miucs.require('keyboard.lua')
local M=miucs.require('motion.lua')
local S=miucs.require('scene.lua')
local active=false
local state=M.new()
local function reset()
  K.reset();state=M.new()
  K.update({now=0,deltaTime=0});S.update(state)
end
return {
  create=function() miucs.load(S.create());reset() end,
  activate=function(viewport) active=viewport.id=='yuru-camp';reset() end,
  update=function(frame)
    if active then S.update(M.update(state,frame,K.update(frame))) end
  end,
  appearanceChanged=function(a) miucs.set('yuru-camp',{opacity=a.opacity or 1}) end,
  resize=function() end,
  deactivate=function() active=false;reset() end,
  dispose=function() active=false end
}
