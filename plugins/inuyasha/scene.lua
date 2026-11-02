local K=miucs.require('keyboard.lua')
local A=miucs.require('frames.lua')
local S={}
local actors={inuyasha={x=202,y=158},kagome={x=627,y=158},shippo={x=407,y=158},dust={x=202,y=158}}
local function pose(a,index)
  local r,o=a.rects[index],a.offsets[index]
  return {sourceRect=r,x=o[1]*a.scale,y=o[2]*a.scale,width=r[3]*a.scale,height=r[4]*a.scale}
end
function S.create()
  local nodes=K.scene()
  local stage={{type='image',id='backdrop',source='assets/backdrop.png',x=36,y=-80,width=728,height=728/3,sampling='linear'}}
  for _,name in ipairs({'dust','inuyasha','kagome','shippo'}) do
    local a,v=A[name],actors[name]
    local art=pose(a,1);art.type='image';art.id=name..'-art';art.source=a.source;art.sampling='linear'
    stage[#stage+1]={type='group',id=name..'-actor',x=v.x,y=v.y,children={art}}
  end
  nodes[#nodes+1]={type='group',id='stage',clip={39,19,722,142},z=5,children=stage}
  return {type='group',id='inuyasha',width=800,height=460,children=nodes}
end
function S.update(s)
  for _,name in ipairs({'dust','inuyasha','kagome','shippo'}) do
    local art=pose(A[name],s[name..'Frame'])
    if name=='dust' then art.opacity=s.dustVisible and 1 or 0 end
    miucs.set(name..'-art',art)
  end
end
return S
