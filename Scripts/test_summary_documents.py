#!/usr/bin/env python3
"""Test actual PDF extraction and hard text bounds using synthetic documents."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='sentient-summary-documents-') as temporary:
 binary=Path(temporary)/'tests'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'Sentient OS macOS/Summarize/SummarySource.swift'),str(root/'Sentient OS macOS/Summarize/SummaryConversation.swift'),str(root/'Sentient OS macOS/Summarize/SummaryConversationStore.swift'),str(root/'Sentient OS macOS/Sources/MessageBody.swift'),str(root/'Scripts/Fixtures/SummaryDocumentTests.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary),temporary],check=True,timeout=30)
