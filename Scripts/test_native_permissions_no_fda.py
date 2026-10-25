#!/usr/bin/env python3
"""Run signed native capability admission while Seatbelt denies TCC database reads.

Copies only pinned CLI/helper code into a disposable canonical runtime. Does not copy auth,
configuration, sessions or user data; does not request, grant or reset permissions. Existing
Automation and helper AX/capture grants are required. Refuses a competing running helper.
The only native read targets the lab's own synthetic window. No model calls or screenshots saved.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile


def verify_artifact(directory, artifact):
    expected = {}
    for item in artifact['files']:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError('Unsafe artifact manifest path')
        expected[item['path']] = item
    actual = set()
    for entry in directory.rglob('*'):
        if entry.is_symlink():
            raise RuntimeError('Pinned artifacts cannot contain symlinks')
        if entry.is_dir():
            continue
        if not entry.is_file():
            raise RuntimeError('Pinned artifact contains a special file')
        relative = str(entry.relative_to(directory))
        actual.add(relative)
        item = expected.get(relative)
        if item is None:
            raise RuntimeError('Pinned artifact has an unexpected file')
        stat = entry.stat()
        if stat.st_size != item['bytes'] or bool(stat.st_mode & 0o111) != item['executable']:
            raise RuntimeError('Pinned artifact size/mode mismatch')
        digest = hashlib.sha256()
        with entry.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        if digest.hexdigest() != item['sha256']:
            raise RuntimeError('Pinned artifact hash mismatch')
    if actual != set(expected):
        raise RuntimeError('Pinned artifact inventory mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='Existing signed Debug app; never re-signed by this runner')
    parser.add_argument('--runtime-source', type=Path, default=Path.home()/'Library/Application Support/SentientOS/Private Codex',
                        help='Code artifact source only; auth/config/session files are never read or copied')
    args = parser.parse_args()
    app = args.app.expanduser().resolve()
    source = args.runtime_source.expanduser().resolve()
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    executable = app/'Contents/MacOS'/info['CFBundleExecutable']
    manifest = json.loads((app/'Contents/Resources/BundledCodexRelease.json').read_text())
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
    # The lab never takes over a foreign helper: do not interrupt another live client's work.
    process_names = subprocess.check_output(['/bin/ps','-axo','comm='],text=True).splitlines()
    if any(Path(line.strip()).name == 'SkyComputerUseService' for line in process_names):
        raise RuntimeError('A computer-use helper is already running. Finish its owning client before this isolated check.')
    root = Path(tempfile.mkdtemp(prefix='sentient-permission-nofda-')).resolve()
    root.chmod(0o700)
    (root/'.native-permission-fixture').write_text('1\n')
    (root/'evidence').mkdir(mode=0o700)
    runtime = root/'runtime'
    cli_name = 'cli-' + manifest['cli']['version']
    artifacts = [(source/'releases'/cli_name, runtime/'releases'/cli_name, manifest['cli']),
                 (source/'.codex/computer-use/Codex Computer Use.app',runtime/'.codex/computer-use/Codex Computer Use.app',manifest['helper'])]
    for original, copied, artifact in artifacts:
        verify_artifact(original, artifact)
        copied.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        shutil.copytree(original,copied,symlinks=True)
        verify_artifact(copied, artifact)
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',
                    '--test-requirement==anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"',str(artifacts[1][1])],check=True)
    profile = root/'deny-tcc.sb'
    profile.write_text('''(version 1)
(allow default)
(deny file-read* (subpath (param "SYSTEM_TCC")) (subpath (param "USER_TCC")) (subpath (param "REAL_APP_SUPPORT")))
(deny file-write* (subpath (param "REAL_APP_SUPPORT")) (literal (param "REAL_PREFERENCES"))
    (literal "/tmp/sentient-dev.log") (literal "/private/tmp/sentient-dev.log"))
''')
    environment = {key:value for key,value in os.environ.items() if key in ['HOME','USER','LOGNAME','TMPDIR','PATH','LANG','LC_ALL']}
    environment.update(SENTIENT_SELFTEST='nativecua',LAB_COMMAND='permission-readiness',LAB_NAME='permission-readiness',
                       LAB_ROOT=str(root),SENTIENT_CODEX_RUNTIME_ROOT=str(runtime),LAB_DENY_TCC_REQUIRED='1',
                       LAB_CUA_CACHE=str(root/'cua-cache'))
    command = ['/usr/bin/sandbox-exec','-f',str(profile),'-D','SYSTEM_TCC=/Library/Application Support/com.apple.TCC',
               '-D','USER_TCC='+str(Path.home()/'Library/Application Support/com.apple.TCC'),
               '-D','REAL_APP_SUPPORT='+str(Path.home()/'Library/Application Support/SentientOS'),
               '-D','REAL_PREFERENCES='+str(Path.home()/'Library/Preferences'/(info['CFBundleIdentifier']+'.plist')),str(executable)]
    print('Isolated evidence:',root,flush=True)
    with (root/'run.log').open('wb') as output:
        process = subprocess.Popen(command,env=environment,cwd=root,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            code = process.wait(timeout=90)
        except (subprocess.TimeoutExpired,KeyboardInterrupt):
            # Only the process group created above is signalled; never a shared helper identity.
            os.killpg(process.pid,signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=5)
            raise RuntimeError('Owned lab process timed out; inspect its retained log') from None
    receipt = json.loads((root/'evidence/permission-readiness.json').read_text())
    if code != 0 or 'error' in receipt:
        raise RuntimeError('Native permission lab failed; inspect the retained receipt/log')
    required = ['isolatedRuntimeVerified','automationGranted','helperAccessibilityVerified',
                'helperScreenRecordingVerified','permissionReadinessVerified','proofClearedAfterClose',
                'systemTCCDenyConfirmed']
    if not all(receipt.get(key) is True for key in required):
        raise RuntimeError('Effective native permission proof did not pass')
    if receipt.get('userTCCDenyConfirmed') is not True and receipt.get('userTCCMissing') is not True:
        raise RuntimeError('User TCC database was neither denied nor absent')
    if any(receipt.get(key) is not False for key in ['helperAccessibilityTCCReadable','helperScreenRecordingTCCReadable','systemTCCReadable','userTCCReadable']):
        raise RuntimeError('TCC reads were not actually denied')
    summary = {key:receipt[key] for key in required+['userTCCDenyConfirmed','userTCCMissing',
        'helperAccessibilityTCCReadable','helperScreenRecordingTCCReadable','systemTCCReadable','userTCCReadable']}
    (root/'boolean-receipt.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('PASS: actual owned-window AX + capture with both TCC database reads unavailable; no permission changes',flush=True)


if __name__ == '__main__':
    main()
