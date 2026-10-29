local C=miucs.require("common.lua")
local T={}
function T.reset()
  T.amplitude,T.phase,T.count,T.cursor=0,0,0,0;T.session=nil
  T.sinceBeat,T.sinceOnset=100,100;T.period,T.desired=.5,.5;T.strength,T.onsetStrength=0,0
  T.sampleRate,T.channels,T.audioTime=nil,nil,nil
end
T.reset()
function T.update(dt,input)
  input=input or {};if T.session~=input.sessionID then T.reset();T.session=input.sessionID end
  T.sinceBeat=T.sinceBeat+dt;T.sinceOnset=T.sinceOnset+dt
  local audio,frame=C.audio(input);local beat,onset=nil,nil
  if audio then
    if T.sampleRate and (T.sampleRate~=audio.sampleRate or T.channels~=audio.channelCount or audio.time<T.audioTime) then T.cursor=frame.sequence;T.sinceBeat=100;T.sinceOnset=100 end
    T.sampleRate,T.channels,T.audioTime=audio.sampleRate,audio.channelCount,audio.time
    local now=frame.receivedAt+input.frameAge
    for _,e in ipairs(input.beats or {}) do
      if C.fresh(e,now,T.cursor,frame.sequence,.15) and e.bpm>=50 and e.bpm<=200 and e.confidence>=.45 and e.confidence<=1 and e.strength>=0 and e.strength<=1 then beat=e end
    end
    if not beat and T.sinceBeat>math.max(.9,T.desired*1.5) and T.sinceOnset>=.12 then
      for _,e in ipairs(input.onsets or {}) do if C.fresh(e,now,T.cursor,frame.sequence,.15) and e.strength>=.18 and e.strength<=1 then onset=e end end
    end
    T.cursor=math.max(T.cursor,frame.sequence)
    if beat then T.desired=60/beat.bpm;if T.count==0 then T.period=T.desired end;T.count=T.count+1;T.sinceBeat=now-beat.receivedAt;T.strength=.88+.12*beat.strength;T.sinceOnset=100
    elseif onset then T.sinceOnset=now-onset.receivedAt;T.onsetStrength=.55+.30*math.sqrt(onset.strength) end
  else T.cursor=math.max(T.cursor,(input.frame or {}).sequence or 0) end
  local b=audio and T.sinceBeat<=math.max(.9,T.desired*1.5)
  local o=audio and not b and T.sinceOnset<=.42
  local engaged=b or o;local step=(beat or onset) and math.min(dt,.05) or dt
  T.period=C.approach(T.period,T.desired,step,.14)
  T.amplitude=C.approach(T.amplitude,b and T.strength or (o and T.onsetStrength or 0),step,engaged and .055 or .08)
  if not engaged and T.amplitude<.025 then T.amplitude=0 end
  if T.amplitude>0 then T.phase=(T.phase+math.pi*step/T.period)%(2*math.pi) end
  local level=C.clamp(math.floor(T.amplitude*4+.5),0,4)
  return level==0 and 0 or 1+(level-1)*64+math.floor(T.phase/(2*math.pi)*64)%64
end
return T
