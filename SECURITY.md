# Security Policy

Sentient OS is built on a promise: your raw data never leaves your Mac. We treat anything that breaks that promise, or any other security issue, as a top priority.

## Reporting a vulnerability

Email **security@sentient-os.ai**.

Please do not report vulnerabilities through public GitHub issues.

Include what you can:

- What the issue is and why it matters
- Steps to reproduce (a proof of concept helps a lot)
- The version or commit you tested
- Any suggested fix

You will get an acknowledgement within 48 hours, and we will keep you informed while we work on a fix.

## Scope

Everything Sentient OS ships is in scope:

- The macOS app (this repository)
- The hosted MCP mirror at `mcp.sentient-os.ai` and its server code
- Our release and update infrastructure

We are especially interested in reports that break our privacy invariants, because they are security claims, not marketing:

1. Raw data never leaves the device; cloud models only ever see PII-stripped summaries.
2. Items judged sensitive on-device leave zero trace downstream.
3. The MCP mirror stores only ciphertext encrypted on the user's Mac (AES-256-GCM); the server never sees plaintext at rest.
4. No accounts: a mirror cannot be tied to a human identity.
5. Deletion is total and self-serve; an unrefreshed mirror auto-deletes after 30 days.

If you find a way to violate any of these, we especially want to know.

When testing the live mirror, test against your own data and your own mirror URL. Please avoid disruptive testing (denial of service, resource exhaustion) against `mcp.sentient-os.ai`, and if you believe you can reach another user's vault, stop at the minimum proof needed and report it.

## Supported versions

Sentient OS is under active development. Security fixes land in the latest release only, so please make sure the issue reproduces against the newest version.

## Coordinated disclosure

We ask that you give us reasonable time to fix an issue before disclosing it publicly. 90 days is a good default; issues in the hosted mirror will typically be fixed much faster. We are happy to credit you when the fix ships, or keep you anonymous if you prefer.

We do not run a paid bounty program yet. It's a two-person team; what we offer is fast fixes, honest credit, and gratitude.
