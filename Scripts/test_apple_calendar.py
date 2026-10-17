#!/usr/bin/env python3
"""Run the production Calendar pipeline and strict parser against controlled failures.

Only native EventKit, inference and storage boundaries are fixtures. No user calendars,
preferences, model, network, telemetry or production databases are accessed.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
SOURCES = [
    "Sources/DataSource.swift", "Engine/Verdict.swift", "Engine/PIIScan.swift",
    "Engine/Triage.swift", "Ingestion/Connector.swift", "Ingestion/RunProgress.swift",
    "Ingestion/Connectors/AppleCalendarConnector.swift", "Ingestion/IterativeRun+AppleCalendar.swift",
]
with tempfile.TemporaryDirectory(prefix="calendar-tests-") as temp:
    binary = Path(temp) / "calendar-tests"
    subprocess.run([
        "swiftc", "-O", "-parse-as-library", "-module-cache-path",
        os.environ.get("CLANG_MODULE_CACHE_PATH", str(Path(temp) / "modules")),
        *[str(APP / path) for path in SOURCES],
        str(ROOT / "Scripts/fixtures/apple_calendar_tests.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
    subprocess.run([
        "swiftc", "-O", "-parse-as-library", "-module-cache-path",
        os.environ.get("CLANG_MODULE_CACHE_PATH", str(Path(temp) / "modules")),
        *[str(APP / path) for path in [
            "Sources/DataSource.swift", "Engine/Verdict.swift", "Engine/PIIScan.swift",
            "Engine/Triage.swift", "Sources/AppleCalendarSource.swift",
        ]],
        str(ROOT / "Scripts/fixtures/apple_calendar_health.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
