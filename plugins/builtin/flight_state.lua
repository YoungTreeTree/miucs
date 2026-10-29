local C=miucs.require("common.lua")
local W={}
local function spring(p,v,target,f,dt)local d=p-target;local c=v+f*d;local e=math.exp(-f*dt);return target+(d+c*dt)*e,(v-f*c*dt)*e end
local function ease(x)x=C.clamp(x,0,1);return x*x*(3-2*x)end
local function softmin(a,b)local h=math.max(10-math.abs(a-b),0)/10;return math.min(a,b)-h*h*2.5 end
function W.noise(index,seed)local n=math.sin((index*73+seed*137)*12.9898)*43758.5453;return (n-math.floor(n))*2-1 end
local function resetInput()W.audio=nil;W.audioAge=1e9;W.lastAudio=nil;W.lastMelody=nil;W.note=nil;W.noteAge=1e9;W.history={};W.lower=48;W.upper=84;W.rangeTime=nil;W.onset=false;W.flux=0 end
function W.reset()
  W.distance=0;W.y=126;W.velocity=0;W.target=126;W.angle=0;W.scale=.8;W.activity=0;W.flap=0;W.loudness=0;W.bass=0;W.mids=0;W.highs=0;W.brightness=.5;W.scatter=0;W.elapsed=0;W.lead=250
  W.gates={};W.particles={};W.puffs={};W.score=0;W.nextGate=0;W.gateID=0;W.particleID=0;W.particleBudget=0;W.cooldown=0;W.session=nil;W.sequence=0;W.sampleRate=nil;W.channels=nil;resetInput()
end
W.reset()
local function emit(feather)
  local a,b=W.noise(W.particleID,7),W.noise(W.particleID,19);local life=feather and .65 or .9
  W.particles[#W.particles+1]={id=W.particleID,x=82,y=W.y+a*4,vx=-12-math.abs(a)*16,vy=b*(8+W.scatter*35),life=life,lifetime=life,feather=feather};W.particleID=W.particleID+1
end
function W.update(frame)
  local input=frame.audio or {};local f=input.frame
  if input.sessionID~=W.session then resetInput();W.session=input.sessionID;W.sequence=0;W.sampleRate=nil;W.channels=nil end
  if input.state=="running" and f and input.frameAge and input.frameAge<.4 then
    if W.sequence~=f.sequence then
      if W.sampleRate~=f.audio.sampleRate or W.channels~=f.audio.channelCount then resetInput();W.sampleRate=f.audio.sampleRate;W.channels=f.audio.channelCount end
      local a=f.audio
      if a.time~=W.lastAudio then W.lastAudio=a.time;W.audio=a;W.audioAge=input.frameAge end
      local m=f.melody
      if m then
        if W.lastMelody and m.time<W.lastMelody then W.history={};W.lower=48;W.upper=84;W.rangeTime=nil end;W.lastMelody=m.time
        if m.isMelodic and m.confidence>=.48 and m.pitchHz and m.pitchHz>0 and (not W.rangeTime or m.time>W.rangeTime)then
          local midi=69+12*math.log(m.pitchHz/440,2);local dt=C.clamp(m.time-(W.rangeTime or m.time),0,.2);W.rangeTime=m.time
          W.history[#W.history+1]={time=m.time,midi=midi};while #W.history>2048 or (#W.history>0 and W.history[1].time<m.time-30)do table.remove(W.history,1)end
          if #W.history>=24 and m.time-W.history[1].time>=3 then
            local values={};for _,p in ipairs(W.history)do values[#values+1]=p.midi end;table.sort(values)
            local lo=values[math.floor((#values-1)*.1)+1]-2;local hi=values[math.floor((#values-1)*.9)+1]+2;local center=(lo+hi)/2;local span=math.max(12,hi-lo);local limit=dt*.7
            W.lower=W.lower+C.clamp(center-span/2-W.lower,-limit,limit);W.upper=W.upper+C.clamp(center+span/2-W.upper,-limit,limit);W.upper=math.max(W.upper,W.lower+12)
          end
          W.target=196-C.clamp((midi-W.lower)/(W.upper-W.lower),0,1)*140
          if midi>=0 and midi<=127 then if W.noteAge>=.24 or not W.note or math.abs(midi-W.note)>.65 then W.note=math.floor(midi+.5)end;W.noteAge=0 end
        end
      end
      W.sequence=f.sequence
    end
    if W.audio and not W.audio.isSilent and W.audioAge<.4 then W.onset=#(input.onsets or {})>0;W.flux=math.max(W.flux,C.clamp(((input.spectralFluxPeak or 0)-.04)/.56,0,1)) end
  else resetInput() end
  local remaining=math.min(frame.deltaTime,.1)
  while remaining>1e-10 do
    local dt=math.min(remaining,1/120);remaining=remaining-dt
    W.elapsed=W.elapsed+dt;W.audioAge=W.audioAge+dt;W.noteAge=W.noteAge+dt
    local a=W.audio or {};local active=W.audio and not a.isSilent and W.audioAge<.4
    local function drive(power)return C.clamp((10*math.log(math.max(power or 0,1e-12),10)+60)/45,0,1)end
    W.activity=C.approach(W.activity,active and 1 or 0,dt,.28);if W.activity<.002 then W.activity=0 end
    W.loudness=C.approach(W.loudness,active and drive((a.envelope or 0)^2)or 0,dt,.10);W.scale=C.approach(W.scale,.8+.6*W.loudness,dt,.12)
    for _,pair in ipairs({{"bass","lowEnergy",.1},{"mids","midEnergy",.3},{"highs","highEnergy",.1}})do W[pair[1]]=C.approach(W[pair[1]],active and drive(a[pair[2]])or 0,dt,pair[3])end
    W.brightness=C.approach(W.brightness,C.clamp(math.log(math.max(a.centroidHz or 1000,150)/150,2)/6,0,1),dt,1.2);W.scatter=C.approach(W.scatter,a.flatness or 0,dt,.25)
    W.lead=C.approach(W.lead,a.bandwidthHz and 200+90*C.clamp(a.bandwidthHz/5000,0,1) or 250,dt,.45)
    local speed=(96+30*W.mids)*W.activity;W.distance=W.distance+speed*dt
    W.y,W.velocity=spring(W.y,W.velocity,W.target,32,dt);W.angle=C.approach(W.angle,C.clamp(W.velocity*.0015,-.28,.28),dt,.055)
    if active and W.distance>=W.nextGate then local x=W.distance+W.lead
      if #W.gates==0 or x-W.gates[#W.gates].x>=74 then
        local center=72+miucs.random()*108;local half=40+miucs.random()*8
        W.gates[#W.gates+1]={id=W.gateID,x=x,top=center-half,bottom=center+half,rest=center,half=half,center=center,velocity=0,passed=false};W.gateID=W.gateID+1;W.nextGate=W.distance+74+miucs.random()*16
      end
    end
    W.flap=W.flap*math.exp(-dt/.14);if W.onset then W.onset=false;if active then W.flap=1;emit(true)end end
    local stretch=1+W.flap*W.loudness*.06;local halfw=W.scale*(25/stretch+13*stretch*math.abs(math.sin(W.angle)));local halfh=W.scale*(13*stretch+25/stretch*math.abs(math.sin(W.angle)))
    W.halfWidth=halfw
    for i=#W.gates,1,-1 do local g=W.gates[i];local ahead=g.x-W.distance
      if ahead<220 then
        local overlap=30+halfw;local clearance=halfh+14;local approach=ease((220-ahead)/130);local influence=approach*(1-ease((-ahead-overlap)/90));local predicted=C.clamp(W.y+W.velocity*.045,56,196)
        local target=ahead>=-overlap and g.rest+(predicted-g.rest)*approach or g.center
        g.center,g.velocity=spring(g.center,g.velocity,C.clamp(target,g.half+8,238-g.half),14,dt)
        local top,bottom=g.center-g.half,g.center+g.half;g.top=top+(softmin(top,W.y-clearance)-top)*influence;g.bottom=bottom+(-softmin(-bottom,-W.y-clearance)-bottom)*influence
      end
      if not g.passed and g.x+30+halfw<W.distance then g.passed=true;W.score=W.score+1 end
      if g.x<W.distance-166 then table.remove(W.gates,i)end
    end
    W.particleBudget=W.particleBudget+W.highs*24*W.activity*dt;if W.particleBudget>=1 then W.particleBudget=W.particleBudget-1;emit(false)end
    for i=#W.particles,1,-1 do local p=W.particles[i];p.life=p.life-dt;p.x=p.x+(p.vx-speed*.5)*dt;p.y=p.y+p.vy*dt;if p.life<=0 or p.x<0 then table.remove(W.particles,i)end end
    while #W.particles>80 do table.remove(W.particles,1)end
    W.cooldown=math.max(W.cooldown-dt,0)
    if active and W.flux>0 and W.cooldown==0 then W.puffs[#W.puffs+1]={x=96-23*W.scale,y=W.y+10*W.scale,strength=W.flux,age=0,lifetime=.5+W.flux*.25};W.cooldown=.14+.2*(1-W.flux);if #W.puffs>6 then table.remove(W.puffs,1)end end
    W.flux=0
    for i=#W.puffs,1,-1 do local p=W.puffs[i];p.age=p.age+dt;p.x=p.x-(20+p.strength*24+speed*.35)*dt;p.y=p.y-(3+p.strength*4)*dt;if p.age>=p.lifetime or p.x< -20 then table.remove(W.puffs,i)end end
  end
end
return W
