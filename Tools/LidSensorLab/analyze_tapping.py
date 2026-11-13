#!/usr/bin/env python3
"""Replay native light/motion captures through the production candidate; retain every trial.

Potential missed-target annotations come from the user's first-two-runs correction, using
optical depth only, never detector success. They are provisional, not contact ground truth.
"""
import csv,json,os,subprocess
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
ROOT=Path(__file__).resolve().parents[2]
LAB=Path(__file__).resolve().parent
OUT=LAB/'build/Analysis'; OUT.mkdir(parents=True,exist_ok=True)
files=[p for p in sorted((LAB/'build/Captures').glob('tapping-*.json')) if json.loads(p.read_text()).get('completed')]
if not files:raise SystemExit('No completed tap captures.')
binary=LAB/'build/tap-replay'
subprocess.run(['xcrun','swiftc','-O','-parse-as-library',str(ROOT/'Sentient OS macOS/Notch Magic/PhysicalTapDetector.swift'),str(ROOT/'Sentient OS macOS/Notch Magic/PhysicalMissedTapDetector.swift'),str(LAB/'Tests/TapReplay.swift'),'-o',str(binary)],check=True)
def replay(shift=0):
 env=dict(os.environ,TAP_REPLAY_MOTION_SHIFT=str(shift),TAP_REPLAY_SENSITIVITY='1.1')
 output=subprocess.check_output([str(binary),*map(str,files)],env=env,text=True)
 (OUT/('tap-replay.jsonl' if not shift else 'tap-shifted-replay.jsonl')).write_text(output)
 return {x['file']:x['detections'] for x in map(json.loads,output.splitlines())}
actual=replay();shifted=replay(2)
summary={'method':'Exact production Swift replay in callback arrival order. Cue matching window -0.3 to +3.5 s, not measured contact time. First two runs only: at most two dips below half the within-run median depth marked possible missed targets, per user correction; no raw data removed. Two-second motion shift is a diagnostic time-mismatch stress test, not a measured false-positive rate.', 'runs':[]}
fig,axes=plt.subplots(len(files),1,figsize=(15,3*len(files)),layout='constrained',squeeze=False)
for index,p in enumerate(files):
 meta=json.loads(p.read_text());rows=list(csv.DictReader((p.parent/meta['als_file']).open()))
 t=np.array([float(r['seconds']) for r in rows]);lux=np.array([float(r['lux']) for r in rows]);trials=[]
 for cue in meta['cues']:
  c=cue['ui_update_seconds'];baseline=float(np.median(lux[(t>=c-1)&(t<c)]));w=(t>=c-.3)&(t<c+3.5)
  minimum=float(min(lux[w]));depth=max(0,1-minimum/max(.001,baseline))
  hits=[h for h in actual[p.name] if c-.3<=h<c+3.5]
  trials.append({'trial':cue['trial'],'cue':c,'baseline_lux':baseline,'minimum_lux':minimum,'dip_fraction':depth,'detections':hits,'possible_missed_target':False})
 median=float(np.median([r['dip_fraction'] for r in trials]))
 if index<2:
  weak=sorted([r for r in trials if r['dip_fraction']<median*.5],key=lambda r:r['dip_fraction'])[:2]
  for r in weak:r['possible_missed_target']=True
 retained=[r for r in trials if not r['possible_missed_target']]
 matched=sum(bool(r['detections']) for r in trials);kept=sum(bool(r['detections']) for r in retained)
 result={'file':p.name,'lighting':meta.get('lighting_label',''),'on_lap':meta.get('on_lap',False),'native_als_hz':meta['native_als_hz'],'motion_hz':meta['motion_hz'],
  'all_trials_matched':matched,'all_trials':len(trials),'retained_matched':kept,'retained_trials':len(retained),'shifted_motion_detections':shifted[p.name],'detections':actual[p.name],
  'extra_detections':sum(max(0,len(r['detections'])-1) for r in trials)+sum(not any(r['cue']-.3<=h<r['cue']+3.5 for r in trials) for h in actual[p.name]),'trials':trials}
 summary['runs'].append(result)
 ax=axes[index,0];ax.step(t,lux,where='post',color='#ad7100',lw=1.5,label='Native light')
 for r in trials:
  ax.axvline(r['cue'],color='#777',lw=.6,alpha=.35)
  if r['possible_missed_target']:ax.axvspan(r['cue'],r['cue']+3.5,color='#ccc',alpha=.35)
 for n,h in enumerate(actual[p.name]):ax.axvline(h,color='#168781',alpha=.7,lw=1,label='Candidate fires' if n==0 else None)
 label=meta.get('lighting_label') or 'First location (unlabelled)'
 ax.set_title(f"{index+1}. {label} — replay {matched}/10; excluding possible misses {kept}/{len(retained)}",loc='left',fontsize=11)
 ax.set(ylabel='Lux',xlim=(0,45));ax.grid(alpha=.12);ax.legend(loc='upper right',fontsize=8)
 print(f"Run {index+1}: {matched}/10 all cues; {kept}/{len(retained)} retained; possible missed targets {[r['trial'] for r in trials if r['possible_missed_target']]}; shifted-motion triggers {len(shifted[p.name])}")
axes[-1,0].set_xlabel('Seconds from experiment start; gray spans = provisional missed targets')
fig.suptitle('Light-led tap candidate: recorded-data replay, not a validated accuracy estimate',fontsize=15)
fig.savefig(OUT/'tapping-results.png',dpi=140);plt.close(fig)
summary['total']={k:sum(r[k] for r in summary['runs']) for k in ['all_trials_matched','all_trials','retained_matched','retained_trials','extra_detections']}
summary['limitations']=['Four completed captures, forty cues, one person and one Mac.','Parameters explored on these recordings: these are development/replay results, not held-out validation.','The first two runs contain user-reported misses without exact cue labels; exclusions are provisional.','Earlier ALS-only negative controls cannot establish combined-detector specificity.','Near-noise-floor motion can coincide with optical dips. Shifted-motion triggers show corroboration is not contact proof.','Ambient samples about 202 ms apart limit timing; device report stamps are not optical integration timestamps.']
(OUT/'tapping-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(summary['total']);print(OUT/'tapping-results.png')
