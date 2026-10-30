"""Build the documented reveal geometry from frozen trace samples."""
def path(reference):
    points=reference['trace'];result=[];previous=None;segment=None
    live=points[-1] if points and reference['continuous'] else None
    offset=reference['y']-live['y'] if live else 0
    def mix(a,b,t):return [a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t]
    for point in points:
        x,y=point['x'],point['y']
        if live and point['segment']==live['segment']:
            blend=max(0,min(1,1-(640-x)/10));y+=offset*blend*blend*(3-2*blend)
        end=[x,y];progress=point.get('progress')
        if segment!=point['segment']:result.append(['M',x,y])
        elif progress is None:result.append(['L',x,y])
        else:
            handle=(x-previous[0])*.45;c1=[previous[0]+handle,previous[1]];c2=[x-handle,y]
            if progress>=1:result.append(['C',*c1,*c2,*end])
            elif progress<=0:result.append(['M',x,y])
            else:
                t=progress/2;s=1-t;l1=mix(previous,c1,t);l2=mix(l1,mix(c1,c2,t),t);le=mix(l2,mix(mix(c1,c2,t),mix(c2,end,t),t),t)
                r2=mix(c2,end,s);r1=mix(mix(c1,c2,s),r2,s);rs=mix(mix(mix(previous,c1,s),mix(c1,c2,s),s),r1,s)
                result.extend([['C',*l1,*l2,*le],['M',*rs],['C',*r1,*r2,*end]])
        previous=end;segment=point['segment']
    if live:result.append(['L',640,reference['y']])
    return result
