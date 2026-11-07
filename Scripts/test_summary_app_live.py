#!/usr/bin/env python3
"""Live signed-app summary windows using open browser/Claude documents and prepared Preview PDFs."""
import argparse,json,os,tempfile,shutil
from pathlib import Path
import test_sidekick_app as app
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',type=Path,required=True)
p.add_argument('--live',action='store_true')
p.add_argument('--youtube-only',action='store_true')
p.add_argument('--cases',type=Path,help='Explicit app/window capture audit cases; may include opt-in live inference')
p.add_argument('--artifacts',type=Path,default=Path('/tmp/sentient-summary-app-live'))
a=p.parse_args()
if not a.live:p.error('This sends real open document text to the summary relay; use --live to authorize.')
_,executable=app.resolve_app(a.app)
a.artifacts.mkdir(parents=True,exist_ok=True)
root=Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-summary-live-',dir=a.artifacts)).resolve()
root.chmod(0o700);(root/app.MARKER).write_text('1\n');(root/'vault').mkdir(mode=0o700)
fixture=app.fixture(root,'chatgpt')
runtime=(Path.home()/'Library/Application Support/SentientOS/Private Codex').resolve()
(root/'allow-live-summary').write_text('authorized\n')
if a.youtube_only:(root/'youtube-only').write_text('1')
if a.cases:shutil.copy2(a.cases,root/'summary-audit-cases.json')
print('Live app fixture:',root,flush=True)
app.run_stage(executable,root,fixture,runtime,'seed',45)
receipt=app.run_stage(executable,root,fixture,runtime,'live-summary',360)
print(json.dumps({'passed':True,'root':str(root),'checks':len(receipt['checks'])},indent=2))
