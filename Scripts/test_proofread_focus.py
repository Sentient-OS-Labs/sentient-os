#!/usr/bin/env python3
"""Exercise production selection handoff in a separate disposable native app. Requires Accessibility."""
import plistlib, subprocess, tempfile, time
from pathlib import Path
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='sentient-proofread-focus-') as temporary:
    work = Path(temporary)
    contents = work / 'Proofread Fixture.app/Contents'
    (contents / 'MacOS').mkdir(parents=True)
    binary = contents / 'MacOS/probe'
    (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'probe', 'CFBundleIdentifier':'ai.sentient.proofread-fixture', 'CFBundleName':'Proofread Fixture', 'CFBundlePackageType':'APPL'}))
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library', str(root/'Sentient OS macOS/Proofread/ProofreadSelection.swift'),str(root/'Scripts/Fixtures/ProofreadFocusTests.swift'),'-o',str(binary)],check=True)
    subprocess.run(['open','-n','-a',str(contents.parent),'--args','editor'],check=True)
    time.sleep(1)
    pid = subprocess.check_output(['pgrep','-f',str(binary)],text=True).strip().splitlines()[0]
    try:
        subprocess.run([str(binary),pid],check=True,timeout=15)
    finally:
        subprocess.run(['kill',pid],check=False)
