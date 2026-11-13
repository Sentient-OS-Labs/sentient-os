#!/usr/bin/env python3
"""Render both proposed island color treatments in an isolated native app fixture."""
import argparse
from pathlib import Path
import tempfile
import struct
import shutil
import test_sidekick_app as app

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--selected-design', action='store_true')
parser.add_argument('--done-preview', action='store_true')
parser.add_argument('--layout-refinement', action='store_true')
parser.add_argument('--hardware-island', action='store_true')
parser.add_argument('--logo-reference', type=Path)
parser.add_argument('--motion', action='store_true')
parser.add_argument('--response-motion', action='store_true')
parser.add_argument('--completion-motion', action='store_true')
parser.add_argument('--island-motion', action='store_true')
args = parser.parse_args()
_, executable = app.resolve_app(args.app)
root = Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-colors-')).resolve()
root.chmod(0o700)
(root / app.MARKER).write_text('1\n')
(root / 'vault').mkdir(mode=0o700)
fixture = app.fixture(root, 'chatgpt')
if args.done_preview:
    (root / 'done-preview').touch()
if args.layout_refinement:
    (root / 'layout-refinement').touch()
if args.hardware_island:
    (root / 'layout-refinement').touch()
    (root / 'hardware-island').touch()
if args.selected_design:
    (root / 'selected-underlight').touch()
if args.completion_motion:
    args.motion = True
    (root / 'completion-motion').touch()
if args.response_motion:
    args.motion = True
    (root / 'response-motion').touch()
if args.island_motion:
    args.motion = True
    (root / 'island-motion').touch()
if args.logo_reference:
    shutil.copy2(args.logo_reference, root / 'website-logo.png')
runtime = (Path.home() / 'Library/Application Support/SentientOS/Private Codex').resolve()
print('Color preview: ' + str(root), flush=True)
app.run_stage(executable, root, fixture, runtime, 'seed', 45)
app.run_stage(executable, root, fixture, runtime, 'ui-notch-motion' if args.motion else 'ui-island-colors', 120)
if args.motion:
    print(str(root / 'motion-snapshots'), flush=True)
    raise SystemExit(0)
for image in (root / 'color-previews').glob('*.png'):
    width, height = struct.unpack('>II', image.read_bytes()[16:24])
    app.require(width >= (1040 if args.done_preview else 1280) and height >= (500 if args.done_preview else 700), 'Preview was minimized during capture')
print(str(root / 'color-previews/comparison.png'), flush=True)
