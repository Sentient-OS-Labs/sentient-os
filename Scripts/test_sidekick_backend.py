#!/usr/bin/env python3
"""Run Sidekick's production-code backend fixtures. No real accounts, model calls or UI.

Each suite compiles complete production types and uses temporary data. The signed-app
SidekickBackendLab is a separate, explicitly selected real-CLI acceptance layer.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys

SCRIPTS = Path(__file__).resolve().parent
SUITES = [
    'test_sidekick_conversation.py',
    'test_sidekick_transcript.py',
    'test_sidekick_migration.py',
    'test_sidekick_run.py',
    'test_sidekick_memory.py',
    'test_sidekick_tools.py',
    'test_sidekick_context.py',
    'test_sidekick_lifecycle.py',
    'test_sidekick_diagnostics.py',
]


def run(name):
    try:
        result = subprocess.run([sys.executable, str(SCRIPTS / name)],
                                capture_output=True, text=True, timeout=240)
        return name, result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return name, 1, 'Suite exceeded its 240-second deadline.'


if __name__ == '__main__':
    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(run, SUITES))
    for name, code, output in results:
        print(f'{"PASS" if code == 0 else "FAIL"} {name}')
        print(output.strip())
    failed = sum(code != 0 for _, code, _ in results)
    print(f'{len(SUITES) - failed}/{len(SUITES)} Sidekick backend suites passed')
    sys.exit(bool(failed))
