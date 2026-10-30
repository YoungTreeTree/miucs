-- Character transforms never animate: motion is drawn into the source frames.
-- Keyboard and audio have independent sessions. All ages use host time.
local M={}
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local clips={
  slash={frames={1,2,3,4,5,6,7,8},times={.025,.045,.045,.035,.05,.055,.06,.045}},
  guard={frames={9,10,11,12,13,14,15,16},times={.025,.035,.045,.055,.065,.055,.05,.04}},
}
for _,c in pairs(clips) do c.duration=0;for _,t in ipairs(c.times) do c.duration=c.duration+t end end
local function actor() return {age=10,frame=1,clip='slash',pending=nil,expires=0} end
local function audioReset(s)
  s.shotAge=10;s.guardianFrame=1;s.beam=0;s.charge=0;s.lastBeat=nil
  s.audioTime=nil;s.period=nil
end
function M.new()
  local s={time=0,link=actor(),audioSession=nil,audioCursor=0,shotCount=0}
  audioReset(s);return s
end
local function playLink(s,hits,dt)
  local d=s.link
  if hits.reset then s.link=actor();d=s.link end
  d.age=d.age+dt
  -- A simultaneous chord is one guard; no double animation or unbounded queue.
  local nextClip=hits.right and 'guard' or (hits.left and 'slash' or nil)
  if nextClip then
    if d.age>=clips[d.clip].duration then
      d.clip=nextClip;d.age=0;d.pending=nil
    else d.pending=nextClip;d.expires=s.time+.18 end
  elseif d.age>=clips[d.clip].duration then
    if d.pending and d.expires>=s.time then d.clip=d.pending;d.age=0 end
    d.pending=nil
  end
  d.frame=1
  local endTime=0
  local c=clips[d.clip]
  for i,t in ipairs(c.times) do
    endTime=endTime+t
    if d.age<endTime then d.frame=c.frames[i];break end
  end
end
function M.update(s,frame,hits)
  local dt=clamp(frame.deltaTime or 0,0,60)
  local now=frame.now or s.time+dt
  s.time=s.time+dt
  local input=frame.audio or {};local f=input.frame or {};local a=f.audio or {}
  if s.audioSession~=input.sessionID then
    s.audioSession=input.sessionID;s.audioCursor=0;audioReset(s)
  end
  local through=f.sessionID==input.sessionID and (f.sequence or 0) or 0
  if dt>.5 then
    s.link=actor();audioReset(s);s.audioCursor=math.max(s.audioCursor,through)
    return s
  end
  playLink(s,hits,dt)
  s.shotAge=s.shotAge+dt
  local age=input.frameAge
  local live=input.state=='running' and f.sessionID==input.sessionID and age and age>=0 and age<.4
    and a.isSilent==false and type(a.time)=='number'
    and now-(f.receivedAt or -1e9)>=-.05 and now-(f.receivedAt or -1e9)<=.45
  local discontinuity=live and s.audioTime and (a.time<s.audioTime or a.sampleRate~=s.sampleRate or a.channelCount~=s.channelCount)
  if discontinuity then s.audioCursor=math.max(s.audioCursor,through);audioReset(s) end
  if live then
    s.audioTime=a.time;s.sampleRate=a.sampleRate;s.channelCount=a.channelCount
    local reference=math.max(now,math.min(now+.05,(f.receivedAt or now)+age))
    local accepted=nil
    for _,e in ipairs(input.beats or {}) do
      local seq=e.sequence or 0;local lag=reference-(e.receivedAt or -1e9)
      if seq>s.audioCursor and seq<=through then
        s.audioCursor=seq
        if lag>=0 and lag<=.25 and (e.confidence or 0)>=.45 and (e.confidence or 2)<=1
            and (e.bpm or 0)>=50 and (e.bpm or 0)<=200 and (e.strength or -1)>=0 and (e.strength or 2)<=1 then accepted=e end
      end
    end
    if accepted and (input.droppedBeatCount or 0)==0 then
      s.shotAge=0;s.shotCount=s.shotCount+1;s.lastBeat=s.time
      s.period=60/accepted.bpm;s.strength=accepted.strength
    end
  else
    -- Silence/disconnect removes the laser immediately; keyboard keeps working.
    audioReset(s)
  end
  s.audioCursor=math.max(s.audioCursor,through)
  s.beam=0;s.charge=0;s.guardianFrame=1
  -- Fire/recoil frames 9..16 begin on the actual beat, never an extrapolated beat.
  if s.shotAge<.28 then
    s.guardianFrame=9+math.min(7,math.floor(s.shotAge/.035))
    if s.shotAge<.13 then s.beam=(1-s.shotAge/.13)^.65 end
  elseif live and s.lastBeat and s.period then
    -- One predicted windup only; a missing beat can never fire or keep looping.
    local untilBeat=s.period-(s.time-s.lastBeat)
    if untilBeat>=0 and untilBeat<.20 then
      s.charge=1-untilBeat/.20
      s.guardianFrame=2+math.min(6,math.floor(s.charge*7))
    end
  end
  return s
end
return M
