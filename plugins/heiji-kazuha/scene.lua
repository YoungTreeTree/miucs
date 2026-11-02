local K=miucs.require('keyboard.lua')
local F=miucs.require('frames.lua')
local S={}
local actors={heiji={x=235,y=153,scale=.38},kazuha={x=584,y=153,scale=.285}}
local last={}
local function pose(name,index)
  local f=F[name].frames[index];local r=f.rect;local a=actors[name]
  return {sourceRect=r,x=a.x-f.anchor[1]*a.scale,y=a.y-f.anchor[2]*a.scale,
    width=r[3]*a.scale,height=r[4]*a.scale}
end
function S.create()
  last={}
  local nodes=K.scene();local stage={}
  for _,name in ipairs({'heiji','kazuha'}) do
    local n=pose(name,1)
    n.type='image';n.id=name;n.source=F[name].source;n.sampling='nearest'
    stage[#stage+1]=n
  end
  for i,position in ipairs({{515,72},{651,106}}) do
    stage[#stage+1]={type='group',id='note-'..i,x=position[1],y=position[2],opacity=0,children={
      {type='rect',id='note-stem-'..i,x=5,y=0,width=2,height=11,fill='#D88997',antialias=false},
      {type='rect',id='note-flag-'..i,x=7,y=0,width=4,height=3,fill='#D88997',antialias=false},
      {type='rect',id='note-head-'..i,x=0,y=9,width=6,height=4,fill='#D88997',antialias=false}
    }}
  end
  nodes[#nodes+1]={type='group',id='stage',clip={40,14,720,144},z=5,children=stage}
  return {type='group',id='heiji-kazuha',width=800,height=460,children=nodes}
end
function S.update(s)
  for _,name in ipairs({'heiji','kazuha'}) do
    local index=s[name].frame
    if last[name]~=index then miucs.set(name,pose(name,index));last[name]=index end
  end
  local opacity=math.max(0,1-s.kazuha.pulse/.28)
  for i=1,2 do miucs.set('note-'..i,{opacity=opacity}) end
end
return S
