#!/usr/bin/env python3
"""Compile the production hosted client and run offline auth, quota and lifecycle tests."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="sentient-hosted-client-") as temporary:
    binary = Path(temporary) / "tests"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6", "-D", "DEBUG",
                    str(ROOT / "Scripts/Fixtures/HostedInferenceClientTests.swift"),
                    str(ROOT / "Sentient OS macOS/Cloud/HostedInference/HostedInference.swift"),
                    str(ROOT / "Sentient OS macOS/Cloud/HostedInference/HostedInferenceClient.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
