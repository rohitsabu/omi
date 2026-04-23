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

## Guardrails

- Don't add webhook callbacks, pagination, or auth in Phase 1.
- Don't accumulate transcript text in Swift memory — read from disk.
- Don't reach past the TS pipeline into the Minutes MCP directly from Swift.
  Phase 3 replaces the TS pipeline; until then the TS pipeline is the only
  author of meeting folder contents.
