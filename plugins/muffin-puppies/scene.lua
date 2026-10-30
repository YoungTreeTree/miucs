local I=miucs.require('ink.lua')
local K=miucs.require('keyboard.lua')
local J=miucs.require('jump_frames.lua')
local S={}
-- All dog positions and scales stay fixed. Atlas frames contain the entire motion.
local sprites={
  left={x=148,y=21.6,w=144,h=141.6,source=J.maltese.source,rects=J.maltese.rects},
  right={x=342,y=18.2,w=156,h=145.6,source=J.golden.source,rects=J.golden.rects},
  muffin={x=611,y=30,w=134,h=134,rects={{1068,58,420,420},{1068,546,420,420}}}
}
local function sprite(id,v)
  return {type='image',id=id,x=v.x,y=v.y,width=v.w,height=v.h,source=v.source or 'assets/characters.png',
    sourceRect=v.rects[1],sampling='linear',pivot={.5,.97}}
end
function S.create()
  local nodes=K.scene()
  local stage={}
  for _,side in ipairs({'left','right'}) do
    local v=sprites[side]
    stage[#stage+1]=sprite(side..'-dog',v)
  end
  stage[#stage+1]={type='ellipse',id='muffin-shadow',x=625,y=153,width=109,height=7,fill='#3F394329'}
  stage[#stage+1]=sprite('muffin',sprites.muffin)
  for i=1,8 do
    local ring=I.shape('bubble-'..i,I.ellipse(0,0,10,10),'#D2C8FF12',1.5,9,4)
    for _,n in ipairs(ring.children) do if n.stroke then n.stroke=i%2==0 and '#C4AEF0' or '#D8B5EF' end end
    ring.children[#ring.children+1]={type='ellipse',id='bubble-glint-'..i,x=-5,y=-6,width=3.5,height=5,fill='#FFFFFFE8',rotation=.5}
    ring.opacity=0;ring.width=20;ring.height=20
    stage[#stage+1]=ring
  end
  nodes[#nodes+1]={type='group',id='stage',clip={40,20,720,140},z=5,children=stage}
  return {type='group',id='muffin-puppies',width=800,height=460,children=nodes}
end
function S.update(s)
  for _,side in ipairs({'left','right'}) do
    local d=s[side];local v=sprites[side]
    miucs.set(side..'-dog',{sourceRect=v.rects[d.frame]})
  end
  local v=sprites.muffin
  miucs.set('muffin',{sourceRect=v.rects[s.breath<.26 and 2 or 1],scaleX=1+(s.breath<.26 and .015*math.sin(s.breath/.26*math.pi) or 0)})
  -- Ring center in the registered Muffin image. It stays fixed while a bubble grows.
  local wandX,wandY=633,101
  for i=1,8 do
    local b=s.bubbles[i]
    if b then
      local t=math.max(0,b.age-.16)
      local grow=math.min(1,b.age/.16)
      local r=b.radius*(.2+.8*grow)
      local x=wandX-r-3-t*43+math.sin(t*3+b.phase)*t*2
      local y=wandY-t*40
      local opacity=math.min(1,(1.85-b.age)/.4)*.85
      miucs.set('bubble-'..i,{x=x,y=y,scaleX=r/10,scaleY=r/10,opacity=opacity})
    else miucs.set('bubble-'..i,{opacity=0}) end
  end
end
return S
