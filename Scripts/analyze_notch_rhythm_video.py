"""Measure visible response relative to the cue marker in the isolated native rhythm fixture.
This does not measure physical contact or sensor latency. Pass the fixture output directory.
"""
import subprocess,json,sys
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=Path(sys.argv[1]).resolve()
p=subprocess.Popen(['ffmpeg','-v','error','-i',str(root/'tap-rhythm.mp4'),'-vf','scale=700:240,fps=60','-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE)
rows=[];frames=[];i=0
while True:
 data=p.stdout.read(700*240*3)
 if len(data)!=700*240*3:break
 f=np.frombuffer(data,dtype=np.uint8).reshape(240,700,3)
 mark=f[20,4];opened=int(mark[1])>int(mark[0]);mask=(f[:,300:400].astype(float).sum(axis=2)<115).mean(axis=1)>.35
 y=np.where(mask)[0];h=int(y.max()+1) if len(y) else 0
 rows.append((i/60,opened,h));
 if i in [35,40,45,270,273,276,279]:frames.append((i,f.copy()))
 i+=1
p.wait();a=np.array(rows);edges=np.where(a[1:,1]!=a[:-1,1])[0]+1
result=[]
for j in edges:
 direction=1 if a[j,1] else -1
 k=next((k for k in range(j,min(j+8,len(a))) if direction*(a[k,2]-a[max(0,j-1),2])>=1),None)
 result.append({'frame':int(j),'target_open':bool(a[j,1]),'first_pixel_response_ms':None if k is None else round((k-j)/60*1000,1)})
fig,ax=plt.subplots(figsize=(14,4),layout='constrained');ax.plot(a[:,0],a[:,2],label='Visible notch bottom (pixels)')
for r in result:ax.axvline(r['frame']/60,color='green' if r['target_open'] else 'red',alpha=.35)
ax.set(xlabel='Seconds in recording',ylabel='Visible height (pixels)',title='Actual SwiftUI spring reversals: 180 ms and 100 ms tap spacing');ax.legend();fig.savefig(root/'rhythm-response.png',dpi=150)
fig,axs=plt.subplots(1,len(frames),figsize=(3*len(frames),2),layout='constrained')
for ax,(i,f) in zip(axs,frames):ax.imshow(f);ax.set_title(f'Frame {i}');ax.axis('off')
fig.savefig(root/'rhythm-frames.png',dpi=120)
(root/'rhythm-response.json').write_text(json.dumps(result,indent=2));print(root);print('frames',len(rows),'transitions',len(edges),'responses',result)
