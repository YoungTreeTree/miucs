-- Run with cwd at niulai-keyboard; system Lua/mock API, not native Skia acceptance.
local checks=0
local function check(ok,msg)checks=checks+1;assert(ok,msg)end
local nodes={}
miucs={require=function(p)return dofile(p)end,set=function(id,p)
 check(nodes[id]~=nil,'unknown scene id '..id)
 for k,v in pairs(p)do if type(v)=='number'then check(v==v and math.abs(v)<1e6,'finite bounded property')end;nodes[id][k]=v end
end}
local K=dofile('keyboard.lua')
local function walk(n)check(not nodes[n.id],'duplicate id');nodes[n.id]=n;for _,child in ipairs(n.children or {})do walk(child)end end
for _,n in ipairs(K.scene())do walk(n)end
local function snapshot(seq,held,events,mods,offset)
 local h={};for _,key in ipairs(held or {})do h[#h+1]={key=key,duration=1}end
 return {now=1+seq*.016,deltaTime=.016,keyboard={sessionID='k',sequence=seq,state='running',sampledAt=1+seq*.016+(offset or 0),modifiers=mods or 0,heldKeys=h,events=events or {},pressesPerSecond=3,idleDuration=0}}
end
local function event(seq,key,kind,pressed)return {sequence=seq,key=key,kind=kind or 'pressed',receivedAt=1+seq*.016,modifierIsPressed=pressed}end
K.update(snapshot(1,{'a'},{event(1,'a')},0,.001));check(K.state.strikes==1 and K.state.pressed.a,'Mac sample newer accepted');check(K.state.left.key=='a','left hoof a')
K.update(snapshot(1,{'a'},{event(1,'a')}));check(K.state.strikes==1,'event dedup')
K.update(snapshot(2,{'a'},{event(2,'a','repeated')}));check(K.state.strikes==1,'repeat no extra strike')
K.update(snapshot(3,{'a','s','j'},{event(3,'s')}));check(K.state.left.key=='s' and K.state.right.key=='j','multi-side holds')
K.update(snapshot(4,{'a','j'},{event(4,'s','released')}));check(K.state.left.key=='s' and not K.state.pressed.s and K.state.pressed.a,'release stays at last strike, older hold still lights')
K.update(snapshot(5,{}, {event(5,'a','released')}));check(not next(K.state.pressed),'snapshot releases missing key');check(K.state.left.key=='s','release does not home')
K.update(snapshot(6,{}, {event(6,'leftShift','modifiersChanged',true)},1));check(K.state.pressed.leftShift and not K.state.pressed.rightShift,'physical modifier side')
K.update(snapshot(7,{}, {event(7,'rightShift','modifiersChanged',true)},1));check(K.state.pressed.leftShift and K.state.pressed.rightShift,'both modifier sides')
K.update(snapshot(8,{}, {event(8,'leftShift','modifiersChanged',false)},1));check(not K.state.pressed.leftShift and K.state.pressed.rightShift,'one modifier release preserves other')
K.update(snapshot(9,{}, {},0));check(not K.state.pressed.rightShift,'aggregate off clears stale side')
K.update(snapshot(10,{}, {event(10,'capsLock','modifiersChanged',true)},16));check(K.state.caps and not K.state.pressed.capsLock,'caps toggle not hold')
local f=snapshot(11,{'a'},{});f.keyboard.sessionID='new';K.update(f);check(K.state.strikes==0 and K.state.pressed.a,'fresh session observes hold without replay')
f=snapshot(100,{'a'},{event(100,'a')});f.keyboard.sessionID='new';f.keyboard.sampledAt=f.now-1;K.update(f);check(not next(K.state.pressed) and K.state.strikes==0,'stale suppresses')
f.keyboard.sampledAt=f.now;K.update(f);check(K.state.strikes==0,'stale cursor never replayed')
f=snapshot(101,{'j'},{event(101,'j')});f.keyboard.sessionID='new';f.keyboard.state='secureInput';K.update(f);check(not next(K.state.pressed),'secure input clears')
f=snapshot(102,{'j'},{event(102,'j')});f.keyboard.sessionID='new';f.deltaTime=2;K.update(f);check(not next(K.state.pressed),'long stall no backlog');f.deltaTime=.016;K.update(f);check(K.state.strikes==0 and K.state.pressed.j,'held snapshot restored without old action')
K.reset();f=snapshot(1,{'space'},{event(1,'space')});K.update(f);check(K.state.left.key=='space','first space left');K.update(snapshot(2,{}, {event(2,'space','released')}));K.update(snapshot(3,{'space'},{event(3,'space')}));check(K.state.right.key=='space','next space right')
K.reset();f=snapshot(1,{}, {event(1,'leftShift','modifiersChanged',nil)},1);K.update(f);check(not K.state.pressed.leftShift,'ambiguous modifier not invented')
f=snapshot(2,{}, {event(2,nil)});K.update(f);check(K.state.strikes==0,'unknown key ignored')
-- Exact pixel-keyboard target parity: new strikes move one hand; release/idle
-- and auto-repeat never retarget it, including a different older held key.
K.reset()
K.update(snapshot(1,{'a'},{event(1,'a')}))
K.update(snapshot(2,{'a','l'},{event(2,'l')}))
K.update(snapshot(3,{'l'},{event(3,'a','released')}))
K.update(snapshot(4,{}, {event(4,'l','released')}))
for i=5,125 do K.update(snapshot(i,{},{}))end
check(K.state.left.key=='a' and K.state.right.key=='l','running idle retains both last targets')
check(K.state.left.down<.001 and K.state.right.down<.001,'released hooves lift in place')
check(math.abs(K.state.left.x-(118+45/2))<.01 and math.abs(K.state.right.x-(513+45/2))<.01,'positions do not home after release')
K.update(snapshot(126,{'a','s'},{event(126,'s')}))
K.update(snapshot(127,{'a'},{event(127,'s','released')}))
K.update(snapshot(128,{'a'},{event(128,'a','repeated')}))
check(K.state.left.key=='s' and K.state.right.key=='l','repeat and older hold do not steal last targets')
local stopped=snapshot(129,{},{});stopped.keyboard.state='stopped';K.update(stopped)
check(K.state.left.key=='f' and K.state.right.key=='j','unavailable input resets original home targets')
K.reset();for i=1,1800 do local f=snapshot(i,i%40<20 and {'a','j'} or {},{},0,.001);K.update(f)end
local count=0;for _ in pairs(nodes)do count=count+1 end
check(nodes['left-hoof'] and nodes['right-hoof'],'hoof nodes');check(not nodes['left-paw'],'no cat paw');check(count<4096,'node bound')
print(string.format('KEYBOARD PASS: %d checks; %d fixed nodes; press/release/multikey/modifier/session/stale/skew/long-gap',checks,count))
