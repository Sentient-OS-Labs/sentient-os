#!/usr/bin/env python3
"""Render physical-tap Settings and Lumen in an isolated signed-app fixture; no live agent or sensor."""
import argparse
from pathlib import Path
import tempfile
import test_sidekick_app as app

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--live-sensor', action='store_true', help='Read real sensors without dispatching any actions')
args = parser.parse_args()
_, executable = app.resolve_app(args.app)
root = Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-physical-tap-')).resolve()
root.chmod(0o700)
(root / app.MARKER).write_text('1\n')
(root / 'vault').mkdir(mode=0o700)
fixture = app.fixture(root, 'chatgpt')
runtime = (Path.home() / 'Library/Application Support/SentientOS/Private Codex').resolve()
print(root, flush=True)
app.run_stage(executable, root, fixture, runtime, 'seed', 45)
app.run_stage(executable, root, fixture, runtime, 'ui-physical-tap', 60)
if args.live_sensor:
    app.run_stage(executable, root, fixture, runtime, 'live-physical-sensor', 45)
print(root / 'physical-tap-settings.png', flush=True)
