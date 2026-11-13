#!/usr/bin/env python3
"""Use only the most recent recording in each manual category, including partial runs explicitly."""
import csv,json,subprocess
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
ROOT=Path(__file__).resolve().parent;OUT=ROOT/'build/Analysis';OUT.mkdir(exist_ok=True,parents=True)
latest={}
for p in (ROOT/'build/Captures').glob('*.json'):
 m=json.loads(p.read_text())
 if not m.get('manual_start_stop'):continue
 category=m.get('manual_action','missedTaps')
 stamp=int(p.stem.split('-')[-2])
 if category not in latest or stamp>latest[category][0]:latest[category]=(stamp,p,m)
order=['missedTaps','deskTaps','typing','handRest'];fig,axes=plt.subplots(4,3,figsize=(16,10),layout='constrained');summary=[];arrays={}
for i,kind in enumerate(order):
 _,p,m=latest[kind];rows=list(csv.DictReader((p.parent/m['motion_file']).open()));streams={}
 for j,sensor in enumerate(['gyro','accel']):
  rs=[r for r in rows if r['kind']==sensor];t=np.array([float(r['seconds']) for r in rs]);v=np.array([[float(r[k]) for k in ['x','y','z']] for r in rs]);base=v[0].copy();hp=[]
  for n,x in enumerate(v):
   delta=x-base;hp.append(delta);dt=t[n]-t[n-1] if n else .00125;base+=delta*(1-np.exp(-dt/.012))
  h=np.array(hp);e=np.linalg.norm(h,axis=1);streams[sensor]=(t,v,h,e)
  ax=axes[i,j];ax.plot(t,e,lw=.7,color='#117e7b' if sensor=='gyro' else '#5478ad');ax.set_title(f"{kind} · {sensor}"+(' · partial' if not m['completed'] else ''),loc='left');ax.set_xlim(0,m['duration_seconds']);ax.grid(alpha=.15)
  ax.axvspan(0,.4,color='#aaa',alpha=.15);ax.axvspan(m['duration_seconds']-.4,m['duration_seconds'],color='#aaa',alpha=.15)
 light=list(csv.DictReader((p.parent/m['als_file']).open()));lt=np.array([float(r['seconds']) for r in light]);lux=np.array([float(r['lux']) for r in light]);axes[i,2].step(lt,lux,where='post',color='#b67d2b');axes[i,2].set_title('Native light (lux)',loc='left');axes[i,2].set_xlim(0,m['duration_seconds']);axes[i,2].grid(alpha=.15)
 arrays[kind]=streams
 summary.append({'category':kind,'file':p.name,'completed':m['completed'],'duration':m['duration_seconds'],'gyro_samples':len(streams['gyro'][0]),'accel_samples':len(streams['accel'][0]),'light_samples':len(lt)})
for ax in axes[-1]:ax.set_xlabel('Seconds after Start')
fig.suptitle('Latest recording only, per category · no older examples mixed in\nHigh-pass motion; gray regions may include Start/Stop handling',fontsize=15);fig.savefig(OUT/'latest-motion-controls.png',dpi=150);plt.close(fig)
(OUT/'latest-motion-controls.json').write_text(json.dumps(summary,indent=2))
import pickle
(OUT/'latest-motion-controls.pkl').write_bytes(pickle.dumps(arrays))
print(json.dumps(summary,indent=2))

# Reproduce recognition with the actual production classifier. Only the four selected
# files above are replayed; no older captures or inferred keyboard event timestamps.
root=ROOT.parents[1]
binary=ROOT/'build/hint-replay'
subprocess.run(['xcrun','swiftc','-O','-parse-as-library',str(root/'Sentient OS macOS/Notch Magic/PhysicalTapDetector.swift'),str(root/'Sentient OS macOS/Notch Magic/PhysicalMissedTapDetector.swift'),str(ROOT/'Tests/TapReplay.swift'),'-o',str(binary)],check=True)
output=subprocess.check_output([str(binary),*[str(latest[k][1]) for k in order]],text=True)
(OUT/'latest-motion-hint-replay.jsonl').write_text(output)
print(output)
