#!/usr/bin/env python3
"""Capture production proofread views in the existing isolated signed-app UI fixture."""
import argparse
import json
from pathlib import Path
import tempfile
import test_sidekick_app as app

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--artifacts',type=Path,default=Path(tempfile.gettempdir())/'sentient-proofread-ui')
    parser.add_argument('--hold-seconds',type=int,default=0,choices=range(301))
    args=parser.parse_args()
    _,executable=app.resolve_app(args.app)
    artifacts=args.artifacts.resolve();artifacts.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-proofread-',dir=artifacts)).resolve()
    root.chmod(0o700);(root/app.MARKER).write_text('1\n');(root/'vault').mkdir(mode=0o700)
    if args.hold_seconds: (root/'proofread-hold-seconds').write_text(str(args.hold_seconds))
    fixture=app.fixture(root,'chatgpt')
    runtime=(Path.home()/'Library/Application Support/SentientOS/Private Codex').resolve()
    print('Proofread fixture: '+str(root),flush=True)
    app.run_stage(executable,root,fixture,runtime,'seed',45)
    receipt=app.run_stage(executable,root,fixture,runtime,'ui-proofread',45+args.hold_seconds)
    manifest=app.read_json(root/'proofread-manifest.json')
    app.require(manifest['provider_calls']==0 and manifest['native_error_type']=='none','Fixture used a live service')
    app.require(len(manifest['captures']) in [2,4],'Missing proofread editor and notch states')
    for item in manifest['captures']:
        path=root/'proofread-snapshots'/(item['name']+'.png')
        app.require(path.is_file() and path.stat().st_size>4096,'Missing UI rendering')
    print(json.dumps({'passed':True,'root':str(root),'checks':len(receipt['checks']), 'captures':len(manifest['captures']), 'native_edit_tested':manifest['native_edit_tested']},indent=2))

if __name__=='__main__': main()
