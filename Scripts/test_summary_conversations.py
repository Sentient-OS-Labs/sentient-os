#!/usr/bin/env python3
"""Verify conversation scope and safe local continuation with synthetic data only."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='sentient-chat-scope-') as temporary:
 binary=Path(temporary)/'test'
 sources=['Summarize/SummarySource.swift','Summarize/SummaryConversation.swift','Summarize/SummaryConversationStore.swift','Sources/MessageBody.swift']
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',*[str(root/'Sentient OS macOS'/s) for s in sources],str(root/'Scripts/Fixtures/SummaryConversationTests.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary),temporary],check=True,timeout=20)
