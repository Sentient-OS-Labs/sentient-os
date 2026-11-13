#!/usr/bin/env python3
"""Analyze native ALS packets only. No repeated cached lux polls or interpolation."""
import argparse,csv,json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--captures',type=Path,default=Path(__file__).resolve().parent/'build/Captures')
parser.add_argument('--out',type=Path,default=Path(__file__).resolve().parent/'build/Analysis')
args=parser.parse_args();args.out.mkdir(parents=True,exist_ok=True)
files=[p for p in sorted(args.captures.glob('ambient-*.json')) if json.loads(p.read_text()).get('completed')]
if not files:raise SystemExit('No complete light run yet.')
p=files[-1];m=json.loads(p.read_text());rows=list(csv.DictReader((p.parent/m['als_file']).open()))
rows=[r for r in rows if r['lux']]
t=np.array([float(r['seconds']) for r in rows]);a=np.array([float(r['lux']) for r in rows]);arrival=np.array([float(r['arrival_seconds']) for r in rows]);dt=float(np.median(np.diff(t)))
metrics=[];aligned=[]
fig,axes=plt.subplots(3,4,figsize=(14,8),layout='constrained',sharex=True,sharey=True)
labels={'tap':'Screen tap','handPass':'Hand pass, no contact','hover':'Hover, no contact','lighting':'Broad lighting/shadow','desk':'Desk tap','typing':'Firm typing'}
for ax,c in zip(axes.flat,m['cues']):
 cue=c['ui_update_seconds'];baseline=float(np.median(a[(t>=cue-3.8)&(t<cue-2.2)]))
 sel=(t>=cue-2)&(t<cue+4);tt=t[sel];v=a[sel];ratio=v/baseline;j=int(np.argmin(v));dip=1-ratio[j]
 below=ratio<.8;left=j;right=j
 if below[j]:
  while left>0 and below[left-1]:left-=1
  while right+1<len(v) and below[right+1]:right+=1
  width=float(tt[right]-tt[left]+dt)
 else:width=0
 metrics.append({'trial':c['trial'],'kind':c['kind'],'baseline_lux':baseline,'dip_fraction':float(dip),
                 'width_below_80pct_s':width,'minimum_relative_to_cue_s':float(tt[j]-cue),
                 'native_sample_interval_s':dt})
 color='#087f8c' if c['kind']=='tap' else '#b56826'
 ax.step(tt-cue,ratio*100,where='post',color=color,lw=1.5)
 ax.axvspan(-2,0,color='#ededed',label='Preparation')
 ax.axvline(0,ls='--',color='#666',lw=.8)
 ax.axhline(80,color='#999',lw=.5,ls=':')
 ax.set_title(f"{c['trial']}. {labels.get(c['kind'],c['kind'])}",loc='left',fontsize=11)
 ax.set(xlim=(-2,4),ylim=(0,112));ax.grid(alpha=.13)
 aligned.append((c['kind'],tt-tt[j],ratio))
for ax in axes[-1]:ax.set_xlabel('Seconds relative to NOW cue')
for ax in axes[:,0]:ax.set_ylabel('Light / pre-trial baseline (%)')
fig.suptitle('Native ambient-light traces: taps and non-tap controls',fontsize=16)
fig.savefig(args.out/'ambient-trials.png',dpi=160);plt.close(fig)
summary={'source':p.name,'native_frames':len(t),'native_hz':1/dt,'timestamp_arrival_delay_p99_s':float(np.quantile(arrival-t,.99)),
 'method':'Baseline before preparation. Width is contiguous native samples below 80% of baseline, around the deepest dip. Approximately 202 ms sample spacing limits duration estimates. Cue timestamps are not contact timestamps. No gyro or acceleration was captured in this run.',
 'trials':metrics}
(args.out/'ambient-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for r in metrics:print(f"{r['trial']:2} {r['kind']:10} dip={100*r['dip_fraction']:5.1f}% width={r['width_below_80pct_s']:.2f}s minimum at cue {r['minimum_relative_to_cue_s']:+.2f}s")
print(args.out/'ambient-trials.png')
