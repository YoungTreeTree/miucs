-- Model-drawn poses only. A command owns all three actors until recovery finishes.
local M={}
local command={
  inuyasha={{1,.10},{5,.10},{6,.12},{7,.08},{8,.08},{9,.06},{10,.08},{11,.10},{12,.48},{13,.18},{14,.18},{15,.16},{16,.12}},
  kagome={{3,.10},{4,.12},{5,.10},{6,.08},{7,.08},{8,.14},{9,.42},{10,.14},{11,.18},{12,.12}},
  shippo={{1,.40},{3,.08},{4,.14},{5,.14},{6,.16},{7,.40},{8,.16}},
}
local boast={{3,.10},{4,.24},{5,.14},{16,.12}}
local duration=1.94
local function pose(age,list)
  local ending=0
  for _,v in ipairs(list) do ending=ending+v[2];if age<ending then return v[1] end end
  return 1
end
local function resetAudio(s)
  s.beatCount=0;s.audioTime=nil;s.lastBeat=nil
end
function M.new()
  local s={time=0,commandAge=10,boastAge=10,pending=0,audioSession=nil,audioCursor=0,
    inuyashaFrame=1,kagomeFrame=1,shippoFrame=1,dustFrame=1,dustVisible=false}
  resetAudio(s);return s
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
    s.commandAge=10;s.boastAge=10;s.pending=0;resetAudio(s)
    s.audioCursor=math.max(s.audioCursor,through)
    s.inuyashaFrame=1;s.kagomeFrame=1;s.shippoFrame=1;s.dustVisible=false
    return s
  end
  s.commandAge=s.commandAge+dt;s.boastAge=s.boastAge+dt
  if hits.reset then s.boastAge=10;s.pending=0 end
  if s.commandAge>=duration then
    if hits.left or hits.right then
      if s.boastAge>=.60 then s.boastAge=0;s.pending=0 else s.pending=s.time+.16 end
    elseif s.boastAge>=.60 and s.pending>0 then
      if s.pending>=s.time then s.boastAge=0 end
      s.pending=0
    end
  else s.pending=0 end
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
        if lag>=0 and lag<=.25 and (e.confidence or 0)>=.6 and (e.confidence or 2)<=1
            and (e.bpm or 0)>=50 and (e.bpm or 0)<=200
            and (e.strength or -1)>=.35 and (e.strength or 2)<=1 then accepted=e end
      end
    end
    if accepted and (input.droppedBeatCount or 0)==0 then
      if s.lastBeat and s.time-s.lastBeat>2 then s.beatCount=0 end
      s.lastBeat=s.time;s.beatCount=s.beatCount+1
      -- No queued commands; high BPM cannot interrupt a fall or recovery.
      if (s.beatCount-1)%4==0 and s.commandAge>=duration then
        s.commandAge=0;s.boastAge=10;s.pending=0
      end
    end
  else
    -- Finish an already-started physical action; silence never starts a new one.
    resetAudio(s)
  end
  s.audioCursor=math.max(s.audioCursor,through)
  s.dustVisible=s.commandAge>=.48 and s.commandAge<.84
  s.dustFrame=s.dustVisible and math.min(4,1+math.floor((s.commandAge-.48)/.09)) or 1
  if s.commandAge<duration then
    s.inuyashaFrame=pose(s.commandAge,command.inuyasha)
    s.kagomeFrame=pose(s.commandAge,command.kagome)
    s.shippoFrame=pose(s.commandAge,command.shippo)
  else
    -- Only a blink while idle; no autonomous falls, pointing or surprise.
    s.inuyashaFrame=s.boastAge<.60 and pose(s.boastAge,boast) or (s.time%5.3>5.16 and 2 or 1)
    s.kagomeFrame=(s.time+1.7)%6.1>5.95 and 2 or 1
    s.shippoFrame=(s.time+.6)%4.9>4.74 and 2 or 1
  end
  return s
end
return M
