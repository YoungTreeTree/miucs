-- Input-driven frame clocks. No rotation of a flat character image and no
-- unbounded queue: rapid input changes cadence but cannot restart a slash.
local M={}
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local weights={.06,.10,.10,.10,.06,.06,.08,.10,.10,.08,.08,.08}
local function sword() return {age=1,duration=.7,pending=0,frame=1} end
local function dancer() return {phase=0,speed=1,target=1,untilTime=0,active=false,frame=1,pulse=1} end
function M.new()
  return {time=0,heiji=sword(),kazuha=dancer(),audioSession=nil,audioCursor=0,audioTime=nil}
end
local function swing(s,hits,dt)
  if hits.reset then s.heiji=sword() end
  local h=s.heiji
  h.age=h.age+dt
  if hits.count>0 then h.pending=s.time+.22 end
  if h.age>=h.duration and h.pending>s.time then
    h.duration=clamp(.76-.036*hits.rate,.30,.72)
    h.age=0;h.pending=0
  end
  h.frame=1
  if h.age<h.duration then
    local progress=h.age/h.duration
    local through=0
    for i,w in ipairs(weights) do
      through=through+w
      if progress<through then h.frame=i;break end
    end
  end
end
function M.update(s,frame,hits)
  local dt=clamp(frame.deltaTime or 0,0,60)
  local now=frame.now or s.time+dt
  s.time=s.time+dt
  local input=frame.audio or {};local f=input.frame or {};local a=f.audio or {}
  if s.audioSession~=input.sessionID then
    s.audioSession=input.sessionID;s.audioCursor=0;s.audioTime=nil;s.kazuha=dancer()
  end
  local through=f.sessionID==input.sessionID and (f.sequence or 0) or 0
  if dt>.5 then
    s.heiji=sword();s.kazuha=dancer();s.audioCursor=math.max(s.audioCursor,through)
    return s
  end
  swing(s,hits,dt)
  local age=input.frameAge
  local live=input.state=='running' and f.sessionID==input.sessionID and age and age>=0 and age<.4
    and a.isSilent==false and now-(f.receivedAt or -1e9)>=-.05 and now-(f.receivedAt or -1e9)<=.45
  local discontinuity=live and s.audioTime and
    (a.time<s.audioTime or a.sampleRate~=s.sampleRate or a.channelCount~=s.channelCount)
  if discontinuity then s.kazuha=dancer();s.audioCursor=math.max(s.audioCursor,through) end
  local accepted=nil
  if live then
    s.audioTime=a.time;s.sampleRate=a.sampleRate;s.channelCount=a.channelCount
    local reference=math.max(now,math.min(now+.05,(f.receivedAt or now)+age))
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
  end
  s.audioCursor=math.max(s.audioCursor,through)
  local d=s.kazuha;d.pulse=d.pulse+dt
  if accepted and (input.droppedBeatCount or 0)==0 then
    d.target=accepted.bpm/120 -- two beats per complete turn
    if not d.active then d.phase=0;d.speed=d.target end
    d.active=true;d.untilTime=s.time+1.35*60/accepted.bpm;d.pulse=0
  end
  if not live or (input.droppedBeatCount or 0)>0 then d.untilTime=0 end
  if d.active then
    d.speed=d.speed+(d.target-d.speed)*(1-math.exp(-dt*8))
    local nextPhase=d.phase+dt*d.speed
    -- Finish at the next front pose after silence/beat loss; never loop on a
    -- stale BPM snapshot. Fresh beats extend the run without resetting phase.
    if s.time>d.untilTime and nextPhase>=1 then
      d.active=false;d.phase=0;d.frame=1
    else
      d.phase=nextPhase%1;d.frame=math.min(8,math.floor(d.phase*8)+1)
    end
  else d.frame=1 end
  return s
end
return M
