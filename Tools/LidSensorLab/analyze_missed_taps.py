#!/usr/bin/env python3
"""Native missed-tap exploratory traces. Start/Stop are not contact labels."""
import csv,json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
ROOT=Path(__file__).resolve().parent
OUT=ROOT/'build/Analysis';OUT.mkdir(exist_ok=True,parents=True)
files=[p for p in sorted((ROOT/'build/Captures').glob('missed-taps-*.json')) if json.loads(p.read_text()).get('completed')]
fig,axs=plt.subplots(len(files),3,figsize=(17,len(files)*2.1),layout='constrained')
results=[]
for idx,p in enumerate(files):
 m=json.loads(p.read_text());rows=list(csv.DictReader((p.parent/m['motion_file']).open()));light=list(csv.DictReader((p.parent/m['als_file']).open()));streams={}
 for j,kind in enumerate(['gyro','accel']):
  r=[r for r in rows if r['kind']==kind];t=np.array([float(r['seconds']) for r in r]);v=np.array([[float(r[k]) for k in ['x','y','z']] for r in r]);base=v[0].copy();high=[]
  for i,x in enumerate(v):
   delta=x-base;high.append(delta);dt=t[i]-t[i-1] if i else .00125;base+=delta*(1-np.exp(-dt/.012))
  h=np.array(high);energy=np.linalg.norm(h,axis=1);streams[kind]=(t,v,h,energy)
  ax=axs[idx,j];ax.plot(t,energy,lw=.65,color='#17847e' if j==0 else '#5276a3');ax.set_xlim(0,m['duration_seconds']);ax.grid(alpha=.13)
  ax.axvspan(0,.5,color='#ccc',alpha=.3);ax.axvspan(m['duration_seconds']-.5,m['duration_seconds'],color='#ccc',alpha=.3)
  ax.set_title(f"{idx+1} · {'Lap' if m['on_lap'] else 'Off lap'} · {kind}",loc='left',fontsize=10)
 lt=np.array([float(r['seconds']) for r in light]);lux=np.array([float(r['lux']) for r in light]);axs[idx,2].step(lt,lux,where='post',color='#ac7a21');axs[idx,2].set_title('Native light (lux)',loc='left',fontsize=10);axs[idx,2].set_xlim(0,m['duration_seconds']);axs[idx,2].grid(alpha=.13)
 # Exploratory grouped gyro peaks; do not force exactly three detected events.
 t,v,h,e=streams['gyro'];threshold=max(.35,float(np.quantile(e,.25))*4)
 active=np.where(e>threshold)[0];groups=[]
 for index in active:
  if not groups or t[index]-t[groups[-1][-1]]>.10:groups.append([index])
  else:groups[-1].append(index)
 pulses=[]
 for g in groups:
  peak=g[np.argmax(e[g])];at=t[peak];sel=(t>=at-.05)&(t<=at+.15);axis=h[peak]/max(e[peak],1e-9);opposite=max(0,float(np.max(-h[sel]@axis)))
  ta,va,ha,ea=streams['accel'];near=(ta>=at-.05)&(ta<=at+.15)
  pulses.append({'time':float(at),'gyro_peak':float(e[peak]),'accel_peak':float(max(ea[near])),'opposite_ratio':opposite/float(e[peak]),'duration_above_threshold':float(t[g[-1]]-t[g[0]]),'boundary':bool(at<.5 or at>m['duration_seconds']-.5)})
 for pulse in pulses:axs[idx,0].axvline(pulse['time'],color='#bf5748',alpha=.4,lw=.6)
 results.append({'file':p.name,'on_lap':m['on_lap'],'duration':m['duration_seconds'],'threshold':threshold,'pulses':pulses,'lux_range':[float(min(lux)),float(max(lux))]})
 print(idx+1,'lap',m['on_lap'],'threshold',round(threshold,3),'pulses',[(round(x['time'],3),round(x['gyro_peak'],3),round(x['accel_peak'],4),round(x['opposite_ratio'],2),x['boundary']) for x in pulses])
for ax in axs[-1]:ax.set_xlabel('Seconds after Start')
fig.suptitle('Missed-notch tapping: eight manual recordings\nGray = first/last 0.5 s (possible Start/Stop handling); red = exploratory motion candidates',fontsize=14)
fig.savefig(OUT/'missed-taps-overview.png',dpi=140);plt.close(fig)
(OUT/'missed-taps-summary.json').write_text(json.dumps(results,indent=2))
