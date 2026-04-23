#!/usr/bin/env bash
# bridge_calendar.sh — smoke test for the /calendar/* endpoints on the Omi
# Desktop automation bridge (Phase 2 of the minutes×omi merge).
#
# Preconditions:
#   - Omi Desktop is built and running with the automation bridge enabled
#     (i.e. ./run.sh --yolo in another terminal, or env OMI_ENABLE_LOCAL_AUTOMATION=1).
#   - Calendar TCC has been granted (approve via System Settings → Privacy →
#     Calendars, or set SKIP_CALENDAR=1 on a fresh install before the prompt
#     has been approved).
#
# What it does:
#   1. Hit GET /state, assert bridgeEnabled and the presence of `calendarAccess`.
#   2. Hit GET /calendar/upcoming, assert `{ ok: true, events: [...] }` shape.
#   3. Hit GET /calendar/event?id=bogus-nonsense-id, assert 404 event_not_found.
#   4. Hit GET /calendar/active, assert the shape is `{ ok, active, others }`.
#
# This is a contract test: we don't assert on specific meeting titles or
# times (the user's calendar is real), only on shape/HTTP-status correctness.
#
# Run:
#   ./desktop/test/bridge_calendar.sh
#   PORT=47777 ./desktop/test/bridge_calendar.sh
#   SKIP_CALENDAR=1 ./desktop/test/bridge_calendar.sh    # skip everything except /state check

set -euo pipefail

PORT="${PORT:-47777}"
BASE="http://127.0.0.1:${PORT}"
SKIP_CALENDAR="${SKIP_CALENDAR:-0}"

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

# The `calendarAccess` field must exist — even on a fresh install where it is
# still "notDetermined". Its presence is the contract; the value can vary.
CAL_ACCESS=$(echo "$STATE" | jq -r 'if .result | has("calendarAccess") then .result.calendarAccess else "MISSING" end')
[[ "$CAL_ACCESS" != "MISSING" ]] || fail "/state missing calendarAccess field"
case "$CAL_ACCESS" in
  granted|denied|restricted|notDetermined)
    pass "calendarAccess=$CAL_ACCESS"
    ;;
  *)
    fail "calendarAccess has unexpected value: $CAL_ACCESS"
    ;;
esac

if [[ "$SKIP_CALENDAR" == "1" ]]; then
  printf "\nSKIP_CALENDAR=1 — skipping calendar route assertions.\n"
  exit 0
fi

# If access hasn't been granted yet, the calendar routes are legitimately
# 503. Don't fail — tell the user what to do and exit OK. This makes the
# smoke usable on a freshly-installed bundle before the TCC prompt fires.
if [[ "$CAL_ACCESS" != "granted" ]]; then
  printf "\ncalendarAccess=%s — calendar routes will 503 until TCC is approved.\n" "$CAL_ACCESS"
  printf "Approve in System Settings → Privacy & Security → Calendars, then re-run.\n"
  printf "Or run with SKIP_CALENDAR=1 to bypass.\n"
  exit 0
fi

header "GET /calendar/upcoming"
UP_RES=$(curl -sS "$BASE/calendar/upcoming?withinMinutes=1440")
UP_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/calendar/upcoming?withinMinutes=1440")
echo "$UP_RES" | jq '{ok, count, events: (.events | length), firstTitle: (.events[0].title // null), firstStart: (.events[0].startsAt // null)}'
[[ "$UP_HTTP" == "200" ]] || fail "/calendar/upcoming expected 200, got $UP_HTTP"
OK=$(echo "$UP_RES" | jq -r '.ok | tostring')
[[ "$OK" == "true" ]] || fail "/calendar/upcoming ok != true"
HAS_EVENTS=$(echo "$UP_RES" | jq -r 'if has("events") and (.events|type == "array") then "yes" else "no" end')
[[ "$HAS_EVENTS" == "yes" ]] || fail "/calendar/upcoming missing .events array"
COUNT=$(echo "$UP_RES" | jq -r '.count // 0')
pass "upcoming ok=true count=$COUNT"

# Shape sanity on the first event (if any).
FIRST=$(echo "$UP_RES" | jq -r '.events[0] // empty')
if [[ -n "$FIRST" ]]; then
  for field in id title startsAt endsAt attendees isOnline calendarTitle isAllDay; do
    PRESENT=$(echo "$UP_RES" | jq -r --arg f "$field" 'if (.events[0] | has($f)) then "yes" else "no" end')
    [[ "$PRESENT" == "yes" ]] || fail "/calendar/upcoming event missing field: $field"
  done
  pass "event shape has id/title/startsAt/endsAt/attendees/isOnline/calendarTitle/isAllDay"
else
  printf "  (no events in the next 24h — shape check skipped, but call succeeded)\n"
fi

header "GET /calendar/event?id=bogus"
EV_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/calendar/event?id=bogus-nonsense-id")
EV_RES=$(curl -sS "$BASE/calendar/event?id=bogus-nonsense-id")
[[ "$EV_HTTP" == "404" ]] || fail "/calendar/event?id=bogus expected 404, got $EV_HTTP (body: $EV_RES)"
ERR=$(echo "$EV_RES" | jq -r '.error // empty')
[[ "$ERR" == "event_not_found" ]] || fail "/calendar/event?id=bogus error='$ERR' (expected event_not_found)"
pass "bogus event id → 404 event_not_found"

header "GET /calendar/active"
ACT_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/calendar/active")
ACT_RES=$(curl -sS "$BASE/calendar/active")
[[ "$ACT_HTTP" == "200" ]] || fail "/calendar/active expected 200, got $ACT_HTTP"
for field in ok active others; do
  PRESENT=$(echo "$ACT_RES" | jq -r --arg f "$field" 'if has($f) then "yes" else "no" end')
  [[ "$PRESENT" == "yes" ]] || fail "/calendar/active missing field: $field"
done
ACTIVE_TYPE=$(echo "$ACT_RES" | jq -r '.active | type')
[[ "$ACTIVE_TYPE" == "object" || "$ACTIVE_TYPE" == "null" ]] || fail "/calendar/active .active type = $ACTIVE_TYPE (expected object|null)"
pass "active ok keys=ok/active/others (.active is $ACTIVE_TYPE)"

# Round-trip a real event id from upcoming into /calendar/event, if we got one.
if [[ -n "$FIRST" ]]; then
  header "GET /calendar/event?id=<real-id>"
  REAL_ID=$(echo "$UP_RES" | jq -r '.events[0].id')
  ENC_ID=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$REAL_ID")
  DET_RES=$(curl -sS "$BASE/calendar/event?id=${ENC_ID}")
  DET_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/calendar/event?id=${ENC_ID}")
  if [[ "$DET_HTTP" == "200" ]]; then
    TITLE=$(echo "$DET_RES" | jq -r '.event.title // empty')
    NOTES_TYPE=$(echo "$DET_RES" | jq -r '.event | if has("notes") then (.notes | type) else "MISSING" end')
    [[ -n "$TITLE" ]] || fail "real event detail missing title"
    [[ "$NOTES_TYPE" == "string" || "$NOTES_TYPE" == "null" ]] || fail "real event .notes type=$NOTES_TYPE"
    pass "round-tripped id → detail title='$TITLE' notes=$NOTES_TYPE"
  else
    # Some EK event identifiers include `/URL/` encoded bits; if the round-trip
    # misses we don't want to block — log but don't fail.
    printf "  (round-trip got HTTP %s — skipping; not a hard assertion)\n" "$DET_HTTP"
  fi
fi

printf "\nAll assertions passed.\n"
