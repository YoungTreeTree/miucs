-- Code-native split hoof: two dark cloven tips, warm yellow jacket sleeve. No cat toes.
local C=miucs.require('common.lua')
local H={}
function H.node(side)
 local function id(s)return side..'-hoof-'..s end
 local nodes={
  C.polygon(id('sleeve-outline'),{{6,20},{42,20},{44,28},{42,60},{38,66},{10,66},{6,60},{4,28}},'#514438'),
  C.polygon(id('sleeve'),{{8,22},{40,22},{40,57},{36,62},{12,62},{8,57}},'#F3C943'),
  C.rect(id('sleeve-shade'),34,28,6,28,'#D8A92D'),
  C.rect(id('sleeve-light'),10,31,4,24,'#FFE77B'),
  C.rect(id('cuff'),6,21,36,9,'#E1AF2E'),
  C.rect(id('cuff-light'),8,23,30,3,'#FFE17A'),
  C.polygon(id('tip-left'),{{4,4},{8,0},{20,0},{22,4},{22,22},{18,26},{6,24},{2,18},{2,8}},'#393432'),
  C.polygon(id('tip-right'),{{26,4},{28,0},{40,0},{44,4},{46,8},{46,18},{42,24},{30,26},{26,22}},'#393432'),
  C.rect(id('left-light'),6,6,4,11,'#68605A'),
  C.rect(id('right-light'),30,5,10,3,'#68605A'),
  C.rect(id('cleft'),22,7,4,17,'#211F20'),
 }
 return {type='group',id=side..'-hoof',x=0,y=0,width=48,height=68,pivot={.5,0},rotation=side=='left' and -.10 or .10,z=20,children=nodes}
end
return H
