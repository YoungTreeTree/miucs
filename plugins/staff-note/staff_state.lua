local C=miucs.require("common.lua")
local S={}
local function resetPitch() S.reliable=false;S.pending=nil;S.trackTime=nil;S.reference=nil end
local function stopSway()if S.angle*S.angular>=0 then S.angular=0 end end
local function breakTrace()if S.lastTraceTime then S.segment=S.segment+1 end;S.lastTraceTime=nil end
local function resetInput()resetPitch();breakTrace();S.sounding=false;S.audioAge=1e9;S.contrast=.5;S.volumeTime=nil;S.observation=nil;stopSway()end
function S.reset()
  S.elapsed=0;S.pitch=nil;S.target=74;S.y=74;S.velocity=0;S.angle=0;S.angular=0;S.direction=-1;S.scale=.94;S.opacity=.22;S.labelOpacity=0
  S.segment=0;S.trace={};S.melodyAge=1e9;S.loudness=0;S.lastTraceTime=nil;resetInput()
  S.session=nil;S.sequence=nil;S.lastMelody=nil;S.lastAudio=nil;S.sampleRate=nil;S.channels=nil;S.onsetCursor=0
end
S.reset()
function S.continuous()local last=S.trace[#S.trace];return S.sounding and S.reliable and S.audioAge<.4 and S.lastTraceTime and last and last.segment==S.segment end
local function pitchY(midi)local degrees={0,0,1,1,2,3,3,4,4,5,5,6};return 74-((math.floor(midi/12)-1)*7+degrees[midi%12+1]-34)*4 end
local function melody(m,age)
  if not S.sounding or age<0 or age>=.24 then S.reliable=false;S.pending=nil;S.trackTime=nil;return end
  if m then if S.observation and m.time<=S.observation then return end;S.observation=m.time end
  if m and (not m.isMelodic or not m.pitchHz) then resetPitch();stopSway();return end
  if not m or m.confidence<.48 or not m.pitchHz or m.pitchHz<=0 then S.pending=nil;S.trackTime=nil;return end
  local midi=69+12*math.log(m.pitchHz/440,2)
  if midi<42.5 or midi>=84.5 then S.pending=nil;S.trackTime=nil;return end
  local resolved=S.reference and math.abs(midi-S.reference)<=.65 and S.reference or math.floor(midi+.5)
  if S.trackTime and m.time<=S.trackTime then return end
  if S.trackTime and m.time-S.trackTime>.075 then S.pending=nil end;S.trackTime=m.time
  local distance=S.reference and math.abs(resolved-S.reference) or 0
  if distance>2 then
    if S.pending and math.abs(resolved-S.pending.anchor)<=1 then S.pending.frames=S.pending.frames+1 else S.pending={anchor=resolved,since=m.time,frames=1} end
    local seconds,frames=.15,4;if distance<=5 then seconds,frames=.10,2 elseif distance<=10 then seconds,frames=.125,3 end
    if S.pending.frames<frames or m.time-S.pending.since+1e-9<seconds then return end
  end
  S.pending=nil
  local reconnecting=not S.continuous()
  S.pitch=resolved;S.reference=resolved;S.target=pitchY(resolved);S.melodyAge=age;S.reliable=true
  local y=S.target;local last=S.trace[#S.trace];local join
  if last and last.segment==S.segment and S.lastTraceTime then
    local dt=math.max(0,m.time-S.lastTraceTime);y=C.approach(last.y,y,dt,.025)
    if reconnecting and dt>=.08-1e-9 then join={started=S.elapsed,duration=.18+math.min(.12,dt*.12)} end
  end
  S.lastTraceTime=m.time;S.trace[#S.trace+1]={time=S.elapsed-age,y=y,segment=S.segment,join=join}
  if #S.trace>512 then table.remove(S.trace,1) end
end
local function volume(a)
  if S.volumeTime and a.time<=S.volumeTime then return end
  local db=20*math.log(math.max(a.envelope,1e-6),10)
  if S.volumeTime then local ease=1-math.exp(-(a.time-S.volumeTime)/3);S.lower=math.min(db,S.lower+(db-S.lower)*ease);S.upper=math.max(db,S.upper+(db-S.upper)*ease)
  else S.lower=db;S.upper=db end
  S.volumeTime=a.time;S.contrast=C.clamp(.5+(db-(S.lower+S.upper)/2)/math.max(12,S.upper-S.lower),0,1)
end
local function spring(p,v,target,f,dt)local d=p-target;local c=v+f*d;local decay=math.exp(-f*dt);return target+(d+c*dt)*decay,(v-f*c*dt)*decay end
function S.update(dt,input)
  input=input or {};S.elapsed=S.elapsed+dt;S.audioAge=S.audioAge+dt;S.melodyAge=S.melodyAge+dt
  if S.audioAge>=.4 then S.sounding=false;stopSway() end
  if not S.sounding then resetPitch();breakTrace() elseif S.melodyAge>=.24 then S.reliable=false end
  for i=#S.trace,1,-1 do if S.elapsed-S.trace[i].time>=8 then table.remove(S.trace,i) end end
  if #S.trace==0 then breakTrace() end;if dt>.25 then stopSway() end
  local resetRings=false;S.ringClearCursor=0
  if S.session~=input.sessionID then resetInput();S.trace={};S.session=input.sessionID;S.sequence=nil;S.lastMelody=nil;S.lastAudio=nil;S.sampleRate=nil;S.channels=nil;S.onsetCursor=0;resetRings=true end
  local frame=input.frame;local age=input.frameAge
  if input.state=="running" and frame and frame.sessionID==input.sessionID and age and age>=0 and age<.4 then
    local a=frame.audio
    if S.sampleRate~=a.sampleRate or S.channels~=a.channelCount or (S.lastAudio and a.time<S.lastAudio) then
      resetInput();S.trace={};S.lastMelody=nil;S.sequence=nil;resetRings=true
      if S.sampleRate then S.onsetCursor=frame.sequence;S.ringClearCursor=frame.sequence end;S.sampleRate=a.sampleRate;S.channels=a.channelCount
    end
    S.audioAge=age;S.sounding=not a.isSilent;S.loudness=math.min(1,math.log(1+math.max(0,a.envelope)*40)/math.log(13))
    if S.sounding then volume(a) else resetInput();S.audioAge=age end
    if S.sequence~=frame.sequence then
      local m=frame.melody
      if m then
        if S.lastMelody and m.time<S.lastMelody then resetInput();S.trace={};S.sounding=not a.isSilent;S.audioAge=age;S.lastMelody=nil;S.onsetCursor=frame.sequence end
        if m.time~=S.lastMelody then melody(m,age+math.max(0,a.time-m.time));S.lastMelody=m.time end
      else melody(nil,0) end
      S.lastAudio=a.time;S.sequence=frame.sequence
    end
    if S.sounding and S.reliable and S.pitch then
      local strength=nil;for _,e in ipairs(input.onsets or {})do if e.sequence>S.onsetCursor and e.sequence<=frame.sequence then strength=math.max(strength or 0,e.strength) end end
      if strength then S.angular=C.clamp(S.angular+S.direction*(300+135*S.loudness+100*C.clamp(strength,0,1))*math.pi/180,-600*math.pi/180,600*math.pi/180);S.direction=-S.direction end
    end
    S.onsetCursor=math.max(S.onsetCursor,frame.sequence)
  else resetInput() end
  local seconds=math.min(dt,.1);local count=math.max(1,math.ceil(seconds*120));local step=seconds/count
  for _=1,count do
    S.y,S.velocity=spring(S.y,S.velocity,S.target,40,step);S.y=C.clamp(S.y,14,146)
    if S.sounding and S.reliable and S.audioAge<.4 and S.pitch then
      local decay=math.exp(-5*step);local sine,cosine=math.sin(12*step),math.cos(12*step);local p,v=S.angle,S.angular
      S.angle=decay*(p*cosine+(v+5*p)/12*sine);S.angular=decay*(v*cosine-(5*v+169*p)/12*sine)
    else S.angle,S.angular=spring(S.angle,S.angular,0,30,step) end
    local limit=20*math.pi/180
    if S.angle< -limit then S.angle=-limit;S.angular=math.max(0,S.angular) end;if S.angle>limit then S.angle=limit;S.angular=math.min(0,S.angular) end
    S.scale=C.approach(S.scale,S.sounding and S.audioAge<.4 and .8+.7*S.contrast or .94,step,.055)
    S.opacity=C.approach(S.opacity,S.reliable and .95 or .22,step,.055);S.labelOpacity=C.approach(S.labelOpacity,S.reliable and 1 or 0,step,.055)
  end
  return resetRings
end
local function smooth(t)return t*t*(3-2*t)end
local function mix(a,b,t)return {a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t}end
function S.path()
  local path={};local previous,segment;local live=S.continuous() and S.trace[#S.trace]
  local offset=live and S.y-live.y or 0
  local function curve(c1,c2,e)path[#path+1]={"C",c1[1],c1[2],c2[1],c2[2],e[1],e[2]}end
  for _,point in ipairs(S.trace)do
    local x=640-math.max(0,S.elapsed-point.time)*70;local y=point.y
    if live and point.segment==live.segment then y=y+offset*smooth(C.clamp(1-(640-x)/10,0,1)) end
    local ending={x,y}
    if segment~=point.segment then path[#path+1]={"M",x,y}
    elseif point.join then
      local progress=smooth(C.clamp((S.elapsed-point.join.started)/point.join.duration,0,1));local handle=(x-previous[1])*.45
      local c1={previous[1]+handle,previous[2]};local c2={x-handle,y}
      if progress>=1 then curve(c1,c2,ending)
      elseif progress<=0 then path[#path+1]={"M",x,y}
      else
        local t=progress/2;local s=1-t
        local l1=mix(previous,c1,t);local l2=mix(l1,mix(c1,c2,t),t);local le=mix(l2,mix(mix(c1,c2,t),mix(c2,ending,t),t),t);curve(l1,l2,le)
        local r2=mix(c2,ending,s);local r1=mix(mix(c1,c2,s),r2,s);local rs=mix(mix(mix(previous,c1,s),mix(c1,c2,s),s),r1,s)
        path[#path+1]={"M",rs[1],rs[2]};curve(r1,r2,ending)
      end
    else path[#path+1]={"L",x,y} end
    segment=point.segment;previous=ending
  end
  if live then path[#path+1]={"L",640,S.y} end
  return path
end
return S
