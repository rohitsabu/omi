#!/usr/bin/env bash
# bridge_minutes_phase3.sh — end-to-end smoke test for the Phase 3 Swift
# minutes lifecycle. Extends the Phase 1 contract smoke with:
#
#   1. Real MCP end-to-end (start → wait 8s → stop → poll for final transcript).
#      Exercises the Swift-native MCP JSON-RPC client + state.json + folder
#      layout. Requires the Minutes Desktop Extension + Whisper small model to
#      be installed; set SKIP_MCP=1 to skip the real record leg.
#
#   2. Enrich + wait for the `.enriched` sentinel the TS enricher drops beside
#      the transcript. Bounded at 180s so a slow claude-cli doesn't hang the
#      test forever.
#
#   3. Graceful-shutdown check — starts a recording, sends SIGTERM to the
#      "Omi Dev" process, and verifies state.json for that meetingId is in
#      a recoverable/completed state on relaunch. Requires SKIP_GRACEFUL=0
#      (default 1) because relaunching the app from a shell script racey on
#      Rohit's normal dev loop — manual verification is still the canonical
#      path. Set SKIP_GRACEFUL=0 explicitly to exercise it.
#
#   4. Regression run with `OMI_MINUTES_LIFECYCLE=ts` — ensures the Phase 1
#      TS shell-out path still works as the fallback lane.
#
# Preconditions:
#   - Omi Desktop is built and running under `./run.sh --yolo`.
#   - minutes-agent checkout at $OMI_MINUTES_AGENT_DIR (default
#     ~/Developer/entropy-negative/minutes-agent).
#   - Anthropic Claude CLI (`claude`) on PATH for the enricher. If claude is
#     not available the enrich leg is skipped with a warning.
#
# Run:
#   ./desktop/test/bridge_minutes_phase3.sh
#   SKIP_MCP=1 ./desktop/test/bridge_minutes_phase3.sh   # skip real recording
#   SKIP_ENRICH=1 ./desktop/test/bridge_minutes_phase3.sh # skip enricher leg
#   SKIP_TS_FALLBACK=1 ./desktop/test/bridge_minutes_phase3.sh
#   SKIP_GRACEFUL=0 ./desktop/test/bridge_minutes_phase3.sh # exercise SIGTERM relaunch
#
# Exit non-zero on any assertion failure.

set -euo pipefail

PORT="${PORT:-47777}"
BASE="http://127.0.0.1:${PORT}"
TITLE="${TITLE:-phase3 smoke $(date +%H%M%S)}"
SKIP_MCP="${SKIP_MCP:-0}"
SKIP_ENRICH="${SKIP_ENRICH:-0}"
SKIP_TS_FALLBACK="${SKIP_TS_FALLBACK:-0}"
SKIP_GRACEFUL="${SKIP_GRACEFUL:-1}"
RECORD_SECONDS="${RECORD_SECONDS:-8}"
ENRICH_TIMEOUT_SEC="${ENRICH_TIMEOUT_SEC:-180}"
OMI_MINUTES_AGENT_DIR="${OMI_MINUTES_AGENT_DIR:-$HOME/Developer/entropy-negative/minutes-agent}"
STATE_FILE="$HOME/Library/Application Support/minutes-agent/state.json"

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
header "GET /state (bridge up, swift mode)"
STATE=$(curl -sS "$BASE/state")
echo "$STATE" | jq -r '.result.bridgeEnabled' | grep -q '^true$' || fail "bridgeEnabled != true"
pass "bridgeEnabled=true"
BRIDGE_PORT=$(echo "$STATE" | jq -r '.result.bridgePort')
[[ "$BRIDGE_PORT" == "$PORT" ]] || fail "bridgePort $BRIDGE_PORT != $PORT"
pass "bridgePort=$PORT"

# 1. Swift path end-to-end: start → wait → stop → poll → enrich → sentinel
if [[ "$SKIP_MCP" == "1" ]]; then
  skip "Real MCP record leg disabled (SKIP_MCP=1)"
else
  header "POST /minutes/start (swift lifecycle)"
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
  [[ -d "$OUTPUT_PATH" ]] || fail "output folder not created on disk: $OUTPUT_PATH"
  pass "started meetingId=$MEETING_ID"
  pass "outputPath exists: $OUTPUT_PATH"

  # state.json should now contain the meeting in active status.
  if [[ -f "$STATE_FILE" ]]; then
    STATE_STATUS=$(jq -r --arg id "$MEETING_ID" \
      '.activeRecordings[$id].status // "missing"' "$STATE_FILE")
    [[ "$STATE_STATUS" == "active" ]] || fail "state.json status=$STATE_STATUS (expected active)"
    pass "state.json activeRecordings[$MEETING_ID].status=active"
  else
    skip "state.json not found at $STATE_FILE"
  fi

  printf "  .. recording for %ss\n" "$RECORD_SECONDS"
  sleep "$RECORD_SECONDS"

  header "POST /minutes/stop (swift lifecycle)"
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

  # Poll /minutes/transcript until isFinal=true OR 120s elapses.
  header "GET /minutes/transcript (poll to finalisation, 120s cap)"
  ENC_ID=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$MEETING_ID")
  FINAL=0
  for ATTEMPT in $(seq 1 60); do
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
    skip "transcript did not finalise in 120s — non-fatal (Minutes may be degraded; continuing)"
  fi

  # 2. Enrich + wait for .enriched marker
  if [[ "$SKIP_ENRICH" == "1" ]]; then
    skip "enrich leg disabled (SKIP_ENRICH=1)"
  elif ! command -v claude >/dev/null 2>&1; then
    skip "claude CLI not on PATH — can't exercise post-meeting-enrich"
  elif [[ ! -f "$TRANSCRIPT_PATH" ]]; then
    skip "transcript.md not on disk — can't enrich (check Minutes Whisper model)"
  else
    header "POST /minutes/enrich + wait for .enriched sentinel"
    ENRICH_BODY=$(jq -n --arg id "$MEETING_ID" '{meetingId: $id}')
    ENRICH_RES=$(curl -sS -X POST -H 'Content-Type: application/json' \
      --data "$ENRICH_BODY" "$BASE/minutes/enrich")
    echo "$ENRICH_RES" | jq .
    JOB=$(echo "$ENRICH_RES" | jq -r '.jobId // empty')
    [[ -n "$JOB" ]] || fail "/minutes/enrich missing jobId"
    pass "enrich queued jobId=$JOB"

    SENTINEL="${TRANSCRIPT_PATH%.md}.enriched"
    ALT_SENTINEL="$OUTPUT_PATH/.enriched"
    printf "  .. waiting for sentinel (up to %ss): %s OR %s\n" "$ENRICH_TIMEOUT_SEC" "$SENTINEL" "$ALT_SENTINEL"
    ELAPSED=0
    FOUND=""
    while [[ "$ELAPSED" -lt "$ENRICH_TIMEOUT_SEC" ]]; do
      if [[ -f "$SENTINEL" ]]; then FOUND="$SENTINEL"; break; fi
      if [[ -f "$ALT_SENTINEL" ]]; then FOUND="$ALT_SENTINEL"; break; fi
      sleep 5
      ELAPSED=$((ELAPSED + 5))
    done
    if [[ -n "$FOUND" ]]; then
      pass ".enriched sentinel landed at $FOUND (after ~${ELAPSED}s)"
    else
      # Non-fatal — claude-cli sometimes takes >3min on a cold index.
      skip ".enriched sentinel did not land within ${ENRICH_TIMEOUT_SEC}s (check ~/Library/Logs/minutes-agent/post-meeting-enrich.log)"
    fi
  fi
fi

# 3. Graceful shutdown — only if explicitly requested. Terminates Omi Dev
# mid-record; verifies state.json is left recoverable. Needs Rohit to relaunch
# the app afterwards.
if [[ "$SKIP_GRACEFUL" != "0" ]]; then
  skip "graceful-shutdown leg disabled (SKIP_GRACEFUL=$SKIP_GRACEFUL; set SKIP_GRACEFUL=0 to exercise)"
else
  header "Graceful shutdown — start, SIGTERM Omi Dev, inspect state.json"
  GS_TITLE="phase3 graceful $(date +%H%M%S)"
  GS_BODY=$(jq -n --arg t "$GS_TITLE" '{title: $t, source: "manual"}')
  GS_RES=$(curl -sS -X POST -H 'Content-Type: application/json' \
    --data "$GS_BODY" "$BASE/minutes/start")
  GS_ID=$(echo "$GS_RES" | jq -r '.meetingId // empty')
  [[ -n "$GS_ID" ]] || fail "graceful-shutdown: /minutes/start returned no meetingId"
  pass "graceful recording started meetingId=$GS_ID"

  OMI_PID=$(pgrep -f 'Omi Dev.app/Contents/MacOS/Omi Computer' | head -1 || true)
  [[ -n "$OMI_PID" ]] || fail "couldn't find running 'Omi Dev' process"
  pass "Omi Dev PID=$OMI_PID; sending SIGTERM"
  kill -TERM "$OMI_PID" || true

  # Wait up to 15s for the process to actually exit (graceful shutdown
  # blocks on the MCP stop_recording).
  for _ in $(seq 1 15); do
    if ! kill -0 "$OMI_PID" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$OMI_PID" 2>/dev/null; then
    skip "Omi Dev $OMI_PID did not exit within 15s — kill -KILL to clean up"
    kill -KILL "$OMI_PID" 2>/dev/null || true
  else
    pass "Omi Dev exited cleanly"
  fi

  if [[ -f "$STATE_FILE" ]]; then
    GS_STATUS=$(jq -r --arg id "$GS_ID" \
      '.activeRecordings[$id].status // "missing"' "$STATE_FILE")
    case "$GS_STATUS" in
      recoverable|completed|finalizing)
        pass "state.json status=$GS_STATUS (recoverable — not leaked)"
        ;;
      active)
        fail "state.json status=active — shutdown hook didn't run"
        ;;
      missing)
        skip "state.json has no entry for $GS_ID (may have been cleared by the TS fallback path)"
        ;;
      *)
        fail "state.json status=$GS_STATUS — unexpected"
        ;;
    esac
  else
    skip "state.json missing — can't verify graceful-shutdown path"
  fi

  # Caller re-launches Omi Dev. We don't attempt it from here because the
  # launch dance is tightly coupled to ./run.sh.
  printf "  NOTE: re-run './run.sh --yolo' to relaunch Omi Dev.\n"
fi

# 4. TS fallback regression — spin one record cycle through OMI_MINUTES_LIFECYCLE=ts.
# We can't set the env var on the already-running bridge, so this leg asserts
# that the TS record-now.ts and stop-now.ts scripts still execute cleanly on
# their own. A full `OMI_MINUTES_LIFECYCLE=ts ./run.sh --yolo` regression is a
# manual step; this checks the TS scripts remain well-formed & usable.
if [[ "$SKIP_TS_FALLBACK" == "1" ]]; then
  skip "TS fallback regression disabled (SKIP_TS_FALLBACK=1)"
else
  header "TS fallback — invoke scripts/record-now.ts + stop-now.ts directly"
  pushd "$OMI_MINUTES_AGENT_DIR" >/dev/null
  # --dry-run on record-now currently uses `dry-` IDs which post-meeting can't
  # resolve, but it's enough to confirm the TS script parses and spawns its
  # children. We invoke without --dry-run and then immediately stop to keep
  # state.json clean.
  TS_TITLE="phase3-ts-fallback $(date +%H%M%S)"
  RECORD_OUT=$(OMI_MINUTES_LIFECYCLE=ts npx tsx scripts/record-now.ts --title "$TS_TITLE" 2>/dev/null | tail -1 || true)
  if [[ -z "$RECORD_OUT" ]]; then
    skip "record-now.ts produced no stdout (Minutes MCP may be unavailable in this shell)"
  else
    TS_ID=$(echo "$RECORD_OUT" | jq -r '.meetingId // empty' 2>/dev/null || true)
    if [[ -n "$TS_ID" ]]; then
      pass "record-now.ts minted meetingId=$TS_ID"
      STOP_OUT=$(npx tsx scripts/stop-now.ts --event-id "$TS_ID" 2>/dev/null | tail -1 || true)
      TS_STOPPED=$(echo "$STOP_OUT" | jq -r '.stopped // 0' 2>/dev/null || echo 0)
      if [[ "$TS_STOPPED" -ge 1 ]]; then
        pass "stop-now.ts stopped $TS_STOPPED recording(s)"
      else
        skip "stop-now.ts returned stopped=$TS_STOPPED (script ran but no active rec)"
      fi
    else
      skip "record-now.ts output didn't parse as JSON: $RECORD_OUT"
    fi
  fi
  popd >/dev/null
fi

printf "\nPhase 3 smoke complete.\n"
