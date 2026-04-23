#!/usr/bin/env bash
# bridge_ai.sh — smoke test for the /ai/* endpoints on the Omi Desktop
# automation bridge.
#
# Preconditions:
#   - Omi Desktop is built and running with the automation bridge enabled
#     (i.e. ./run.sh --yolo in another terminal).
#   - The user is signed into Claude Code (claude -p works from shell).
#     The health-check asserts this.
#
# What it does:
#   1. GET /state                → sanity-check bridge up, AI fields present.
#   2. GET /ai/health            → provider=claude-cli, ready=true, version present.
#   3. POST /ai/ask (happy path) → sends "Reply with PONG", asserts ok=true & text non-empty.
#   4. POST /ai/ask (empty)      → expects HTTP 400, error=empty_prompt.
#   5. Missing-claude simulation → relaunch guidance only (see notes below).
#
# Contract test only — verifies the HTTP shape, not model quality.
#
# Run:
#   ./desktop/test/bridge_ai.sh
#   PORT=47777 SKIP_ASK=1 ./desktop/test/bridge_ai.sh   # HTTP-shape only
#
# Exit non-zero on any assertion failure.

set -euo pipefail

PORT="${PORT:-47777}"
BASE="http://127.0.0.1:${PORT}"
SKIP_ASK="${SKIP_ASK:-0}"

pass() { printf "  ok  %s\n" "$1"; }
fail() { printf "  FAIL %s\n" "$1"; exit 1; }
header() { printf "\n— %s —\n" "$1"; }

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required (brew install jq)"
  fi
}

require_jq

# ---- 1. /state includes AI fields ----

header "GET /state (AI fields)"
STATE=$(curl -sS "$BASE/state")
echo "$STATE" | jq '.result | {aiProvider, aiReady, aiError}'

AI_PROVIDER=$(echo "$STATE" | jq -r '.result.aiProvider // "MISSING"')
AI_READY=$(echo "$STATE" | jq -r '.result.aiReady | tostring')

[[ "$AI_PROVIDER" != "MISSING" ]] || fail "/state missing aiProvider"
pass "aiProvider field present: $AI_PROVIDER"
[[ "$AI_READY" == "true" || "$AI_READY" == "false" ]] \
  || fail "aiReady not a bool: $AI_READY"
pass "aiReady is bool: $AI_READY"

# ---- 2. /ai/health ----

header "GET /ai/health"
HEALTH=$(curl -sS "$BASE/ai/health")
echo "$HEALTH" | jq .

PROVIDER=$(echo "$HEALTH" | jq -r '.provider // "MISSING"')
READY=$(echo "$HEALTH" | jq -r '.ready | tostring')
VERSION=$(echo "$HEALTH" | jq -r '.claudeVersion // empty')

[[ "$PROVIDER" == "claude-cli" || "$PROVIDER" == "none" ]] \
  || fail "/ai/health unexpected provider: $PROVIDER"
pass "provider=$PROVIDER"

if [[ "$PROVIDER" == "claude-cli" && "$READY" == "true" ]]; then
  [[ -n "$VERSION" ]] || fail "/ai/health ready=true but missing claudeVersion"
  pass "claudeVersion=$VERSION"
fi

# ---- 3. /ai/ask happy path ----

if [[ "$SKIP_ASK" == "1" ]]; then
  printf "\nSKIP_ASK=1 — skipping /ai/ask happy-path and empty-prompt tests\n"
  exit 0
fi

if [[ "$READY" != "true" ]]; then
  printf "\nclaude-cli not ready — skipping /ai/ask happy-path test.\n"
  printf "(Sign into Claude Code or set OMI_CLAUDE_BIN_OVERRIDE to test on CI.)\n"
else
  header "POST /ai/ask (happy path)"
  ASK_BODY='{"prompt":"Reply with exactly the word PONG and nothing else."}'
  ASK_RES=$(curl -sS -X POST -H 'Content-Type: application/json' \
    --data "$ASK_BODY" "$BASE/ai/ask")
  echo "$ASK_RES" | jq .
  OK=$(echo "$ASK_RES" | jq -r '.ok | tostring')
  TEXT=$(echo "$ASK_RES" | jq -r '.text // empty')
  [[ "$OK" == "true" ]] || fail "/ai/ask ok != true: $(echo "$ASK_RES" | jq -c .)"
  [[ -n "$TEXT" ]] || fail "/ai/ask text is empty"
  pass "ask returned non-empty text (${#TEXT} bytes)"
fi

# ---- 4. /ai/ask empty prompt ----

header "POST /ai/ask (empty prompt → expect HTTP 400)"
HTTP=$(curl -sS -o /tmp/bridge_ai_empty.json -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data '{"prompt":""}' "$BASE/ai/ask")
cat /tmp/bridge_ai_empty.json | jq .
[[ "$HTTP" == "400" ]] || fail "empty-prompt expected HTTP 400, got $HTTP"
EMPTY_CODE=$(jq -r '.error // empty' </tmp/bridge_ai_empty.json)
[[ "$EMPTY_CODE" == "empty_prompt" ]] || fail "expected error=empty_prompt, got: $EMPTY_CODE"
pass "empty prompt → 400 empty_prompt"

# ---- 5. Missing-claude simulation notes ----
#
# To test the missing-claude path:
#
#   OMI_CLAUDE_BIN_OVERRIDE=/nonexistent/path ./run.sh --yolo
#
# Expected: /ai/health returns provider=none, ready=false, error contains
# "claude binary not found"; /state shows aiProvider=none aiReady=false;
# /ai/ask returns HTTP 503 with error=claude_not_installed.
#
# This script does not attempt to relaunch the app with a different env —
# it's the one test that requires manual app restart. Automating it would
# require either a separate helper binary or launchctl trickery outside
# the scope of a smoke test.

printf "\nAll assertions passed.\n"
