local K=miucs.require('keyboard.lua')
local I=miucs.require('ink.lua')
local A=miucs.require('frames.lua')
local S={}
-- Ground contacts remain fixed; only atlas packing offsets change per frame.
local actors={nadeshiko={x=184,y=158},rin={x=632,y=158},fire={x=395,y=158}}
local function pose(a,index)
  local r,o=a.rects[index],a.offsets[index]
  return {sourceRect=r,x=o[1]*a.scale,y=o[2]*a.scale,width=r[3]*a.scale,height=r[4]*a.scale}
end
function S.create()
  local nodes=K.scene()
  local stage={}
  local function add(n) stage[#stage+1]=n end
  -- Unobtrusive tent and ground are static scene geometry, not animated characters.
  add({type='path',id='ground',path={{'M',80,153},{'Q',400,146,724,153}},stroke='#D8BD902D',strokeWidth=2})
  local tent=I.shape('tent',{{434,142},{467,87},{505,142}},'#E9CFA3',1.3,18,3)
  for _,n in ipairs(tent.children) do if n.stroke then n.stroke='#C5A775' end end
  tent.opacity=.78;add(tent)
  add({type='path',id='tent-seam',path={{'M',467,87},{'L',478,142},{'M',467,87},{'L',457,142}},stroke='#C5A775',strokeWidth=1.3})
  add({type='path',id='tent-door',path={{'M',457,142},{'L',467,105},{'L',478,142},{'Z'}},fill='#D9B887'})
  add({type='path',id='tent-guyline',path={{'M',468,88},{'L',519,144}},stroke='#D2B68B',strokeWidth=.9})
  for _,name in ipairs({'nadeshiko','rin','fire'}) do
    local a,v=A[name],actors[name]
    local art=pose(a,1);art.type='image';art.id=name..'-art';art.source=a.source;art.sampling='linear'
    add({type='group',id=name,x=v.x,y=v.y,children={art}})
  end
  nodes[#nodes+1]={type='group',id='stage',clip={39,19,722,142},z=5,children=stage}
  return {type='group',id='yuru-camp',width=800,height=460,children=nodes}
end
function S.update(s)
  miucs.set('nadeshiko-art',pose(A.nadeshiko,s.nadeshiko.frame))
  miucs.set('rin-art',pose(A.rin,s.rin.frame))
  miucs.set('fire-art',pose(A.fire,s.fireFrame))
end
return S
