#!/usr/bin/env python3
"""Opt-in live relay acceptance. Sends four synthetic requests; uses no API key or real user content."""
from pathlib import Path
import argparse,os,secrets,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live',action='store_true',help='Explicitly authorize the four billable synthetic requests')
parser.add_argument('--base-url',default='https://sentient-doubletap-relay.sentient-doubletap-relay.workers.dev')
parser.add_argument('--artifacts',type=Path,default=Path('/tmp/sentient-screen-actions-live'))
args=parser.parse_args()
if not args.live:parser.error('Use --live only when live-provider verification is authorized.')
if not args.base_url.startswith('https://'):parser.error('Live verification requires HTTPS.')
root=args.artifacts.resolve();root.mkdir(parents=True,exist_ok=True)
identity=root/'live-test-installation.txt'
if not identity.exists():
    identity.write_text(secrets.token_urlsafe(32));identity.chmod(0o600)
with tempfile.TemporaryDirectory(prefix='sentient-screen-actions-client-') as temporary:
    binary=Path(temporary)/'live-checks'
    sources=['Summarize/SummarySource.swift','Summarize/SummaryConversation.swift','Summarize/SummaryConversationStore.swift','Sources/MessageBody.swift','Cloud/ScreenRelayResponse.swift','Summarize/SummarizeInference.swift','Proofread/ProofreadInference.swift']
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-enable-upcoming-feature','NonisolatedNonsendingByDefault','-parse-as-library']+
        [str(ROOT/'Sentient OS macOS'/source) for source in sources]+[str(ROOT/'Scripts/Fixtures/ScreenActionsLive.swift'),'-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary),str(root),args.base_url],check=True,timeout=150)
print('Live receipts:',root/'swift-client-live-checks.json')
