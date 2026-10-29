local count=0
local function check(x,m) count=count+1;assert(x,m) end
local M=dofile("motion.lua");local R=dofile("rider.lua")
local function frame(t,seq,pps,beat)
 return {now=t,deltaTime=1/60,
 keyboard={sessionID="k",sampledAt=t+.001,state="running",sequence=seq,pressesPerSecond=pps,idleDuration=pps>0 and 0 or 10,droppedEventCount=0,events={},heldKeys={}},
 audio={sessionID="a",state="running",frameAge=0,frame={sessionID="a",sequence=seq,receivedAt=t+.001,audio={time=t,sampleRate=48000,channelCount=2,isSilent=false}},
 beats=beat and {{sequence=seq,receivedAt=t+.001,confidence=.9,strength=.9,bpm=120}} or {},onsets={}}}
end
local s=M.new({});local r=R.new()
for i=1,600 do local f=frame(i/60,i,0,false);M.update(s,f);R.update(r,s,f.deltaTime);check(r.frame==3,"idle must not loop") end
check(s.jumpCount==0 and s.beatCount==0,"no fabricated trigger")
s=M.new({});r=R.new();local poses={}
for i=1,600 do local f=frame(i/60,i,0,i%30==0);M.update(s,f);R.update(r,s,f.deltaTime);poses[r.frame]=true end
local n=0;for _ in pairs(poses) do n=n+1 end
check(n>=7 and s.beatCount==20,"music crosses intermediate poses")
check(s.jumpCount==0,"music must not jump")
s=M.new({});r=R.new();local jumpFrames={}
for i=1,1200 do local f=frame(i/60,i,9,false);f.audio={state="stopped"};M.update(s,f);R.update(r,s,f.deltaTime);if r.mode=="jump" then jumpFrames[r.frame]=true end end
n=0;for _ in pairs(jumpFrames) do n=n+1 end
check(s.jumpCount>=15 and n==12,"typing independently uses all jump stages")
check(s.beatCount==0,"typing must not invent beats")
local f=frame(21,1300,0,true);M.update(s,f);local beats=s.beatCount
for i=1,5 do M.update(s,f) end
check(s.beatCount==beats,"duplicate beat")
f=frame(22,1400,0,false);f.deltaTime=2;M.update(s,f)
check(s.jumpPhase=="ground" and s.height==0,"resume settles")
local nodes,cache={},{}
miucs={
 require=function(p) if not cache[p] then cache[p]=dofile(p) end return cache[p] end,
 load=function(root) local function visit(n) check(not nodes[n.id],"duplicate "..n.id);nodes[n.id]=n;for _,c in ipairs(n.children or {})do visit(c)end end;visit(root)end,
 set=function(id,p) check(nodes[id]~=nil,"missing "..id);for k,v in pairs(p)do nodes[id][k]=v end end
}
local app=dofile("main.lua")
app.create();app.appearanceChanged({opacity=.8});app.activate({id="niulai-keyboard"})
for i=1,600 do
 local f=frame(i/60,i,i>300 and 8 or 0,i%30==0);app.update(f)
 for id,n in pairs(nodes)do
  for _,k in ipairs({"x","y","width","height","rotation","scaleX","scaleY","opacity"})do
   local v=n[k];check(v==nil or (type(v)=="number" and v==v and math.abs(v)<1e6),"finite "..id.."."..k)
  end
 end
end
check(nodes["niulai-rider"] and not nodes["keyboard-head"] and not nodes["keyboard-tail"],"no cat assets")
app.deactivate();app.dispose();app.dispose()
print("PASS motion/lifecycle assertions="..count)
