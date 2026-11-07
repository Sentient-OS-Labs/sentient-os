#!/usr/bin/env python3
"""Opt-in real Sidekick routing to the summary and proofread services. Read-only tasks."""
import argparse,json,tempfile
from pathlib import Path
import test_sidekick_app as app
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',type=Path,required=True);p.add_argument('--live',action='store_true');p.add_argument('--provider',choices=['claude','chatgpt'],default='claude');p.add_argument('--artifacts',type=Path,default=Path('/tmp/sentient-sidekick-quick-actions'))
a=p.parse_args()
if not a.live:p.error('Use --live to authorize the provider and the open Safari page summary.')
_,exe=app.resolve_app(a.app);a.artifacts.mkdir(parents=True,exist_ok=True)
root=Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-quick-actions-',dir=a.artifacts)).resolve();root.chmod(0o700)
(root/app.MARKER).write_text('1\n');(root/'vault').mkdir(mode=0o700);(root/'allow-live-quick-actions').write_text('1\n')
fixture=app.fixture(root,a.provider);runtime=Path.home()/'Library/Application Support/SentientOS/Private Codex'
print('Live fixture:',root,flush=True)
app.run_stage(exe,root,fixture,runtime,'seed',45)
r=app.run_stage(exe,root,fixture,runtime,'live-quick-actions',420)
print(json.dumps({'passed':True,'root':str(root),'checks':len(r['checks'])},indent=2))
