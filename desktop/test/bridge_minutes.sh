#!/usr/bin/env bash
# bridge_minutes.sh — smoke test for the /minutes/* endpoints on the Omi
# Desktop automation bridge.
#
# Preconditions:
#   - Omi Desktop is built and running with the automation bridge enabled
#     (i.e. ./run.sh --yolo in another terminal, or env OMI_ENABLE_LOCAL_AUTOMATION=1).
#   - The minutes-agent checkout is at $OMI_MINUTES_AGENT_DIR (default
#     ~/Developer/entropy-negative/minutes-agent).
#
# What it does:
#   1. Hit GET /state, sanity-check the bridge is up.
#   2. POST /minutes/start with a dummy title → capture meetingId.
#   3. GET /minutes/transcript?meetingId=… → confirm JSON shape (not-final OK).
#   4. POST /minutes/stop → capture stoppedAt/durationSec.
#   5. POST /minutes/enrich with a fixture transcript path → confirm 202 + jobId.
#
# This is a contract test — it verifies the HTTP shape of the API, not the
# semantic correctness of the underlying Minutes MCP behavior (which requires
# real microphone access and is exercised by the full end-to-end flow).
#
# Run:
#   ./desktop/test/bridge_minutes.sh
#   PORT=47777 TITLE="custom" ./desktop/test/bridge_minutes.sh
#
# Exit non-zero on any assertion failure.

set -euo pipefail

PORT="${PORT:-47777}"
BASE="http://127.0.0.1:${PORT}"
TITLE="${TITLE:-bridge smoke $(date +%H%M%S)}"
SKIP_CAPTURE="${SKIP_CAPTURE:-0}"

pass() { printf "  ok  %s\n" "$1"; }
fail() { printf "  FAIL %s\n" "$1"; exit 1; }

header() { printf "\n— %s —\n" "$1"; }

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required (brew install jq)"
  fi
}

require_jq

header "GET /state"
STATE=$(curl -sS "$BASE/state")
echo "$STATE" | jq -r '.result.bridgeEnabled' | grep -q '^true$' || fail "bridgeEnabled != true"
pass "bridgeEnabled=true"
BRIDGE_PORT=$(echo "$STATE" | jq -r '.result.bridgePort')
[[ "$BRIDGE_PORT" == "$PORT" ]] || fail "bridgePort $BRIDGE_PORT != $PORT"
pass "bridgePort=$PORT"

if [[ "$SKIP_CAPTURE" == "1" ]]; then
  printf "\nSKIP_CAPTURE=1 — skipping start/stop/transcript/enrich tests\n"
  exit 0
fi

header "POST /minutes/start"
START_BODY=$(jq -n --arg t "$TITLE" '{title: $t, source: "manual"}')
START_RES=$(curl -sS -X POST -H 'Content-Type: application/json' \
  --data "$START_BODY" "$BASE/minutes/start")
echo "$START_RES" | jq .
MEETING_ID=$(echo "$START_RES" | jq -r '.meetingId // empty')
OUTPUT_PATH=$(echo "$START_RES" | jq -r '.outputPath // empty')
OK=$(echo "$START_RES" | jq -r '.ok // false')
[[ "$OK" == "true" ]] || fail "/minutes/start ok != true"
[[ -n "$MEETING_ID" ]] || fail "/minutes/start missing meetingId"
[[ -n "$OUTPUT_PATH" ]] || fail "/minutes/start missing outputPath"
pass "started meetingId=$MEETING_ID outputPath=$OUTPUT_PATH"

sleep 2

header "GET /minutes/transcript"
ENC_ID=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$MEETING_ID")
TX_RES=$(curl -sS "$BASE/minutes/transcript?meetingId=${ENC_ID}")
echo "$TX_RES" | jq .
# jq's // alternative treats `false` as empty, so use tostring to preserve the bool.
IS_FINAL=$(echo "$TX_RES" | jq -r 'if has("isFinal") and (.isFinal|type=="boolean") then (.isFinal|tostring) else "MISSING" end')
[[ "$IS_FINAL" == "true" || "$IS_FINAL" == "false" ]] || fail "transcript.isFinal not a bool (got: $IS_FINAL)"
pass "transcript returned (isFinal=$IS_FINAL)"

header "POST /minutes/stop"
STOP_BODY=$(jq -n --arg id "$MEETING_ID" '{meetingId: $id}')
STOP_RES=$(curl -sS -X POST -H 'Content-Type: application/json' \
  --data "$STOP_BODY" "$BASE/minutes/stop")
echo "$STOP_RES" | jq .
OK=$(echo "$STOP_RES" | jq -r '.ok // false')
[[ "$OK" == "true" ]] || fail "/minutes/stop ok != true"
DURATION=$(echo "$STOP_RES" | jq -r '.durationSec // -1')
[[ "$DURATION" -ge 0 ]] 2>/dev/null || fail "/minutes/stop missing durationSec"
pass "stopped durationSec=$DURATION"

header "POST /minutes/enrich (fixture)"
FIXTURE_DIR="${OMI_MINUTES_AGENT_DIR:-$HOME/Developer/entropy-negative/minutes-agent}/scripts/v2/fixtures"
TRANSCRIPT=""
if [[ -f "$FIXTURE_DIR/sample-transcript.md" ]]; then
  TRANSCRIPT="$FIXTURE_DIR/sample-transcript.md"
elif [[ -d "$FIXTURE_DIR" ]]; then
  TRANSCRIPT=$(find "$FIXTURE_DIR" -maxdepth 3 -name '*.md' | head -1)
fi
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  ENRICH_BODY=$(jq -n --arg id "$MEETING_ID" --arg p "$TRANSCRIPT" \
    '{meetingId: $id, transcriptPath: $p}')
  ENRICH_RES=$(curl -sS -X POST -H 'Content-Type: application/json' \
    --data "$ENRICH_BODY" "$BASE/minutes/enrich")
  HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --data "$ENRICH_BODY" "$BASE/minutes/enrich")
  echo "$ENRICH_RES" | jq .
  OK=$(echo "$ENRICH_RES" | jq -r '.ok | tostring')
  JOB=$(echo "$ENRICH_RES" | jq -r '.jobId // empty')
  [[ "$OK" == "true" ]] || fail "/minutes/enrich ok != true"
  [[ -n "$JOB" ]] || fail "/minutes/enrich missing jobId"
  # 202 on first call; subsequent calls may also be 202 since fire-and-forget.
  [[ "$HTTP" == "202" ]] || fail "/minutes/enrich expected 202, got $HTTP"
  pass "enrich queued jobId=$JOB (HTTP $HTTP)"
else
  printf "  SKIP no fixture transcript under %s\n" "$FIXTURE_DIR"
fi

printf "\nAll assertions passed.\n"
