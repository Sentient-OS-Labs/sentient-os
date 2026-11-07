#!/usr/bin/env python3
"""Stress Home/notch/display handoffs in the production signed app with isolated state."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import test_sidekick_app as app

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--runs', type=int, default=1)
args = parser.parse_args()
_, executable = app.resolve_app(args.app)
original_stop = app.stop_owned

def stop_with_sample(process, root):
    if process.poll() is None:
        subprocess.run(['sample', str(process.pid), '3', '1', '-file', str(root / 'timeout-sample.txt')],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
    original_stop(process, root)
app.stop_owned = stop_with_sample
for index in range(args.runs):
    root = Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-switching-')).resolve()
    root.chmod(0o700); (root / app.MARKER).write_text('1\n'); (root / 'vault').mkdir(mode=0o700)
    fixture = app.fixture(root, 'chatgpt')
    runtime = (Path.home() / 'Library/Application Support/SentientOS/Private Codex').resolve()
    print('Switching fixture: ' + str(root), flush=True)
    app.run_stage(executable, root, fixture, runtime, 'seed', 45)
    receipt = app.run_stage(executable, root, fixture, runtime, 'ui-surface-switching', 75)
    print(json.dumps({'run': index + 1, 'passed': True, 'checks': len(receipt['checks']),
                      'transitions': int((root / 'surface-switch-progress.txt').read_text()), 'root': str(root)}), flush=True)
