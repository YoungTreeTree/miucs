-- Independent input sessions and bounded effects. Time is always host-monotonic.
local M={}
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
-- Only a frame clock: the model drew the trajectory, body deformation and shadows.
local durations={.025,.045,.055,.035,.035,.04,.045,.06,.05,.04,.035,.04,.05,.05,.045,.04}
local duration=0
for _,seconds in ipairs(durations) do duration=duration+seconds end
local function dog() return {age=10,pending=0,frame=1,count=0} end
function M.new()
  return {time=0,left=dog(),right=dog(),audioSession=nil,audioCursor=0,
    breath=10,bubbles={},slot=0,beatCount=0,audioTime=nil}
end
local function jump(d,hit,dt,time,reset)
  if reset then d.pending=0 end
  d.age=d.age+dt
  if hit then
    if d.age>=duration then d.age=0;d.count=d.count+1 else d.pending=time+.16 end
  elseif d.age>=duration and d.pending>time then
    d.age=0;d.pending=0;d.count=d.count+1
  end
  d.frame=1
  local endTime=0
  for i,seconds in ipairs(durations) do
    endTime=endTime+seconds
    if d.age<endTime then d.frame=i;break end
  end
end
function M.update(s,frame,hits)
  local dt=clamp(frame.deltaTime or 0,0,60)
  local now=frame.now or s.time+dt
  s.time=s.time+dt;s.breath=s.breath+dt
  local input=frame.audio or {};local f=input.frame or {};local a=f.audio or {}
  if s.audioSession~=input.sessionID then
    s.audioSession=input.sessionID;s.audioCursor=0;s.breath=10;s.bubbles={};s.audioTime=nil
  end
  local through=f.sessionID==input.sessionID and (f.sequence or 0) or 0
  if dt>.5 then
    s.left=dog();s.right=dog();s.bubbles={};s.breath=10;s.audioCursor=math.max(s.audioCursor,through)
    return s
  end
  jump(s.left,hits.left,dt,s.time,hits.reset)
  jump(s.right,hits.right,dt,s.time,hits.reset)
  -- Finish existing bubbles even when the audio disconnects; no new bubbles without beats.
  for i,b in pairs(s.bubbles) do
    b.age=b.age+dt
    if b.age>=1.85 then s.bubbles[i]=nil end
  end
  local age=input.frameAge
  local live=input.state=='running' and f.sessionID==input.sessionID and age and age>=0 and age<.4
    and a.isSilent==false and now-(f.receivedAt or -1e9)>=-.05 and now-(f.receivedAt or -1e9)<=.45
  local discontinuity=live and s.audioTime and (a.time<s.audioTime or a.sampleRate~=s.sampleRate or a.channelCount~=s.channelCount)
  if discontinuity then s.audioCursor=math.max(s.audioCursor,through);s.breath=10 end
  if live then
    s.audioTime=a.time;s.sampleRate=a.sampleRate;s.channelCount=a.channelCount
    local reference=math.max(now,math.min(now+.05,(f.receivedAt or now)+age))
    local accepted=nil
    for _,e in ipairs(input.beats or {}) do
      local seq=e.sequence or 0;local lag=reference-(e.receivedAt or -1e9)
      if seq>s.audioCursor and seq<=through then
        s.audioCursor=seq
        if lag>=0 and lag<=.25 and (e.confidence or 0)>=.45 and (e.confidence or 2)<=1
            and (e.bpm or 0)>=50 and (e.bpm or 0)<=200 and (e.strength or -1)>=0 and (e.strength or 2)<=1 then
          accepted=e
        end
      end
    end
    -- Coalesced events produce one fresh bubble, never a burst replay of old beats.
    if accepted and (input.droppedBeatCount or 0)==0 then
      s.slot=s.slot%8+1;s.beatCount=s.beatCount+1
      s.bubbles[s.slot]={age=0,radius=8+accepted.strength*6,phase=s.beatCount*1.7}
      s.breath=0
    end
  end
  s.audioCursor=math.max(s.audioCursor,through)
  return s
end
return M
