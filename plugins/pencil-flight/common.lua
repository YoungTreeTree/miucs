local M={}
function M.clamp(x,a,b) return math.max(a,math.min(b,x)) end
function M.approach(x,target,dt,tau) return x+(target-x)*(1-math.exp(-dt/tau)) end
function M.fresh(event,now,cursor,through,age)
  local lag=now-(event.receivedAt or -1e9)
  return event.sequence>cursor and event.sequence<=through and lag>=0 and lag<=age
end
function M.audio(input)
  local f=input and input.frame
  if not f or input.state~="running" or f.sessionID~=input.sessionID or not input.frameAge or input.frameAge<0 or input.frameAge>=.4 or f.audio.isSilent then return nil end
  return f.audio,f
end
function M.path(id,path,extra)
  local n={id=id,type="path",path=path,stroke="#3d3d3d",strokeWidth=1}
  for k,v in pairs(extra or {}) do n[k]=v end
  return n
end
function M.rect(id,x,y,w,h,fill)
  return {type="rect",id=id,x=x,y=y,width=w,height=h,fill=fill,antialias=false}
end
return M
