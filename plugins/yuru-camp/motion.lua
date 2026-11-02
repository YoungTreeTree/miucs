-- Original drawn poses, fixed world anchors. No procedural character movement.
local M={}
local times={
  eat={.04,.06,.08,.08,.08,.10,.13,.12,.08,.07,.06,.05},
  sip={.08,.10,.12,.14,.18,.18,.16,.18,.14,.12,.10,.10},
}
local durations={}
for name,list in pairs(times) do
  durations[name]=0;for _,t in ipairs(list) do durations[name]=durations[name]+t end
end
local function actor() return {age=10,frame=1,pending=0} end
local function pose(age,list)
  local endTime=0
  for i,t in ipairs(list) do endTime=endTime+t;if age<endTime then return i end end
  return 1
end
local function resetAudio(s)
  s.rin=actor();s.fireAge=10;s.fireFrame=1;s.fireDuration=.36
  s.beatCount=0;s.audioTime=nil;s.lastBeat=nil
end
function M.new()
  local s={time=0,nadeshiko=actor(),audioSession=nil,audioCursor=0}
  resetAudio(s);return s
end
local function eat(s,hits,dt)
  if hits.reset then s.nadeshiko=actor() end
  local d=s.nadeshiko;d.age=d.age+dt
  if hits.left or hits.right then
    if d.age>=durations.eat then d.age=0;d.pending=0
    else d.pending=s.time+.20 end
  elseif d.age>=durations.eat and d.pending>0 then
    if d.pending>=s.time then d.age=0 end
    d.pending=0
  end
  d.frame=pose(d.age,times.eat)
end
function M.update(s,frame,hits)
  local dt=math.max(0,math.min(60,frame.deltaTime or 0))
  local now=frame.now or s.time+dt;s.time=s.time+dt
  local input=frame.audio or {};local f=input.frame or {};local a=f.audio or {}
  if s.audioSession~=input.sessionID then
    s.audioSession=input.sessionID;s.audioCursor=0;resetAudio(s)
  end
  local through=f.sessionID==input.sessionID and (f.sequence or 0) or 0
  if dt>.5 then
    s.nadeshiko=actor();resetAudio(s);s.audioCursor=math.max(s.audioCursor,through)
    return s
  end
  eat(s,hits,dt)
  s.rin.age=s.rin.age+dt;s.fireAge=s.fireAge+dt
  local age=input.frameAge
  local live=input.state=='running' and f.sessionID==input.sessionID and age and age>=0 and age<.4
    and a.isSilent==false and type(a.time)=='number'
    and now-(f.receivedAt or -1e9)>=-.05 and now-(f.receivedAt or -1e9)<=.45
  local discontinuity=live and s.audioTime and (a.time<s.audioTime or a.sampleRate~=s.sampleRate or a.channelCount~=s.channelCount)
  if discontinuity then s.audioCursor=math.max(s.audioCursor,through);resetAudio(s) end
  if live then
    s.audioTime=a.time;s.sampleRate=a.sampleRate;s.channelCount=a.channelCount
    local reference=math.max(now,math.min(now+.05,(f.receivedAt or now)+age))
    local accepted=nil
    for _,e in ipairs(input.beats or {}) do
      local seq=e.sequence or 0;local lag=reference-(e.receivedAt or -1e9)
      if seq>s.audioCursor and seq<=through then
        s.audioCursor=seq
        if lag>=0 and lag<=.25 and (e.confidence or 0)>=.45 and (e.confidence or 2)<=1
            and (e.bpm or 0)>=50 and (e.bpm or 0)<=200
            and (e.strength or -1)>=0 and (e.strength or 2)<=1 then accepted=e end
      end
    end
    if accepted and (input.droppedBeatCount or 0)==0 then
      if s.lastBeat and s.time-s.lastBeat>2.0 then s.beatCount=0 end
      s.lastBeat=s.time;s.beatCount=s.beatCount+1;s.fireAge=0
      -- Finish eight drawn flame poses before the next beat even at 200 BPM.
      s.fireDuration=math.min(.36,60/accepted.bpm*.85)
      if (s.beatCount-1)%4==0 and s.rin.age>=durations.sip then s.rin.age=0 end
    end
  else
    -- Audio loss affects only Rin/fire; keyboard animation is independent.
    resetAudio(s)
  end
  s.audioCursor=math.max(s.audioCursor,through)
  s.rin.frame=pose(s.rin.age,times.sip)
  s.fireFrame=s.fireAge<s.fireDuration and math.min(8,1+math.floor(s.fireAge/s.fireDuration*8)) or 1
  return s
end
return M
