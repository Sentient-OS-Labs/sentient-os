#!/usr/bin/env python3
"""Production window matching and AX/image fallback, without windows or provider calls."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'Sentient OS macOS/Summarize'
with tempfile.TemporaryDirectory(prefix='sentient-summary-capture-') as directory:
    binary = Path(directory) / 'test'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-parse-as-library', str(source/'SummaryWindowSelection.swift'),
                    str(source/'SummaryCapture.swift'), str(root/'Scripts/Fixtures/SummaryCaptureTests.swift'),
                    '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)
