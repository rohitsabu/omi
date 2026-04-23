# Omi Desktop Automation Bridge — API

The automation bridge is a local HTTP listener inside the Omi Desktop app,
started when `OMI_ENABLE_LOCAL_AUTOMATION=1` (auto-set by `./run.sh --yolo`).
It exposes read/write handles for Omi state plus the meeting-lifecycle
surface we need to drive Omi from external tooling (curl, scheduled jobs,
other apps, agent scripts).

Default bind: `127.0.0.1:47777`. Override with `OMI_AUTOMATION_PORT` or the
`--automation-port=<N>` launch arg. The listener is hand-rolled on top of
`Network.framework` (`NWListener`) — there is no Vapor or Swift-NIO in this
process. See `Desktop/Sources/DesktopAutomationBridge.swift` for the router
and `Desktop/Sources/MinutesBridge.swift` for the minutes-lifecycle handlers.

Auth: none today. The consumer is curl + Rohit. Shared-secret auth is
planned but scoped out until a second consumer shows up.

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

## Minutes lifecycle routes

The four `/minutes/*` routes are served by the native Swift lifecycle actor
in `Desktop/Sources/MinutesLifecycle.swift`. Phase 4 (2026-04-24) deleted the
TS shell-out path (`scripts/record-now.ts`, `scripts/stop-now.ts`) and the
`OMI_MINUTES_LIFECYCLE` env switch — Swift is the only implementation.

The post-meeting enricher continues to run as a TS subprocess
(`scripts/v2/post-meeting-enrich.ts`) — it's the one TS surface that survived
Phase 4. The minutes-agent checkout path can be overridden via
`OMI_MINUTES_AGENT_DIR` (used by the enricher invocation).

### `POST /minutes/start`

Begin a capture. Calls `MinutesLifecycleService.start(title:source:)`, which
mints a `manual-<iso>` correlation handle, opens the per-meeting folder under
`~/Library/CloudStorage/GoogleDrive-…/Meetings/YYYY/MM/`, and issues
`start_recording` to the long-lived `npx minutes-mcp` subprocess via MCP
JSON-RPC.

Request:

```json
{
  "meetingId": "optional-correlation-handle",
  "title": "Sprint planning",
  "source": "calendar"
}
```

- `meetingId`: ignored — the actor mints its own `manual-<iso>` id and
  returns it. Reserved for a future calendar-driven path that wants a
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
- `500 capture_failed` — `start_recording` MCP call failed or returned no PID.
- `503 bridge_disabled` — bridge wasn't launched with `OMI_ENABLE_LOCAL_AUTOMATION=1`.

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Sprint planning","source":"manual"}' \
  http://127.0.0.1:47777/minutes/start | jq .
```

### `POST /minutes/stop`

Stop a capture. Calls `MinutesLifecycleService.stop(meetingId:)`, which
issues `stop_recording` to the MCP subprocess, parses the response (sync
`**Saved:** <path>` or async `Job: <id>`), and either copies the transcript
into the per-meeting folder synchronously or kicks off a 120s disk-poll
that watches both the hinted path and `~/meetings/` for the finalised file.

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

- `transcriptPath` is the path the lifecycle actor will write to. The file
  may not exist yet at the instant `stop` returns — Minutes MCP finalises
  the transcript asynchronously, and the actor's disk-poll runs in the
  background for up to 120s. Poll `GET /minutes/transcript` with the same
  `meetingId` to pick it up.
- `audioPath` is reserved for symmetry — Minutes bundles audio inside its
  internal meeting file rather than emitting a separate sidecar, so this is
  null today.

Errors:
- `400 bad_request` — invalid JSON body.
- `404 unknown_meeting` — no session for that `meetingId`.
- `500 stop_failed` — `stop_recording` MCP call failed.

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
  an empty string today — live transcript streaming was previously handled
  by the (now-deleted) `scripts/transcript-watcher.ts`. A future route
  (`GET /minutes/transcript/live` or a websocket) can expose that stream if
  a consumer needs it.

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

## AI

Local AI wiring lives in `Desktop/Sources/AIService.swift` (a Swift actor)
and `Desktop/Sources/AIBridge.swift` (HTTP surface). The implementation
shells out to the user's already-signed-in Claude Code CLI
(`claude -p --dangerously-skip-permissions`) piping the prompt over stdin,
with a 90s timeout and an 8 MiB stdout buffer — the same invariants
`minutes-agent/scripts/v2/lib/enrich.ts` uses for its `claudeCliCallModel`
path. No API keys are requested or stored. The Omi app stays signed-out
against Omi's own cloud backend; AI is strictly a local subprocess.

Why this shape: the user is already authenticated to Claude Code, so there
is zero new secret surface for Omi Desktop to manage. `AIService` is a
thin adapter — when we want lower latency later we can swap its single
subprocess call for a direct Anthropic API request via
`APIKeyService.effectiveAnthropicKey` without breaking the
`ask(prompt:model:)` contract or any `/ai/*` route. See
`desktop/AI_WIRING.md` for the full decision record, including the
alternatives (direct Anthropic API, Agent SDK embed, multi-provider
abstraction) and how to migrate to each.

### `GET /ai/health`

Probes whether `claude` is on PATH and responsive. Runs `claude --version`
with a 3s timeout and caches the result for 30s (so `/state` polls stay
cheap). Returns `200` when ready, `503` otherwise.

```json
{
  "ok": true,
  "provider": "claude-cli",
  "ready": true,
  "claudeVersion": "2.1.109 (Claude Code)",
  "claudePath": "/Users/you/.local/bin/claude"
}
```

On failure: `provider` may be `"none"` (binary missing) or `"claude-cli"`
with `ready=false` (binary exists but `--version` failed). The `error`
field carries a short human-readable detail.

### `POST /ai/ask`

Body:

```json
{ "prompt": "Reply with exactly the word PONG", "model": "claude-sonnet-4-6" }
```

- `prompt` (required) — trimmed; empty strings return `400 empty_prompt`.
- `model` (optional) — slug forwarded as `--model`. Defaults to
  `$MINUTES_V2_MODEL` then `claude-sonnet-4-6`.

Success:

```json
{ "ok": true, "text": "PONG", "model": "claude-sonnet-4-6" }
```

Error shape mirrors other bridge routes: `{ "ok": false, "error": "<code>",
"message": "<human>" }`. Status code by `error`:

| Code | HTTP | Meaning |
|---|---|---|
| `empty_prompt` | 400 | Prompt was empty or whitespace. |
| `bad_request` | 400 | Body wasn't valid JSON / didn't decode. |
| `claude_not_installed` | 503 | `claude` binary not on augmented PATH. |
| `claude_not_authenticated` | 503 | `claude` ran but stderr indicates sign-in required. |
| `timeout` | 504 | Subprocess exceeded the 90s wall-clock. |
| `invocation_failed` | 500 | Non-zero exit without a recognised sub-case. |
| `bridge_disabled` | 503 | `OMI_ENABLE_LOCAL_AUTOMATION` is not set. |

### `/state` additions

`GET /state` now folds three AI fields into the existing snapshot:

```json
{
  "aiProvider": "claude-cli",
  "aiReady": true,
  "aiError": null
}
```

When the CLI is missing or unauthenticated, `aiProvider` becomes `"none"`
(binary missing) or stays `"claude-cli"` (binary present, not ready); in
both cases `aiReady=false` and `aiError` carries a one-line reason. The
probe is cached for 30s, so `/state` remains cheap to poll.

### Escape hatches

- `OMI_CLAUDE_BIN_OVERRIDE=/abs/path/to/claude` — pin a specific binary.
  When set to a path that doesn't exist, the bridge reports `aiReady=false`
  and `/ai/ask` returns `503 claude_not_installed`. Used by
  `bridge_ai.sh` for the missing-claude test case.
- `OMI_CLAUDE_PATH_OVERRIDE=/colon/separated/PATH` — override the search
  PATH without touching the process-wide `$PATH`. Useful for CI.
- No config for the 90s timeout or 8 MiB buffer — these are hardcoded to
  match `claude-runner.ts`. If you need to change them, change
  `AIService.timeoutSeconds` and `AIService.maxStdoutBytes` in lockstep
  with the minutes-agent side.

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

`desktop/test/bridge_ai.sh` is the AI-wiring smoke test. It asserts:

1. `GET /state` exposes the `aiProvider` and `aiReady` fields.
2. `GET /ai/health` returns a known `provider` value and a version string
   when ready.
3. `POST /ai/ask` returns `ok:true` with non-empty text for a real prompt
   (skipped automatically if claude-cli is not ready).
4. `POST /ai/ask` with an empty prompt returns `HTTP 400 empty_prompt`.

Run after `./run.sh --yolo` is up:

```bash
./desktop/test/bridge_ai.sh
SKIP_ASK=1 ./desktop/test/bridge_ai.sh   # HTTP-shape only, no model call
```

The missing-claude path is documented inside the script and requires an
app relaunch with `OMI_CLAUDE_BIN_OVERRIDE=/nonexistent/path`.

## Guardrails

- Don't add webhook callbacks, pagination, or auth without a second
  consumer asking for them.
- Don't accumulate transcript text in Swift memory — read from disk.

## Implementation note — native Swift lifecycle (Phase 3 → Phase 4)

The `/minutes/start|stop|transcript|enrich` routes are served by the native
Swift actor `MinutesLifecycleService` in
`Desktop/Sources/MinutesLifecycle.swift`. The actor spawns `npx minutes-mcp`
as a long-lived subprocess and speaks MCP JSON-RPC 2.0 over newline-delimited
JSON on stdio — same wire protocol the TS `@modelcontextprotocol/sdk`
StdioClientTransport speaks.

**History.** Phase 1 (Apr 23) shipped the routes as TS shell-outs to
`scripts/record-now.ts` / `scripts/stop-now.ts`. Phase 3 (Apr 23) added the
native Swift actor as the default with `OMI_MINUTES_LIFECYCLE=ts` as an
escape hatch. Phase 4 (Apr 24) deleted both the TS scripts and the
env-switch fallback — Swift is now the only path.

**Enricher stays in TS.** `POST /minutes/enrich` spawns
`scripts/v2/post-meeting-enrich.ts` as a fire-and-forget subprocess via
`MinutesLifecycleService.enrich(transcriptPath:meetingId:)`. The prompt +
4-section output contract live in TS; a future phase may port them to
native Swift HTTP against Anthropic's API.

**state.json schema.** The lifecycle persists to
`~/Library/Application Support/minutes-agent/state.json` using the schema
inherited from the now-archived `scripts/lib/state.ts`. The Swift actor
adds three optional fields (`status`, `audioPath`, `transcriptPath`) on top
of the TS shape; readers ignore unknown fields.

**Phase 3 smoke.** `desktop/test/bridge_minutes_phase3.sh` exercises the
full record → stop → transcript finalisation → enrich → `.enriched`
sentinel cycle. See the script preamble for `SKIP_MCP`, `SKIP_ENRICH`,
`SKIP_GRACEFUL` toggles.

**Phase 4 happy-path smoke.** `desktop/test/bridge_phase4_e2e.sh` runs a
short (5s) end-to-end record → stop → enrich and asserts the enricher
subprocess actually launches.
