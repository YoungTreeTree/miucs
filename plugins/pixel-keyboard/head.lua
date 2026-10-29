local C=miucs.require("common.lua")
local H={}
function H.reset()
  H.frequency,H.amplitude,H.phase,H.angle=0,0,0,0
  H.session=nil;H.cursor=0;H.sampleTime=nil;H.sinceInput=100;H.sincePress=100;H.rate=0;H.armed=false
end
H.reset()
function H.update(dt,input)
  H.sinceInput=H.sinceInput+dt;H.sincePress=H.sincePress+dt
  local fresh=false
  if input then
    if H.session~=input.sessionID then H.reset();H.session=input.sessionID end
    if input.state~="running" or (input.droppedEventCount or 0)>0 or (H.sampleTime and input.sampledAt<H.sampleTime) then
      H.reset();H.session=input.sessionID;H.cursor=input.sequence;return H.angle
    end
    if not H.sampleTime or input.sampledAt>H.sampleTime then H.sinceInput=0;H.sampleTime=input.sampledAt;H.rate=C.clamp(input.pressesPerSecond or 0,0,6) end
    for _,e in ipairs(input.events or {}) do
      if e.kind=="pressed" and C.fresh(e,input.sampledAt,H.cursor,input.sequence,.25) then fresh=true;H.armed=true;H.sincePress=input.sampledAt-e.receivedAt end
    end
    H.cursor=math.max(H.cursor,input.sequence)
  end
  local active=H.armed and H.sinceInput<=.25 and H.rate>0 and H.sincePress<=math.max(.45,math.min(1.25,1.5/math.max(H.rate,1)))
  local step=fresh and math.min(dt,1/30) or dt
  if active then
    local target=.4*H.rate
    if H.amplitude==0 then H.frequency=target end
    H.frequency=C.approach(H.frequency,target,step,.18)
  end
  H.amplitude=C.approach(H.amplitude,active and 1 or 0,step,active and .12 or .18)
  if not active and H.amplitude<.002 then H.amplitude=0;H.frequency=0;H.phase=0;H.armed=false
  else H.phase=(H.phase+2*math.pi*H.frequency*step)%(2*math.pi) end
  H.angle=H.amplitude*math.sin(H.phase)*math.pi/15
  return H.angle
end
return H
