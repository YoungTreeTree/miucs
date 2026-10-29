local active = false
local radius = 24
return {
  create = function(context)
    miucs.load(miucs.require("scene.lua"))
  end,
  activate = function(viewport)
    active = viewport.id == "example-pulse"
    radius = 24
  end,
  update = function(frame)
    if not active then return end
    local input = frame.audio
    local envelope = 0
    if input and input.state == "running" and input.frame and input.frameAge and input.frameAge < .4 then
      envelope = input.frame.audio.envelope
    end
    local target = 24 + math.min(1, math.max(0, envelope) * 8) * 28
    radius = radius + (target - radius) * (1 - math.exp(-frame.deltaTime / .08))
    if math.abs(radius - target) < .001 then radius = target end
    miucs.set("pulse", {width=radius*2, height=radius*2, x=120-radius, y=80-radius})
  end,
  resize = function(viewport) end, -- Root logical coordinates are fitted by the renderer.
  appearanceChanged = function(appearance)
    miucs.set("pulse", {fill=appearance.ink or "#3d3d3d"})
  end,
  deactivate = function() active = false end,
  dispose = function() active = false end
}
