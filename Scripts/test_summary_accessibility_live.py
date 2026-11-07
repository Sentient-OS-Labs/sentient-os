#!/usr/bin/env python3
"""Opt-in real AX-to-summary acceptance for Edge, Chrome, Safari and Claude. No screenshots."""
import argparse, secrets, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--live', action='store_true', help='Authorize sending these real documents to the summary relay')
p.add_argument('--window-title', required=True, help='Unique title fragment of the same page open in all three browsers')
p.add_argument('--artifacts', type=Path)
a = p.parse_args()
if not a.live: p.error('This sends real window text; opt in with --live.')
output = a.artifacts or Path(tempfile.mkdtemp(prefix='sentient-summary-live-'))
output.mkdir(parents=True, exist_ok=True); output.chmod(0o700)
identity = output / 'test-identity'
if not identity.exists(): identity.write_text(secrets.token_urlsafe(32)); identity.chmod(0o600)
with tempfile.TemporaryDirectory(prefix='sentient-summary-client-') as temporary:
    binary = Path(temporary) / 'client'
    sources = ['Summarize/SummarySource.swift','Summarize/SummaryConversation.swift','Summarize/SummaryConversationStore.swift','Sources/MessageBody.swift', 'Summarize/SummaryCapture.swift', 'Summarize/SummarizeInference.swift', 'Cloud/ScreenRelayResponse.swift']
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-enable-upcoming-feature','NonisolatedNonsendingByDefault','-parse-as-library'] +
        [str(ROOT / 'Sentient OS macOS' / f) for f in sources] + [str(ROOT / 'Scripts/Fixtures/SummaryAccessibilityLive.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(output.resolve()),a.window_title],check=True,timeout=240)
print('Private live receipts:', output / 'live-results.json')
