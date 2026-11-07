#!/usr/bin/env python3
"""Compile production proofreading code against inert UI/capture collaborators."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];APP=ROOT/'Sentient OS macOS'
with tempfile.TemporaryDirectory(prefix='sentient-proofread-test-') as temporary:
    binary=Path(temporary)/'tests'
    files=['Cloud/ScreenRelayResponse.swift','Proofread/ProofreadRequest.swift','Proofread/ProofreadInference.swift','Proofread/ProofreadSelection.swift','Proofread/Proofread.swift']
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-enable-upcoming-feature','NonisolatedNonsendingByDefault','-parse-as-library']+
        [str(APP/f) for f in files]+[str(ROOT/'Scripts/Fixtures/ProofreadTests.swift'),'-o',str(binary)],check=True,timeout=60)
    server=subprocess.Popen(['node',str(ROOT/'Scripts/Fixtures/screen_action_server.mjs')],stdout=subprocess.PIPE,text=True)
    try:
        port=int(server.stdout.readline().strip());subprocess.run([str(binary),f'http://127.0.0.1:{port}'],check=True,timeout=20)
    finally: server.terminate();server.wait(timeout=5)
