local C={}
function C.number(v,d) if type(v)=='number' and v==v and math.abs(v)<math.huge then return v end;return d end
function C.clamp(x,a,b) return math.max(a,math.min(b,x)) end
function C.approach(x,y,dt,tau) return x+(y-x)*(1-math.exp(-dt/tau)) end
function C.rect(id,x,y,w,h,color) return {type='rect',id=id,x=x,y=y,width=w,height=h,fill=color,antialias=false} end
function C.polygon(id,points,color)
 local path={};for i,p in ipairs(points) do path[#path+1]={i==1 and 'M' or 'L',p[1],p[2]} end;path[#path+1]={'Z'}
 return {type='path',id=id,path=path,fill=color,antialias=false}
end
function C.box(id,x,y,w,h,color,s)
 s=s or 3;return C.polygon(id,{{x+s,y},{x+w-s,y},{x+w-s,y+s},{x+w,y+s},{x+w,y+h-s},{x+w-s,y+h-s},{x+w-s,y+h},{x+s,y+h},{x+s,y+h-s},{x,y+h-s},{x,y+s},{x+s,y+s}},color)
end
return C
