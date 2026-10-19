#!/usr/bin/env python3
"""Signed-app diagnostic checks on owned controls, with DEBUG-only injected failures.
No user-app actions, TCC changes, provider requests or report uploads.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--keep-open', type=int, default=0, help='Keep the final successful window open for visual review')
args = parser.parse_args()
app = args.app.resolve()
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
executable = app/'Contents/MacOS'/info['CFBundleExecutable']
root = Path(tempfile.mkdtemp(prefix='sentient-repair-live-'))
(root/'evidence').mkdir()
print('Evidence:', root, flush=True)
for fault, outcome in [('disconnect','repaired'), ('persistent','needsAttention'), ('permission','permissionsNeeded'),
                       ('focus','interrupted'), ('cancel','cancelled'), ('none','passed')]:
    env = dict(os.environ, SENTIENT_SELFTEST='nativecua', LAB_ROOT=str(root), LAB_COMMAND='doctor', LAB_NAME=fault,
               LAB_DIAGNOSTIC_FAULT=fault)
    hold = min(max(args.keep_open, 0), 300) if fault == 'none' else 0
    if hold: env['LAB_KEEP_OPEN'] = str(hold)
    with (root/(fault+'.log')).open('w') as log:
        subprocess.run([str(executable)], env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60+hold)
    receipt = json.loads((root/'evidence'/f'{fault}.json').read_text())
    report = receipt.get('diagnostic', {})
    assert 'error' not in receipt, receipt.get('error')
    assert report.get('outcome') == outcome, report
    assert report['repairVerified'] == (fault == 'disconnect'), report
    if fault in ['permission','focus','cancel']: assert not report['repairAttempted'], report
    if outcome in ['repaired','passed']:
        checks = {step['check']:step['status'] for step in report['steps']}
        assert all(checks.get(key) == 'passed' for key in ['runtime','permissions','connection','accessibility','capture','click','textEntry']), checks
    assert not any(step['status'] == 'running' for step in report['steps']), report
    print(f'PASS: {fault} -> {outcome}; repair_verified={report["repairVerified"]}', flush=True)
print('PASS: six real-window diagnostic outcomes; no uploads or user-app actions', flush=True)
