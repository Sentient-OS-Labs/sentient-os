#!/usr/bin/env python3
"""Descriptive, cue-aligned analysis; repeated HID polls are not independent samples."""
import argparse
import csv
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--captures',type=Path,default=Path(__file__).resolve().parent/'build/Captures')
parser.add_argument('--out',type=Path,default=Path(__file__).resolve().parent/'build/Analysis')
args=parser.parse_args();args.out.mkdir(parents=True,exist_ok=True)
runs=[]
for meta_path in sorted(args.captures.glob('experiment-*.json')):
    meta=json.loads(meta_path.read_text())
    if not meta.get('completed') or len(meta.get('cues',[]))!=meta['tap_count']:continue
    rows=list(csv.DictReader(meta_path.with_suffix('.csv').open()))
    rows=[r for r in rows if r['report7_degrees']]
    t=np.array([float(r['seconds']) for r in rows]);a=np.array([float(r['report7_degrees']) for r in rows]);coarse=np.array([float(r['report1_degrees']) for r in rows])
    changed=np.r_[True,np.diff(a)!=0]
    ct,ca=t[changed],a[changed]
    # Last observed value in each 100 ms bin: no interpolation or invented decimals.
    bin_id=np.floor(t*10).astype(int)
    last=np.r_[np.flatnonzero(np.diff(bin_id)!=0),len(t)-1]
    bt,ba=t[last],a[last]
    base=(bt>=.5)&(bt<4.8)
    baseline=ba[base]
    stats={'file':meta_path.name,'poll_hz':meta['achieved_poll_hz'],'poll_count':len(t),
           'value_changes':int(changed.sum()-1),'median_change_interval_ms':float(np.median(np.diff(ct))*1000),
           'poll_interval_p50_ms':float(np.quantile(np.diff(t),.5)*1000),'poll_interval_p99_ms':float(np.quantile(np.diff(t),.99)*1000),
           'baseline_100ms_bins':int(base.sum()),'baseline_min':float(baseline.min()),'baseline_max':float(baseline.max()),
           'baseline_sd':float(baseline.std(ddof=1)),'baseline_peak_to_peak':float(np.ptp(baseline)),
           'coarse_values':np.unique(coarse).tolist(),'cues':[]}
    traces=[]
    for cue in meta['cues']:
        c=cue['ui_update_seconds']
        pre=(bt>c-1)&(bt<c-.15)
        ref=float(np.median(ba[pre]))
        post=(t>=c)&(t<c+1.5)
        v=a[post];tt=t[post];j=int(np.argmax(abs(v-ref)))
        settled=(bt>c+2)&(bt<c+3.5)
        stats['cues'].append({'tap':cue['tap'],'cue_s':c,'pre_median':ref,
             'peak_delta_deg':float(v[j]-ref),'peak_delay_s':float(tt[j]-c),
             'remaining_shift_deg':float(np.median(ba[settled])-ref),'post_min':float(v.min()),'post_max':float(v.max())})
        z=(ct>c-1)&(ct<c+3.5)
        traces.append((ct[z]-c,ca[z]-ref))
    runs.append((meta,t,a,ct,ca,stats,traces))
if not runs:raise SystemExit('No complete experiments yet.')

fig,axes=plt.subplots(len(runs),2,figsize=(14,3.7*len(runs)),squeeze=False,layout='constrained',gridspec_kw={'width_ratios':[1.6,1]})
colors=plt.get_cmap('tab10').colors
for i,(meta,t,a,ct,ca,stats,traces) in enumerate(runs):
    ax=axes[i,0]
    ax.step(ct,ca,where='post',color='#087f8c',lw=1.2)
    ax.axvspan(0,5,color='#d9e8f3',alpha=.65,label='Untouched baseline')
    for cue in stats['cues']:
        ax.axvline(cue['cue_s'],color='#bc6c25',lw=.9,ls='--',alpha=.8)
        ax.text(cue['cue_s'],1.015,str(cue['tap']),transform=ax.get_xaxis_transform(),ha='center',fontsize=9,color='#92511c')
    ax.set(xlim=(0,29),xlabel='Seconds since Start experiment',ylabel='Report 7 angle (degrees)')
    ax.set_title(f"Run {i+1} · {stats['poll_hz']:.1f} polls/s · baseline σ {stats['baseline_sd']:.3f}°",loc='left',pad=22)
    ax.ticklabel_format(axis='y',style='plain',useOffset=False)
    ax.grid(alpha=.16)
    bx=axes[i,1]
    # The band is descriptive baseline variability, not a confidence interval.
    sd=stats['baseline_sd']
    bx.axhspan(-3*sd,3*sd,color='#e7e7e7',label='±3 baseline SD (descriptive)')
    for j,(x,y) in enumerate(traces):bx.step(x,y,where='post',lw=1.2,color=colors[j],label=f'Tap {j+1}')
    bx.axvline(0,color='#333',lw=.8,ls='--')
    bx.set(xlim=(-.8,3.4),xlabel='Seconds relative to TAP cue',ylabel='Change from local pre-cue median (degrees)')
    bx.set_title('Cue-aligned responses · no smoothing',loc='left',pad=22)
    bx.grid(alpha=.16)
    bx.legend(fontsize=8,ncol=3,loc='upper right')
fig.suptitle('Lid-only tap experiments: sensor signal versus untouched noise',fontsize=16)
fig.savefig(args.out/'lid-experiments.png',dpi=170)
plt.close(fig)
summary=[run[5] for run in runs]
(args.out/'summary.json').write_text(json.dumps({'method':'Statistics use last observation per 100 ms bin. Graphs use unsmoothed changes. Cue time is UI state-update time, not finger-contact time. ±3 SD is descriptive, not a confidence interval.','runs':summary},indent=2)+'\n')
with (args.out/'tap-metrics.csv').open('w') as f:
    fields=['run','tap','cue_s','pre_median','peak_delta_deg','peak_delay_s','remaining_shift_deg','post_min','post_max']
    writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader()
    for i,run in enumerate(summary,1):
        for cue in run['cues']:writer.writerow({'run':i,**cue})
for i,r in enumerate(summary,1):
    print(f"Run {i}: {r['poll_count']} polls, {r['poll_hz']:.1f} Hz; median changed-value interval {r['median_change_interval_ms']:.1f} ms; untouched range {r['baseline_min']:.2f}–{r['baseline_max']:.2f}°, SD {r['baseline_sd']:.3f}°")
    for c in r['cues']:print(f"  tap {c['tap']}: peak {c['peak_delta_deg']:+.3f}° at {c['peak_delay_s']:.3f}s; remaining shift {c['remaining_shift_deg']:+.3f}°")
print(args.out/'lid-experiments.png')

# User-directed second pass: remove conspicuous lasting hinge shifts, retain smaller taps.
# This is descriptive separation on this session, not a trained or held-out detector evaluation.
small=[];quiet=[];excluded=[];curves=[];small_no_shift=[]
grid=np.arange(-.8,3.41,.1)

def window_feature(t,a,bt,ba,cue):
    before=(bt>=cue-1)&(bt<cue-.15)
    reference=float(np.median(ba[before]))
    after=(t>=cue)&(t<cue+1.5)
    return round(float(np.max(np.abs(a[after]-reference))),6), reference

for run_index,(meta,t,a,ct,ca,stats,traces) in enumerate(runs,1):
    ix=np.r_[np.flatnonzero(np.diff(np.floor(t*10))!=0),len(t)-1]
    bt,ba=t[ix],a[ix]
    for cue in stats['cues']:
        if abs(cue['remaining_shift_deg'])>.25:
            excluded.append({'run':run_index,'tap':cue['tap'],'remaining_shift_deg':cue['remaining_shift_deg']})
            continue
        peak,ref=window_feature(t,a,bt,ba,cue['cue_s'])
        small.append({'run':run_index,'tap':cue['tap'],'peak':peak,'remaining_shift':cue['remaining_shift_deg']})
        if abs(cue['remaining_shift_deg'])<=.075:small_no_shift.append(peak)
        indices=np.clip(np.searchsorted(t,cue['cue_s']+grid,side='right')-1,0,len(t)-1)
        curves.append(a[indices]-ref)
        control,_=window_feature(t,a,bt,ba,cue['cue_s']+2)
        quiet.append(control)
    for control_time in [1.5,3.0]:
        control,_=window_feature(t,a,bt,ba,control_time)
        quiet.append(control)

p=np.array([x['peak'] for x in small]);q=np.array(quiet)
cutoffs=[]
for threshold in [.06,.08,.10,.12,.15]:
    cutoffs.append({'threshold_deg':threshold,'small_taps_above':int(np.sum(p>=threshold)),
                    'small_taps_total':len(p),'quiet_windows_above':int(np.sum(q>=threshold)),
                    'quiet_windows_total':len(q)})
result={'excluded_large_shifts':excluded,'small_taps':small,'quiet_peak_excursions':quiet,'cutoff_examples':cutoffs,
        'small_tap_peak_median':float(np.median(p)),'quiet_peak_median':float(np.median(q)),
        'small_tap_peak_range':[float(p.min()),float(p.max())],'quiet_peak_range':[float(q.min()),float(q.max())],
        'minor_shift_sensitivity_check':{'remaining_shift_cutoff':.075,'n':len(small_no_shift),
                                      'peak_median':float(np.median(small_no_shift))},
        'limitations':['Cue times are not measured finger-contact times.','Quiet windows come from the same runs and are not statistically independent trials.','Threshold examples are illustrative on these data, not prospective accuracy estimates.','No desk-tap or hard-typing negative-control run was collected.']}
(args.out/'gentle-analysis.json').write_text(json.dumps(result,indent=2)+'\n')
fig,(ax,bx)=plt.subplots(1,2,figsize=(13,4.9),layout='constrained',gridspec_kw={'width_ratios':[1.65,1]})
noise_limit=float(q.max())
ax.axhspan(-noise_limit,noise_limit,color='#e3e5e7',label=f'Observed quiet-window envelope (±{noise_limit:.2f}°)')
for trace in curves:ax.step(grid,trace,where='post',color='#208f9b',alpha=.27,lw=.85)
ax.step(grid,np.median(np.array(curves),axis=0),where='post',color='#064f5b',lw=2.2,label='Median of retained tap responses')
ax.axvline(0,color='#b56225',ls='--',lw=1,label='TAP cue')
ax.set(xlabel='Seconds relative to the cue',ylabel='Angle change from pre-cue median (degrees)',xlim=(-.8,3.4),ylim=(-.13,.18))
ax.set_title(f'{len(small)} smaller taps after excluding {len(excluded)} large hinge shifts',loc='left')
ax.legend(fontsize=8,loc='upper right');ax.grid(alpha=.13)
for x,values,color in [(0,q,'#72797e'),(1,p,'#087f8c')]:
    jitter=np.linspace(-.13,.13,len(values))
    bx.scatter(x+jitter,values,s=28,color=color,alpha=.75,edgecolors='white',linewidths=.4)
    bx.plot([x-.22,x+.22],[np.median(values)]*2,color=color,lw=2)
bx.set(xticks=[0,1],xticklabels=[f'Quiet windows\n(n={len(q)})',f'Smaller tap windows\n(n={len(p)})'],ylabel='Largest excursion in the next 1.5 seconds (degrees)',ylim=(0,.18),xlim=(-.5,1.5))
bx.set_title('The signal distributions overlap',loc='left');bx.grid(axis='y',alpha=.13)
fig.suptitle('Lid-only tap signal versus noise',fontsize=16)
fig.savefig(args.out/'lid-small-taps.png',dpi=180)
plt.close(fig)
print('Gentle analysis:',json.dumps({k:result[k] for k in ['small_tap_peak_median','quiet_peak_median','small_tap_peak_range','quiet_peak_range','cutoff_examples','minor_shift_sensitivity_check']}))
