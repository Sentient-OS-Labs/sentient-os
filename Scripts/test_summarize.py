#!/usr/bin/env python3
"""Compile real summary logic with synthetic capture/window/credential collaborators."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS/Summarize'
with tempfile.TemporaryDirectory(prefix='sentient-summarize-test-') as temporary:
    binary = Path(temporary) / 'summary-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault', '-warnings-as-errors', '-parse-as-library',
                    str(ROOT/'Sentient OS macOS/Cloud/ScreenRelayResponse.swift'), str(APP/'SummaryRequest.swift'), str(APP/'SummarySource.swift'), str(APP/'SummaryConversation.swift'), str(APP/'SummaryConversationStore.swift'), str(ROOT/'Sentient OS macOS/Sources/MessageBody.swift'), str(APP/'SummaryCapture.swift'), str(APP/'SummarizeInference.swift'), str(APP/'Summarize.swift'),
                    str(APP/'SummarySessions.swift'), str(ROOT/'Scripts/Fixtures/SummarizeTests.swift'), '-o', str(binary)], check=True, timeout=60)
    server = subprocess.Popen(['node', str(ROOT/'Scripts/Fixtures/screen_action_server.mjs')], stdout=subprocess.PIPE, text=True)
    try:
        port = int(server.stdout.readline().strip())
        subprocess.run([str(binary), f'http://127.0.0.1:{port}'], check=True, timeout=20)
    finally:
        server.terminate()
        server.wait(timeout=5)
