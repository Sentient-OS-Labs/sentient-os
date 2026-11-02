#!/usr/bin/env python3
"""Render actual connector route/repair controls in a signed, process-isolated DEBUG app.

Uses synthetic hosted records only. Never clicks sign-in, performs OAuth, reads a
provider, changes real preferences, or captures another application's window.
"""
import argparse
import json
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
import test_sidekick_app as app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path, default=Path(tempfile.gettempdir()) / 'sentient-connector-setup-ui')
    args = parser.parse_args()
    root = None
    try:
        _, executable = app.resolve_app(args.app)
        artifacts = args.artifacts.expanduser().resolve()
        artifacts.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix='sentient-sidekick-app-connectors-', dir=artifacts)).resolve()
        root.chmod(0o700)
        (root / app.MARKER).write_bytes(b'1\n')
        (root / 'vault').mkdir(mode=0o700)
        fixture = app.fixture(root, 'claude')
        runtime = Path.home() / 'Library/Application Support/SentientOS/Private Codex'
        app.run_stage(executable, root, fixture, runtime, 'seed', 60)
        receipt = app.run_stage(executable, root, fixture, runtime, 'ui-connector-setup', 90)
        report = app.read_json(root / 'connector-setup-manifest.json')
        app.require(report.get('completed') is True and report.get('provider_calls') == 0
                    and report.get('oauth_actions') == 0, 'Connector fixture did not complete safely')
        captures = report.get('captures', [])
        app.require(len(captures) == 7 and report.get('capture_scope') == 'current_process_windows_only',
                    'Unexpected connector capture scope')
        for capture in captures:
            image = (root / capture['file']).resolve()
            app.require(image.parent == root / 'connector-snapshots'
                        and image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                        and image.stat().st_size > 4096, 'Invalid owned connector capture')
        result = {'passed': True, 'root': str(root), 'checks': len(receipt['checks']),
                  'captures': [str(root / item['file']) for item in captures]}
        app.save_json(root / 'connector-setup-runner-result.json', result)
        print(json.dumps(result, indent=2))
        return 0
    except (app.AcceptanceFailure, OSError, ValueError) as error:
        print(f'FAIL: {error}')
        if root:
            app.save_json(root / 'connector-setup-runner-result.json', {'passed': False, 'root': str(root), 'error': str(error)})
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
