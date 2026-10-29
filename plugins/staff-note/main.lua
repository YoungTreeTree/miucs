local visual=miucs.require("staff.lua")
local active=false
return {
  create=function() miucs.load(visual.scene()) end,
  activate=function() active=true;visual.reset() end,
  update=function(frame) if active then visual.update(frame) end end,
  appearanceChanged=function(appearance)
    visual.appearance(appearance.ink or "#3d3d3d")
    miucs.set("staff-note",{opacity=appearance.opacity or 1})
  end,
  resize=function(viewport) end,
  deactivate=function() active=false;visual.reset() end,
  dispose=function() active=false;visual.reset() end
}
