#!/usr/bin/env python3
"""Record the real notch/island surfaces through voice transitions with no microphone or provider."""
import argparse,json,tempfile
from pathlib import Path
import test_sidekick_app as app
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--app',type=Path,required=True);p.add_argument('--artifacts',type=Path,default=Path('/tmp/sentient-voice-continuity'))
a=p.parse_args();_,executable=app.resolve_app(a.app)
a.artifacts.mkdir(parents=True,exist_ok=True)
root=Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-voice-continuity-',dir=a.artifacts)).resolve()
root.chmod(0o700);(root/app.MARKER).write_text('1\n');(root/'vault').mkdir(mode=0o700)
fixture=app.fixture(root,'chatgpt');runtime=(Path.home()/'Library/Application Support/SentientOS/Private Codex').resolve()
print('Voice continuity fixture:',root,flush=True)
app.run_stage(executable,root,fixture,runtime,'seed',45)
r=app.run_stage(executable,root,fixture,runtime,'ui-voice-continuity',90)
print(json.dumps({'passed':True,'root':str(root),'checks':len(r['checks'])},indent=2))
