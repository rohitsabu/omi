# Omi Desktop Automation Bridge — API

The automation bridge is a local HTTP listener inside the Omi Desktop app,
started when `OMI_ENABLE_LOCAL_AUTOMATION=1` (auto-set by `./run.sh --yolo`).
It exposes read/write handles for Omi state plus the meeting-lifecycle
surface we need to drive Omi from external tooling (curl, scheduled jobs,
other apps, agent scripts during the minutes→omi consolidation).

Default bind: `127.0.0.1:47777`. Override with `OMI_AUTOMATION_PORT` or the
`--automation-port=<N>` launch arg. The listener is hand-rolled on top of
`Network.framework` (`NWListener`) — there is no Vapor or Swift-NIO in this
process. See `Desktop/Sources/DesktopAutomationBridge.swift` for the router
and `Desktop/Sources/MinutesBridge.swift` for the Phase 1 minutes handlers.

Auth: none in Phase 1. The consumer today is curl + Rohit. Shared-secret
auth is planned but scoped out until a second consumer shows up.

Every response is JSON. Errors follow `{ "ok": false, "error": "<code>",
"message": "<human>" }`. Success shapes vary by route.

## Core routes (pre-existing)

### `GET /state` and `GET /health`

Returns `DesktopAutomationSnapshot` — bundle id, signed-in status, current
tab, onboarding flag, etc. Use this as the up-check before exercising any
other route.

```bash
curl -sS http://127.0.0.1:47777/state | jq .
```

### `POST /navigate`

Body: `{ "target": "settings", "settingsSection": "…", "highlightedSettingId": "…", "activateApp": true }`.
Fires an in-app `NotificationCenter` post to move the UI. Returns the updated
snapshot after a 150ms settle.

### `POST /conversation/open`

Body: `{ "conversationId": "…", "showTranscript": false, "activateApp": true }`.

### `POST /gmail-read`

Reads up to 50 recent Gmail emails and saves them as memories. No body.

---

## Minutes lifecycle routes (Phase 1)

All four wrap the minutes-agent TypeScript pipeline at
`~/Developer/entropy-negative/minutes-agent/` — the bridge shells out to
`scripts/record-now.ts`, `scripts/stop-now.ts`, and
`scripts/v2/post-meeting-enrich.ts`. This is a deliberate shim: the
consumer surface is Swift/HTTP, the implementation under the hood is still
the proven TS capture pipeline. Phase 3 of `OMI_CONSOLIDATION.md` replaces
the TS pipeline with a native Swift `PostMeetingService`; the HTTP contract
stays identical.

The minutes-agent checkout path can be overridden via
`OMI_MINUTES_AGENT_DIR`.

### `POST /minutes/start`

Begin a capture. Wraps `scripts/record-now.ts --title "…"`.

Request:

```json
{
  "meetingId": "optional-correlation-handle",
  "title": "Sprint planning",
  "source": "calendar"
}
```

- `meetingId`: ignored in Phase 1 (record-now mints its own `manual-<iso>` id
  and returns it). Reserved for Phase 2 when calendar-driven sessions get a
  predictable id up front.
- `title`: defaults to `"Manual capture HH:MM"` if omitted.
- `source`: `calendar` or `manual`. Informational; forwarded to the session
  record so downstream callers can tell auto-recordings from manual ones.

Response `200`:

```json
{
  "ok": true,
  "meetingId": "manual-2026-04-23T18:21:04.112Z",
  "startedAt": "2026-04-23T18:21:04.200Z",
  "outputPath": "/Users/rohitsabu/Library/CloudStorage/GoogleDrive-…/Meetings/2026/04/2026-04-23 — sprint-planning — rohit",
  "title": "Sprint planning"
}
```

Errors:
- `400 bad_request` — body is not valid JSON.
- `500 capture_failed` — `record-now.ts` exited non-zero (stderr tail in `message`).
- `500 capture_parse_failed` — `record-now.ts` succeeded but no JSON line on stdout.
- `503 bridge_disabled` — bridge wasn't launched with `OMI_ENABLE_LOCAL_AUTOMATION=1`.

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Sprint planning","source":"manual"}' \
  http://127.0.0.1:47777/minutes/start | jq .
```

### `POST /minutes/stop`

Stop a capture and queue post-processing. Wraps `scripts/stop-now.ts --event-id <id>`.

Request:

```json
{ "meetingId": "manual-2026-04-23T18:21:04.112Z" }
```

Response `200`:

```json
{
  "ok": true,
  "meetingId": "manual-2026-04-23T18:21:04.112Z",
  "stoppedAt": "2026-04-23T18:53:11.021Z",
  "durationSec": 1927,
  "transcriptPath": "/Users/…/Meetings/…/transcript.md",
  "audioPath": null
}
```

- `transcriptPath` is the path the TS pipeline will write to. The file may
  not exist yet at the instant `stop` returns — Minutes MCP finalises the
  transcript asynchronously. Poll `GET /minutes/transcript` with the same
  `meetingId` to pick it up.
- `audioPath` is null in Phase 1. Minutes bundles audio inside its internal
  meeting file rather than emitting it as a separate sidecar.

Errors:
- `400 bad_request` — invalid JSON body.
- `404 unknown_meeting` — no session for that `meetingId`.
- `500 stop_failed` — `stop-now.ts` exited non-zero.

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"meetingId":"manual-2026-04-23T18:21:04.112Z"}' \
  http://127.0.0.1:47777/minutes/stop | jq .
```

### `GET /minutes/transcript?meetingId=…`

Return the transcript text. Reads `<outputPath>/transcript.md` from disk —
the bridge never buffers transcript text in Swift memory.

Response `200`:

```json
{
  "text": "## Sprint planning\n\n**Attendees:** …",
  "isFinal": true,
  "meetingId": "manual-…",
  "transcriptPath": "/Users/…/transcript.md"
}
```

- `isFinal` is `true` iff the session has been stopped **and** the file
  exists on disk. A live, mid-recording request returns `isFinal: false` and
  an empty string today — live transcript streaming happens inside the TS
  pipeline's `transcript-watcher.ts`, which polls Minutes MCP directly. A
  future route (`GET /minutes/transcript/live` or a websocket) can expose
  that stream if needed; out of scope for Phase 1.

Errors:
- `400 bad_request` — missing `meetingId` query parameter.
- `404 unknown_meeting` — no session for that `meetingId`.

```bash
curl -sS "http://127.0.0.1:47777/minutes/transcript?meetingId=manual-2026-04-23T18%3A21%3A04.112Z" | jq .
```

### `POST /minutes/enrich`

Queue the post-meeting enricher. Wraps
`scripts/v2/post-meeting-enrich.ts --meeting <transcriptPath> --no-notify`,
which is backed by `claude -p` and produces the 4-section output
(Decisions / Commitments / Open questions / Follow-up email draft) into
`insights.md` + `follow-up-email-draft.md` sidecars beside the transcript.

Request:

```json
{
  "meetingId": "manual-2026-04-23T18:21:04.112Z",
  "transcriptPath": "/optional/override/path.md"
}
```

- If `transcriptPath` is omitted, the bridge uses the session's folder
  + `transcript.md`.

Response `202`:

```json
{
  "ok": true,
  "jobId": "4B7F2A2E-…-00A0",
  "meetingId": "manual-…",
  "transcriptPath": "/Users/…/transcript.md"
}
```

The enricher runs asynchronously. The HTTP response returns as soon as the
job is spawned; output sidecars appear in the meeting folder when the
enricher finishes (typically 15–45s on claude-cli backend).

Errors:
- `400 bad_request` — invalid JSON body.
- `404 unknown_meeting` — no session for that `meetingId` and no
  `transcriptPath` override.
- `409 transcript_missing` — the resolved transcript file doesn't exist on
  disk. Usually means the meeting was started but not yet stopped.

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"meetingId":"manual-2026-04-23T18:21:04.112Z"}' \
  http://127.0.0.1:47777/minutes/enrich | jq .
```

---

## Calendar

Phase 2 added a read-only `/calendar/*` surface backed by EventKit. The goal
is to retire the cookie-based `CalendarReaderService` path (and the parallel
TS calendar poller on the minutes-agent side) in favor of a single,
TCC-approved EventKit integration inside the signed Omi app. Phase 2 *only*
adds the data source — auto-triggering recordings from calendar events is
Phase 3; retiring the TS poller is Phase 4.

### Access model

On first launch the app calls `EKEventStore.requestFullAccessToEvents` once.
This fires the macOS Calendars TCC prompt if no prior decision exists for
the bundle id. Approve it (or re-enable in System Settings → Privacy →
Calendars if you missed the prompt) and the routes start returning events.

**Hardened-runtime requirement.** Because Omi ships with hardened runtime,
TCCD silently denies the Calendars request unless the app's entitlements
declare `com.apple.security.personal-information.calendars = true`. The
Info.plist `NSCalendarsFullAccessUsageDescription` key alone isn't enough —
you'll see `Policy disallows prompt … requires entitlement
com.apple.security.personal-information.calendars` in tccd logs if the
entitlement is missing. Phase 2 added it to both
`Desktop/Omi.entitlements` and `Desktop/Omi-Release.entitlements`.

`GET /state` now includes a `calendarAccess` field with one of:

| Value | Meaning |
|---|---|
| `granted` | Full access granted — `/calendar/*` routes will work. |
| `denied` | User denied. Re-enable in System Settings → Privacy → Calendars. |
| `restricted` | e.g. MDM policy; routes will 503 until lifted. |
| `notDetermined` | Prompt hasn't fired yet. First `/calendar/upcoming` hit will force it. |

```bash
curl -sS http://127.0.0.1:47777/state | jq '.result.calendarAccess'
```

When status is not `granted`, every `/calendar/*` route returns `503`:

```json
{ "ok": false, "error": "calendar_access_denied",
  "message": "EventKit access is \"denied\". Approve in System Settings → Privacy → Calendars and retry." }
```

### `GET /calendar/upcoming`

Events starting within the next N minutes.

Query params:

| Param | Type | Default | Notes |
|---|---|---|---|
| `withinMinutes` | int | `60` | Window size. Max 43200 (30 days). `400 bad_request` outside range. |
| `includeAllDay` | bool | `false` | Include events with `isAllDay=true`. |
| `includeSubscribed` | bool | `false` | Include read-only subscribed calendars (holidays, birthdays, team feeds). Default excludes them. |

Response shape:

```json
{
  "ok": true,
  "withinMinutes": 60,
  "count": 2,
  "events": [
    {
      "id": "B3C1…",
      "title": "Sprint planning",
      "startsAt": "2026-04-23T19:30:00Z",
      "endsAt": "2026-04-23T20:00:00Z",
      "location": "Zoom",
      "organizer": "Rohit Sabu",
      "attendees": ["Alice", "Bob", "carol@example.com"],
      "isOnline": true,
      "meetingUrl": "https://zoom.us/j/1234567890",
      "calendarTitle": "Work",
      "isAllDay": false,
      "notes": null
    }
  ]
}
```

`isOnline` is true iff the event has a URL pointing at a recognised video-
conferencing host (`zoom.us`, `meet.google.com`, `webex.com`,
`teams.microsoft.com`, `teams.live.com`, `bluejeans.com`). Detected across
the event's dedicated URL field, location string, and notes body.
`meetingUrl` is populated with the first match found.

```bash
curl -sS 'http://127.0.0.1:47777/calendar/upcoming?withinMinutes=120' | jq .
curl -sS 'http://127.0.0.1:47777/calendar/upcoming?withinMinutes=60&includeAllDay=true' | jq .
curl -sS 'http://127.0.0.1:47777/calendar/upcoming?includeSubscribed=true' | jq .
```

### `GET /calendar/active`

The event currently in progress (if any). "In progress" means
`startsAt ≤ now < endsAt`. All-day events are excluded. If multiple events
overlap right now, `active` is the one with the earliest `startsAt` and
`others` contains the rest (sorted by start time).

Response:

```json
{
  "ok": true,
  "active": { "id": "B3C1…", "title": "Sprint planning", …as above },
  "others": []
}
```

When nothing is in progress `active` is `null` and `others` is empty.

```bash
curl -sS http://127.0.0.1:47777/calendar/active | jq .
```

### `GET /calendar/event`

Single event detail, including notes.

Query params:

| Param | Type | Notes |
|---|---|---|
| `id` | string (required) | The EventKit identifier returned on upcoming/active responses. |

Response:

```json
{
  "ok": true,
  "event": {
    "id": "B3C1…",
    "title": "Sprint planning",
    …same fields as upcoming…,
    "notes": "Agenda:\n1. Review last sprint…\n\nZoom link: https://zoom.us/…"
  }
}
```

Errors:

- `400 bad_request` — missing `?id=`.
- `404 event_not_found` — no event with that identifier.

```bash
curl -sS "http://127.0.0.1:47777/calendar/event?id=$(curl -sS http://127.0.0.1:47777/calendar/upcoming | jq -r '.events[0].id')" | jq .
```

### Read-only by design

Phase 2 does not expose create/update/delete/RSVP. Omi does not write to the
user's calendar; the automation surface mirrors that. If a future phase
needs writes they'll land behind a separate feature flag.

---

## Tests

`desktop/test/bridge_minutes.sh` is the contract smoke test. It asserts:

1. `GET /state` returns `bridgeEnabled: true`.
2. `POST /minutes/start` returns an `ok:true` body with `meetingId` + `outputPath`.
3. `GET /minutes/transcript?meetingId=…` returns a valid JSON shape.
4. `POST /minutes/stop` returns `ok:true` with a non-negative `durationSec`.
5. `POST /minutes/enrich` (against the fixture transcript under
   `minutes-agent/scripts/v2/fixtures/sample-meeting/`) returns `202` with a
   `jobId`.

Run it after `./run.sh --yolo` is up:

```bash
./desktop/test/bridge_minutes.sh
```

Set `SKIP_CAPTURE=1` to hit only the `/state` check (useful when Minutes MCP
isn't connected and you just want to smoke the bridge HTTP layer).

`desktop/test/bridge_calendar.sh` is the Phase 2 calendar smoke test. It
asserts:

1. `GET /state` includes a `calendarAccess` field.
2. `GET /calendar/upcoming` returns `{ ok: true, events: [...] }` — doesn't
   assert on specific titles, the user's calendar is real.
3. `GET /calendar/event?id=bogus-nonsense-id` returns 404 `event_not_found`.

Set `SKIP_CALENDAR=1` to bypass if calendar access hasn't been granted yet
(so a fresh install doesn't fail the smoke before the TCC prompt is
approved):

```bash
./desktop/test/bridge_calendar.sh
SKIP_CALENDAR=1 ./desktop/test/bridge_calendar.sh
```

## Guardrails

- Don't add webhook callbacks, pagination, or auth in Phase 1.
- Don't accumulate transcript text in Swift memory — read from disk.
- (Phase 1 guardrail, now obsolete as of Phase 3.) Don't reach past the TS
  pipeline into the Minutes MCP directly from Swift. Phase 3 changed this —
  the default `/minutes/*` path now speaks MCP from inside Omi. See
  § Phase 3 note below.

## Phase 3 note — native Swift lifecycle + TS fallback

As of Phase 3 (2026-04-23), the default implementation behind the
`/minutes/start|stop|transcript|enrich` routes is a native Swift actor
(`MinutesLifecycleService`, in `Desktop/Sources/MinutesLifecycle.swift`)
that spawns `npx minutes-mcp` as a long-lived subprocess and speaks MCP
JSON-RPC 2.0 over newline-delimited JSON on stdio — the same wire protocol
the TS `@modelcontextprotocol/sdk` StdioClientTransport speaks. The Phase 1
shell-out path to `scripts/record-now.ts` + `scripts/stop-now.ts` is retained
as a fallback lane.

**Feature flag.** `OMI_MINUTES_LIFECYCLE` picks the implementation:

| Value | Behaviour |
|---|---|
| `swift` (default) | Native Swift actor. MCP subprocess lives inside Omi. Meeting state persists to `~/Library/Application Support/minutes-agent/state.json`. Graceful shutdown on app quit. |
| `ts` | Phase 1 behaviour — each route shells out to `scripts/record-now.ts` / `scripts/stop-now.ts`. Unchanged byte-for-byte from Phase 1. |

Set it in the same shell you launch `./run.sh --yolo` in. Default is `swift`
once Phase 3 smoke tests pass. If you see a lifecycle regression on a build
that shouldn't be breaking things, flip to `ts` for an instant fallback
while the Swift side is investigated.

**HTTP contract.** The four routes return byte-identical responses under
both modes. The only observable difference from the consumer side is the
Swift mode's graceful-shutdown behaviour on app quit (not visible via
HTTP) and the fact that the MCP subprocess is owned by Omi instead of by
the TS helper.

**Enricher stays in TS.** `POST /minutes/enrich` still spawns
`scripts/v2/post-meeting-enrich.ts` in both modes — Phase 3 deliberately
doesn't port the enricher. A future phase may, but the prompt + 4-section
output contract are preserved in TS for now.

**state.json compatibility.** Swift and TS read/write the same
`~/Library/Application Support/minutes-agent/state.json` — same schema, same
atomic-rename write pattern, same meeting folder layout. Switching between
`OMI_MINUTES_LIFECYCLE=swift` and `=ts` doesn't require a migration. Swift
adds three additive optional fields (`status`, `audioPath`, `transcriptPath`)
that the TS side preserves on reads but doesn't use.

**Phase 3 smoke.** `desktop/test/bridge_minutes_phase3.sh` asserts the full
record → stop → transcript finalisation → enrich → `.enriched` sentinel
cycle on the Swift path, plus a TS-fallback regression leg. See the script
preamble for `SKIP_MCP`, `SKIP_ENRICH`, `SKIP_GRACEFUL`, `SKIP_TS_FALLBACK`
toggles.
