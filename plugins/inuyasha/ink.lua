-- Persistent, deterministic geometry: small irregular pen lifts, never frame noise.
local I = {color = '#29272D'}
local function hash(s)
  local h = 19
  for n = 1, #s do h = (h * 31 + s:byte(n)) % 65521 end
  return h
end
local function path(points, close)
  local p = {}
  for n, v in ipairs(points) do p[#p+1] = {n == 1 and 'M' or 'L', v[1], v[2]} end
  if close then p[#p+1] = {'Z'} end
  return p
end
function I.rounded(x, y, w, h, r)
  local p = {}
  for _, c in ipairs({{x+w-r,y+r,-math.pi/2}, {x+w-r,y+h-r,0},
      {x+r,y+h-r,math.pi/2}, {x+r,y+r,math.pi}}) do
    for i = 0, 8 do
      local a = c[3] + math.pi/2 * i/8
      p[#p+1] = {c[1]+math.cos(a)*r, c[2]+math.sin(a)*r}
    end
  end
  return p
end
function I.ellipse(x,y,rx,ry)
  local p={}
  for i=0,63 do local a=i*math.pi/32;p[#p+1]={x+rx*math.cos(a),y+ry*math.sin(a)} end
  return p
end
function I.smooth(points)
  local out={}
  for i=1,#points do
    local a,b,c,d=points[(i-2)%#points+1],points[i],points[i%#points+1],points[(i+1)%#points+1]
    for step=0,5 do
      local t=step/6;local p={}
      for axis=1,2 do
        p[axis]=.5*((2*b[axis])+(-a[axis]+c[axis])*t+
          (2*a[axis]-5*b[axis]+4*c[axis]-d[axis])*t*t+
          (-a[axis]+3*b[axis]-3*c[axis]+d[axis])*t*t*t)
      end
      out[#out+1]=p
    end
  end
  return out
end
function I.shape(id, points, fill, width, run, gap, closed)
  if closed == nil then closed=true end
  width,run,gap = width or 2.7,run or 26,gap or 5
  local nodes={}
  if fill then nodes[#nodes+1]={type='path',id=id..'-fill',path=path(points,closed),fill=fill} end
  local seed=hash(id)
  local drawing=true
  local remaining=run*(.6+(seed%17)/24)
  local length=0
  local strokes={{},{},{}}
  local stroke=1
  local start=true
  -- Split a sampled contour by arclength, with independent irregular run/gap lengths.
  for edge=1,#points-(closed and 0 or 1) do
    local a,b=points[edge],points[edge%#points+1]
    local dx,dy=b[1]-a[1],b[2]-a[2]
    local d=math.sqrt(dx*dx+dy*dy)
    local at=0
    while at<d-.0001 do
      local step=math.min(d-at,remaining,3)
      local function sample(t)
        local wave=math.sin((length+t)*.17+seed)*.22
        return a[1]+dx*(at+t)/d-dy/d*wave,a[2]+dy*(at+t)/d+dx/d*wave
      end
      if drawing then
        local x,y=sample(0)
        if start then strokes[stroke][#strokes[stroke]+1]={'M',x,y};start=false end
        x,y=sample(step);strokes[stroke][#strokes[stroke]+1]={'L',x,y}
      end
      at=at+step;length=length+step;remaining=remaining-step
      if remaining<.0001 then
        drawing=not drawing;start=true
        seed=(seed*109+89)%65521
        remaining=(drawing and run or gap)*(.68+(seed%100)/125)
        if drawing then stroke=stroke%3+1 end
      end
    end
  end
  for i,p in ipairs(strokes) do
    nodes[#nodes+1]={type='path',id=id..'-ink-'..i,path=p,stroke=I.color,strokeWidth=width*(.9+i*.05)}
  end
  return {type='group',id=id,children=nodes}
end
function I.box(id,x,y,w,h,fill,width)
  return I.shape(id,I.rounded(x,y,w,h,5),fill,width,math.min(w,h)*.8,4.8)
end
return I
