#!/usr/bin/env python3
"""Capture production dictation views in the existing isolated signed-app UI fixture."""
import argparse
import json
from pathlib import Path
import tempfile
import test_sidekick_app as app

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--view-snapshot',action='store_true')
    parser.add_argument('--artifacts',type=Path,default=Path(tempfile.gettempdir())/'sentient-dictation-ui')
    args=parser.parse_args()
    _,executable=app.resolve_app(args.app)
    artifacts=args.artifacts.resolve();artifacts.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-dictation-',dir=artifacts)).resolve()
    root.chmod(0o700);(root/app.MARKER).write_text('1\n');(root/'vault').mkdir(mode=0o700)
    fixture=app.fixture(root,'chatgpt')
    if args.view_snapshot: (root/'view-raster-capture').touch()
    runtime=(Path.home()/'Library/Application Support/SentientOS/Private Codex').resolve()
    print('Dictation fixture: '+str(root),flush=True)
    app.run_stage(executable,root,fixture,runtime,'seed',45)
    receipt=app.run_stage(executable,root,fixture,runtime,'ui-dictation',45)
    manifest=app.read_json(root/'dictation-manifest.json')
    app.require(manifest['provider_calls']==0 and manifest['microphone_used'] is False,'Fixture used a live service')
    app.require(len(manifest['captures'])>=15,'Missing dictation states')
    for item in manifest['captures']:
        path=root/'dictation-snapshots'/(item['name']+'.png')
        app.require(path.is_file() and path.stat().st_size>4096,'Missing UI rendering')
    print(json.dumps({'passed':True,'root':str(root),'checks':len(receipt['checks']), 'captures':len(manifest['captures'])},indent=2))

if __name__=='__main__': main()
