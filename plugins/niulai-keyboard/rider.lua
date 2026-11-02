-- Event-driven pose playback. Never autonomously cycles the sprite atlas.
local R={}
function R.new() return {frame=3,position=3,beatCount=0,jumpCount=0,target=3,mode="carve"} end
function R.update(r,s,dt)
 -- Carve atlas 0..3 relax heel -> flat, 4..7 load opposite edge.
 -- Reverse the same contiguous weight transfer to return, not a flipped sprite.
 if s.jumpPhase~="ground" then
  r.mode="jump"
  if s.jumpPhase=="load" then r.frame=math.min(2,math.floor(s.jumpTime/.18*3))
  elseif s.jumpPhase=="air" then r.frame=3+math.min(5,math.floor(s.jumpTime/.62*6))
  else r.frame=9+math.min(2,math.floor(s.jumpTime/.18*3)) end
  r.position=3 -- land on a flat board before accepting the latest edge target
 else
  r.mode="carve"
  r.target=s.target>0 and 0 or (s.target<0 and 7 or 3)
  local step=math.min(math.max(dt,0),.1)*18
  if r.position<r.target then r.position=math.min(r.target,r.position+step)
  else r.position=math.max(r.target,r.position-step) end
  r.frame=math.floor(r.position+.5)
 end
 r.beatCount=s.beatCount;r.jumpCount=s.jumpCount
 return r
end
return R
