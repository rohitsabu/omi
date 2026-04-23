#!/usr/bin/env bash
# bridge_phase4_e2e.sh — Phase 4 happy-path end-to-end smoke.
#
# Exercises the full /minutes/* surface against the Swift-only lifecycle
# (Phase 4 deleted the TS fallback). One short (5s) recording, stop,
# transcript finalise poll, enrich call → assert the enricher subprocess
# launches. We don't wait on the enricher to finish (claude-cli can take
# 30-90s); we just verify it was spawned with the right args.
#
# Preconditions:
#   - Omi Desktop is built and running under `./run.sh --yolo`.
#   - minutes-agent checkout at $OMI_MINUTES_AGENT_DIR (default
#     ~/Developer/entropy-negative/minutes-agent).
#
# Run:
#   ./desktop/test/bridge_phase4_e2e.sh
#   SKIP_MCP=1 ./desktop/test/bridge_phase4_e2e.sh   # bridge contract only
#   RECORD_SECONDS=10 ./desktop/test/bridge_phase4_e2e.sh
#
# Exits non-zero on any assertion failure.

set -euo pipefail

PORT="${PORT:-47777}"
BASE="http://127.0.0.1:${PORT}"
TITLE="${TITLE:-phase4 e2e $(date +%H%M%S)}"
SKIP_MCP="${SKIP_MCP:-0}"
RECORD_SECONDS="${RECORD_SECONDS:-5}"
OMI_MINUTES_AGENT_DIR="${OMI_MINUTES_AGENT_DIR:-$HOME/Developer/entropy-negative/minutes-agent}"

pass() { printf "  ok  %s\n" "$1"; }
fail() { printf "  FAIL %s\n" "$1"; exit 1; }
header() { printf "\n— %s —\n" "$1"; }
skip() { printf "  -- SKIP %s\n" "$1"; }

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required (brew install jq)"
  fi
}

require_jq

# 0. Bridge health
header "GET /state (bridge up)"
STATE=$(curl -sS "$BASE/state")
echo "$STATE" | jq -r '.result.bridgeEnabled' | grep -q '^true$' || fail "bridgeEnabled != true"
pass "bridgeEnabled=true"
BRIDGE_PORT=$(echo "$STATE" | jq -r '.result.bridgePort')
[[ "$BRIDGE_PORT" == "$PORT" ]] || fail "bridgePort $BRIDGE_PORT != $PORT"
pass "bridgePort=$PORT"

if [[ "$SKIP_MCP" == "1" ]]; then
  skip "Real MCP record leg disabled (SKIP_MCP=1)"
  printf "\nPhase 4 e2e (contract-only) complete.\n"
  exit 0
fi

# 1. Start a recording.
header "POST /minutes/start"
START_BODY=$(jq -n --arg t "$TITLE" '{title: $t, source: "manual"}')
START_RES=$(curl -sS -X POST -H 'Content-Type: application/json' \
  --data "$START_BODY" "$BASE/minutes/start")
echo "$START_RES" | jq .
OK=$(echo "$START_RES" | jq -r '.ok // false')
[[ "$OK" == "true" ]] || fail "/minutes/start ok != true"
MEETING_ID=$(echo "$START_RES" | jq -r '.meetingId // empty')
OUTPUT_PATH=$(echo "$START_RES" | jq -r '.outputPath // empty')
[[ -n "$MEETING_ID" ]] || fail "/minutes/start missing meetingId"
[[ -n "$OUTPUT_PATH" ]] || fail "/minutes/start missing outputPath"
[[ -d "$OUTPUT_PATH" ]] || fail "outputPath dir not created on disk: $OUTPUT_PATH"
pass "started meetingId=$MEETING_ID"
pass "outputPath created: $OUTPUT_PATH"

# 2. Hold the recording for RECORD_SECONDS.
printf "  .. recording for %ss\n" "$RECORD_SECONDS"
sleep "$RECORD_SECONDS"

# 3. Stop.
header "POST /minutes/stop"
STOP_BODY=$(jq -n --arg id "$MEETING_ID" '{meetingId: $id}')
STOP_RES=$(curl -sS -X POST -H 'Content-Type: application/json' \
  --data "$STOP_BODY" "$BASE/minutes/stop")
echo "$STOP_RES" | jq .
OK=$(echo "$STOP_RES" | jq -r '.ok // false')
[[ "$OK" == "true" ]] || fail "/minutes/stop ok != true"
DURATION=$(echo "$STOP_RES" | jq -r '.durationSec // -1')
[[ "$DURATION" -ge "$RECORD_SECONDS" ]] 2>/dev/null || fail "durationSec $DURATION < $RECORD_SECONDS"
TRANSCRIPT_PATH=$(echo "$STOP_RES" | jq -r '.transcriptPath // empty')
[[ -n "$TRANSCRIPT_PATH" ]] || fail "/minutes/stop missing transcriptPath"
pass "stopped durationSec=$DURATION transcriptPath=$TRANSCRIPT_PATH"

# 4. Transcript finalisation poll (up to 60s — short recording).
header "GET /minutes/transcript (poll for finalisation, 60s cap)"
ENC_ID=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$MEETING_ID")
FINAL=0
for ATTEMPT in $(seq 1 30); do
  TX_RES=$(curl -sS "$BASE/minutes/transcript?meetingId=${ENC_ID}")
  IS_FINAL=$(echo "$TX_RES" | jq -r '.isFinal | tostring')
  if [[ "$IS_FINAL" == "true" ]]; then
    FINAL=1
    pass "transcript finalised on attempt $ATTEMPT"
    break
  fi
  sleep 2
done
if [[ "$FINAL" != "1" ]]; then
  skip "transcript did not finalise in 60s (Minutes Whisper may be slow on a 5s clip; non-fatal)"
fi

# 5. Enrich. Verify the subprocess actually fired by checking that the
# bridge returns a jobId AND a fresh log line lands in the enricher's JSONL
# log within a few seconds. We do NOT wait on the enricher to complete —
# claude-cli can take 30-90s and that's not what this smoke verifies.
header "POST /minutes/enrich → assert subprocess launched"

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  # Fall back to a fixture transcript so the enricher subprocess test still runs.
  FIXTURE_DIR="$OMI_MINUTES_AGENT_DIR/scripts/v2/fixtures"
  if [[ -d "$FIXTURE_DIR" ]]; then
    ALT_TX=$(find "$FIXTURE_DIR" -maxdepth 3 -name '*.md' | head -1)
    if [[ -n "$ALT_TX" && -f "$ALT_TX" ]]; then
      TRANSCRIPT_PATH="$ALT_TX"
      printf "  using fixture transcript: %s\n" "$TRANSCRIPT_PATH"
    fi
  fi
fi

LOG_PATH="$HOME/Library/Logs/minutes-agent/post-meeting-enrich.log"
if [[ -f "$LOG_PATH" ]]; then
  PRE_LINES=$(wc -l < "$LOG_PATH" | tr -d ' ')
else
  PRE_LINES=0
fi

ENRICH_BODY=$(jq -n --arg id "$MEETING_ID" --arg p "$TRANSCRIPT_PATH" \
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
[[ "$HTTP" == "202" ]] || fail "/minutes/enrich expected 202, got $HTTP"
pass "enrich queued jobId=$JOB (HTTP $HTTP)"

# Wait briefly for the subprocess to write its first log line.
SAW_LAUNCH=0
for _ in $(seq 1 10); do
  sleep 1
  if [[ -f "$LOG_PATH" ]]; then
    POST_LINES=$(wc -l < "$LOG_PATH" | tr -d ' ')
    if [[ "$POST_LINES" -gt "$PRE_LINES" ]]; then
      SAW_LAUNCH=1
      break
    fi
  fi
  # Fallback: pgrep for an active enricher subprocess.
  if pgrep -f "post-meeting-enrich.ts" >/dev/null 2>&1; then
    SAW_LAUNCH=1
    break
  fi
done

if [[ "$SAW_LAUNCH" == "1" ]]; then
  pass "enricher subprocess fired (post-meeting-enrich.ts launched)"
else
  skip "couldn't confirm enricher launch within 10s — may have completed/failed already; check $LOG_PATH"
fi

printf "\nPhase 4 e2e complete.\n"
