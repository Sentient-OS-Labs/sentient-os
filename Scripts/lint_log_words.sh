#!/bin/sh
# Log-vocabulary lint. Every Log() line ships to Sentry as a Release breadcrumb, and Sentry's
# server-side default scrubber (@password:filter) redacts ANY string containing one of these
# words wholesale to "[Filtered]" — it ate ~8,000 of our own breadcrumbs (Aug 2026 triage), incl.
# every "… out-tokens" success line and every [codex-login] line. So: none of these words may
# appear in the literal text of a Log("…") call, nor in a captureEvent tag/extra KEY or literal
# VALUE. Debug builds run this as a build phase; it exits non-zero with the offending lines.
#
# Checked: the literal text only — `\(interpolations)` are stripped first (an identifier NAME
# like `outputTokens` never reaches Sentry; keep its VALUE structure-only yourself), and `//`
# comments are ignored. Fix a hit by rephrasing (token→out, auth→login/permission,
# session→thread/capture), never by disabling the check.
# Doc: Diagnostics/Documentation - Diagnostics (Sentry & TelemetryDeck).md
set -e
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$ROOT/Sentient OS macOS"
WORDS='token|auth|session|secret|password|passwd|credential|api_key|apikey|private_key|privatekey'
strip() { sed -E 's#//.*$##; s/\\\([^)]*\)//g'; }
# 1) Log("…") literal text.
HITS=$(grep -rn --include='*.swift' 'Log("' "$SRC" | strip | grep -Ei "Log\(\"[^\"]*($WORDS)" || true)
# 2) Diagnostics dictionaries: within 8 lines after a `captureEvent(` call, a `var tags`/`var extras`
#    (CodexAuthSnapshot), or an `extra["…"]`/`tags["…"]` subscript, any quoted key/value carrying a
#    scrubber word. Event NAMES and fingerprints are grouping keys, not scrubbed (they arrive intact
#    as issue titles) — the `fingerprint: […]` segment is dropped first.
HITS2=$(grep -rn --include='*.swift' -E 'captureEvent\(|var tags:|var extras:|extra\["|tags\["|"[a-z_]+": *(String|net\.|mode\.|plan|diag)' "$SRC" | cut -d: -f1,2 | sort -u | while IFS=: read -r f l; do
          sed -n "${l},$((l+8))p" "$f" | strip | sed -E 's/fingerprint: *\[[^]]*\]//; s/captureEvent\("[^"]*"//; s/Analytics\.signal\("[^"]*"//' \
            | grep -Ei "\"[a-z0-9_.-]*($WORDS)[a-z0-9_.-]*\"" | sed "s#^#$f:$l+: #" || true
        done)
if [ -n "$HITS$HITS2" ]; then
  echo "error: Log()/diagnostics vocabulary would be redacted by Sentry's server-side scrubber (words: $WORDS). Rephrase:"
  printf '%s\n%s\n' "$HITS" "$HITS2" | sed '/^$/d' | sort -u | sed 's/^/  /'
  exit 1
fi
echo "lint_log_words: clean"
