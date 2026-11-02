local K=miucs.require('keyboard.lua')
local A=miucs.require('frames.lua')
local S={}
-- Fixed ground anchors and pixel scales. Crop offsets only undo atlas packing.
local actors={
  link={x=140,y=156},
  guardian={x=652,y=156},
}
local function point(name,index)
  local a,v=A[name],actors[name]
  local p=a.anchors[index]
  return v.x+p[1]*a.scale,v.y+p[2]*a.scale
end
local function pose(a,index)
  local r,o=a.rects[index],a.offsets[index]
  return {sourceRect=r,x=o[1]*a.scale,y=o[2]*a.scale,width=r[3]*a.scale,height=r[4]*a.scale}
end
function S.create()
  local nodes=K.scene()
  local stage={}
  for _,name in ipairs({'link','guardian'}) do
    local a,v=A[name],actors[name]
    local art=pose(a,1)
    art.type='image';art.id=name..'-art';art.source=a.source;art.sampling='linear'
    stage[#stage+1]={type='group',id=name,x=v.x,y=v.y,children={art}}
  end
  local effects={
    {type='path',id='laser-glow',path={{'M',600,90},{'L',196,90}},stroke='#EC54BB45',strokeWidth=10},
    {type='path',id='laser-edge',pathRef='laser-glow',stroke='#EE58C5',strokeWidth=3.5},
    {type='path',id='laser-core',pathRef='laser-glow',stroke='#FFF6FD',strokeWidth=1.3},
  }
  stage[#stage+1]={type='group',id='laser',opacity=0,children=effects}
  local rays={}
  for i=0,7 do
    local angle=i*math.pi/4
    local r=i%2==0 and 10 or 6
    rays[#rays+1]={'M',math.cos(angle)*2,math.sin(angle)*2}
    rays[#rays+1]={'L',math.cos(angle)*r,math.sin(angle)*r}
  end
  stage[#stage+1]={type='group',id='impact',opacity=0,children={
    {type='path',id='impact-aura',path=rays,stroke='#78DFF9',strokeWidth=3.5},
    {type='path',id='impact-core',pathRef='impact-aura',stroke='#FFFFFF',strokeWidth=1.3},
  }}
  nodes[#nodes+1]={type='group',id='stage',clip={39,19,722,142},z=5,children=stage}
  return {type='group',id='zelda-guardian',width=800,height=460,children=nodes}
end
function S.update(s)
  miucs.set('link-art',pose(A.link,s.link.frame))
  miucs.set('guardian-art',pose(A.guardian,s.guardianFrame))
  local gx,gy=point('guardian',s.guardianFrame)
  local lx,ly=point('link',s.link.frame)
  miucs.set('laser-glow',{path={{'M',gx,gy},{'L',lx,ly}}})
  miucs.set('laser',{opacity=s.beam})
  miucs.set('impact',{x=lx,y=ly,opacity=s.beam})
end
return S
