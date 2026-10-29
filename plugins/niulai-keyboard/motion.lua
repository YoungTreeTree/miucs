-- Pure deterministic motion state. No OS access, real clock, RNG or external deps.
local M={}
local function num(v,default) if type(v)=="number" and v==v and math.abs(v)<math.huge then return v end;return default end
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function approach(v,to,dt,tau) return v+(to-v)*(1-math.exp(-dt/tau)) end
local function tableOr(v) return type(v)=="table" and v or {} end
function M.new(config)
  config=tableOr(config)
  return {time=0,lean=0,target=0,edge=-1,beatAge=100,period=.6,audioSession=false,audioCursor=0,onsetCursor=0,impulse=0,onsetCount=0,
    keyboardSession=false,keyCursor=0,typing=0,charge=0,wasTyping=false,jumpPhase="ground",jumpTime=0,
    height=0,pose=1,rotation=0,squash=1,drift=0,activity=0,beatCount=0,jumpCount=0,
    jumpHeight=clamp(num(config.jumpHeight,65),20,75),rateScale=clamp(num(config.jumpRateScale,1),.5,1.5)}
end
local function cancelJump(s) s.jumpPhase="ground";s.jumpTime=0;s.height=0;s.rotation=0;s.squash=1;s.charge=0 end
function M.update(s,frame)
  frame=tableOr(frame);local dt=clamp(num(frame.deltaTime,0),0,60);local now=num(frame.now,s.time+dt)
  local input=tableOr(frame.audio);local f=tableOr(input.frame);local a=tableOr(f.audio)
  local k=tableOr(frame.keyboard)
  if s.audioSession~=input.sessionID then
    s.audioSession=input.sessionID;s.audioCursor=0;s.onsetCursor=0;s.impulse=0;s.beatAge=100;s.target=0;s.edge=-1
    s.audioTime=nil;s.sampleRate=nil;s.channelCount=nil
  end
  if s.keyboardSession~=k.sessionID then
    s.keyboardSession=k.sessionID;s.keyCursor=0;s.typing=0;s.charge=0;s.wasTyping=false;s.lastPress=nil
    -- A keyboard reconnect does not cancel an already airborne board.
  end
  if dt>.5 then
    -- Hide/resume or stall: settle and consume cursors; never replay the backlog.
    cancelJump(s);s.lean=0;s.target=0;s.beatAge=100;s.typing=0;s.wasTyping=false
    s.audioCursor=math.max(s.audioCursor,(f.sessionID==input.sessionID and num(f.sequence,0) or 0));s.keyCursor=math.max(s.keyCursor,num(k.sequence,0))
    s.onsetCursor=s.audioCursor;s.impulse=0;s.time=s.time+dt;s.pose=1;s.activity=0
    return s
  end
  s.time=s.time+dt;s.beatAge=s.beatAge+dt;s.impulse=s.impulse*math.exp(-dt/.20)
  local frameAge=num(input.frameAge,1e9)
  local audioLive=input.state=="running" and f.sessionID==input.sessionID and frameAge>=0 and frameAge<.4 and a.isSilent==false
    and num(f.receivedAt,-1)<=now+.05 and now-num(f.receivedAt,-1)<=.45
  local through=f.sessionID==input.sessionID and num(f.sequence,0) or 0
  local discontinuity=s.audioTime and (num(a.time,s.audioTime)<s.audioTime or a.sampleRate~=s.sampleRate or a.channelCount~=s.channelCount)
  if discontinuity then s.audioCursor=through;s.onsetCursor=through;s.beatAge=100;s.target=0 end
  if audioLive then
    s.audioTime=num(a.time,0);s.sampleRate=a.sampleRate;s.channelCount=a.channelCount
    local accepted=0
    -- Host captures frame.now before reading sources; input snapshot may be milliseconds newer.
    local audioNow=math.max(now,math.min(now+.05,num(f.receivedAt,now)+frameAge))
    for _,e in ipairs(tableOr(input.beats)) do
      local seq=num(e.sequence,0);local age=audioNow-num(e.receivedAt,-1e9)
      if seq>s.audioCursor and seq<=through and age>=0 and age<=.25 and num(e.confidence,0)>=.45 and num(e.confidence,0)<=1
        and num(e.bpm,0)>=50 and num(e.bpm,0)<=200 and num(e.strength,-1)>=0 and num(e.strength,2)<=1 then
        s.edge=-s.edge;s.period=60/e.bpm;s.beatAge=age;s.beatCount=s.beatCount+1;accepted=accepted+1
        s.audioCursor=seq
      end
    end
    if accepted>0 then s.target=s.edge end
    for _,e in ipairs(tableOr(input.onsets)) do
      local seq=num(e.sequence,0);local age=audioNow-num(e.receivedAt,-1e9)
      if seq>s.onsetCursor and seq<=through and age>=0 and age<=.25 and num(e.strength,0)>=.08 then
        s.impulse=math.min(1,.4+num(e.strength,0));s.onsetCount=s.onsetCount+1;s.onsetCursor=seq
      end
    end
  end
  -- Also consume rejected/stale/silent snapshot events; they must not reappear later.
  s.audioCursor=math.max(s.audioCursor,through);s.onsetCursor=math.max(s.onsetCursor,through)
  if not audioLive or s.beatAge>math.max(.9,s.period*1.6) then s.target=0 end
  local kage=now-num(k.sampledAt,-1e9)
  local keyLive=k.state=="running" and kage>=-.05 and kage<=.4
  local keyboardNow=keyLive and math.max(now,num(k.sampledAt,now)) or now
  local pps=keyLive and clamp(num(k.pressesPerSecond,0),0,256) or 0
  local idle=num(k.idleDuration,1e9)
  local freshPress=false
  for _,e in ipairs(tableOr(k.events)) do
    local seq=num(e.sequence,0);local age=keyboardNow-num(e.receivedAt,-1e9)
    if keyLive and seq>s.keyCursor and seq<=num(k.sequence,0) and age>=0 and age<=.25 and e.kind=="pressed" then freshPress=true end
  end
  s.keyCursor=math.max(s.keyCursor,num(k.sequence,0))
  -- If idleDuration is missing, only fresh events can authorize a new jump.
  if freshPress then s.lastPress=keyboardNow;idle=0 end
  if idle==1e9 and s.lastPress then idle=keyboardNow-s.lastPress end
  local typing=keyLive and pps>.05 and idle>=0 and idle<.85 and num(k.droppedEventCount,0)==0
  s.typing=approach(s.typing,typing and pps or 0,dt,.12)
  if typing then
    if not s.wasTyping then s.charge=math.max(s.charge,.7) end
    s.charge=math.min(1,s.charge+dt*clamp((.22+.15*s.typing)*s.rateScale,.25,1.15))
  else s.charge=0 end
  s.wasTyping=typing
  if s.jumpPhase=="ground" and typing and s.charge>=1 then
    s.jumpPhase="load";s.jumpTime=0;s.charge=0;s.jumpCount=s.jumpCount+1
  end
  local airborne=s.jumpPhase~="ground"
  s.jumpTime=s.jumpTime+dt;s.height=0;s.rotation=0;s.squash=1
  if s.jumpPhase=="load" then
    s.pose=3;local p=clamp(s.jumpTime/.18,0,1);s.squash=1-.16*(p*p*(3-2*p))
    if s.jumpTime>=.18 then s.jumpPhase="air";s.jumpTime=0 end
  elseif s.jumpPhase=="air" then
    local p=clamp(s.jumpTime/.62,0,1);s.height=s.jumpHeight*math.sin(math.pi*p);local stretch=clamp(p/.22,0,1);s.squash=.84+.16*(stretch*stretch*(3-2*stretch))+.035*math.sin(math.pi*p);s.pose=4;s.rotation=-.08*math.sin(2*math.pi*p)
    if s.jumpTime>=.62 then s.jumpPhase="land";s.jumpTime=0;s.height=0;s.rotation=0 end
  elseif s.jumpPhase=="land" then
    local p=clamp(s.jumpTime/.18,0,1);s.pose=5;local q=p<.35 and p/.35 or (1-p)/.65;s.squash=1-.16*(q*q*(3-2*q))
    if s.jumpTime>=.18 then s.jumpPhase="ground";s.jumpTime=0 end
  else
    s.lean=approach(s.lean,s.target,dt,.20)
    s.pose=s.lean>.32 and 0 or (s.lean<-.32 and 2 or 1)
  end
  -- In-air animation is not disturbed by beat direction changes; latest target resumes on landing.
  s.activity=approach(s.activity,(audioLive or typing or airborne) and 1 or 0,dt,.25)
  s.drift=(s.drift+dt*(12+42*s.activity))%560
  return s
end
return M
