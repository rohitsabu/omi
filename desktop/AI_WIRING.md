# AI Wiring — decision record

**Date:** 2026-04-23.
**Owners:** `Desktop/Sources/AIService.swift`, `Desktop/Sources/AIBridge.swift`.

## Summary

Omi Desktop exposes local AI capability via two HTTP routes on the
automation bridge (`http://127.0.0.1:47777`):

- `POST /ai/ask`
- `GET /ai/health`

…plus three fields on `GET /state` (`aiProvider`, `aiReady`, `aiError`).

The implementation is a Swift actor (`AIService`) that shells out to
`claude -p --dangerously-skip-permissions`, piping the prompt over stdin.
This reuses the `claudeCliCallModel` pattern from
`minutes-agent/scripts/v2/lib/enrich.ts` — same flags, same 90s timeout,
same 8 MiB stdout buffer. The Omi app stays signed-out against Omi's own
cloud backend; AI runs entirely as a local subprocess piggybacking on the
user's existing Claude Code login.

## What was already in the fork

The audit before wiring started turned up a surprisingly full AI layer
already present:

- `APIKeyService.swift` — in-memory fetch of Anthropic / Gemini / Firebase
  / Google-Calendar keys from the Omi cloud backend, plus a BYOK flow
  that lets free-plan users supply their own keys.
- `BYOKValidator.swift` — validates supplied keys against each provider.
- `Chat/ACPBridge.swift` — long-lived Node.js subprocess running the Agent
  Client Protocol chat bridge. Supports Anthropic-API-key mode and OAuth
  mode; feeds `Providers/ChatProvider.swift`.
- `ProactiveAssistants/Core/GeminiClient.swift` — direct Gemini API
  client for screen-activity analysis and task extraction.
- `OnboardingBYOKStepView.swift` — UI for entering BYOK keys during
  onboarding.
- `ModelQoS.swift`, `TierManager.swift` — model tier gating.

The gap: none of this is exposed via the automation bridge. There was no
`/ai/ask` route, no `AIService`, no `/state` fields for AI readiness. The
chat layer requires a paid upgrade (`ClaudeAuthSheet.swift`) and isn't
usable from a signed-out app. So for "prove AI works on the fork today,
signed out, no keys" we need a new path — which is what this doc covers.

## Options considered

### (A) `claude -p` CLI subprocess — SHIPPED

Shell out to the user's already-signed-in Claude Code CLI. Same pattern
as `minutes-agent/scripts/v2/lib/enrich.ts` → `claudeCliCallModel`, which
has been running in production for post-meeting enrichment for weeks.

- **Pros:** zero new secrets; reuses auth the user already has; single
  invocation pattern shared with minutes-agent so one set of error modes
  to learn; matches the Phase 3 trajectory called out in
  `minutes-agent/OMI_CONSOLIDATION.md` ("Phase 3 initial impl shells out
  to `claude -p` (proven end-to-end)"); swappable for any other backend
  behind the same `ask(prompt:model:)` signature.
- **Cons:** cold-start latency ~1–3s per call (Node + subprocess spawn);
  8 MiB stdout cap; no streaming (responses arrive as one blob).

### (B) Anthropic API directly from Swift

Use `APIKeyService.effectiveAnthropicKey` and hit
`https://api.anthropic.com/v1/messages` directly from `URLSession`.

- **Pros:** ~200–500ms cold-start; native streaming; no Node dependency.
- **Cons:** the key is either bundled-fetched from Omi backend (only
  works while signed in, against our constraint) or user-supplied via
  BYOK onboarding (requires unblocking the signed-out key-entry UX);
  another code path that handles credentials; duplicates ACPBridge which
  already does API-key mode. Ongoing cost ownership (who pays?).

### (C) Anthropic Agent SDK embed

The Agent SDK ships for Python/TypeScript but not Swift. "Embedding" in
practice means a Node.js subprocess wrapping the SDK — which is exactly
what `Chat/ACPBridge.swift` already does, and nearly exactly what
`claude -p` already is. Not meaningfully different from (A) for our
purposes.

### (D) Multi-provider abstraction + settings UI

Build `LLMProvider` protocol with implementations for Claude CLI,
Anthropic API, OpenAI, Ollama, plus a settings pane to pick between
them. Eventual correct answer; premature now — we have one consumer
(curl + future minutes-agent enrichment migration) and no user-facing
decision to make yet. The Chat layer already has most of a
multi-provider abstraction via ACPBridge; AIService doesn't need to
duplicate it.

## Recommendation: (A)

Shipped as `AIService.swift` + `AIBridge.swift`. Total new code ~650
lines across two files plus ~30 lines of surgical edits to
`DesktopAutomationBridge.swift` (one route-dispatch stanza, three new
fields on `DesktopAutomationSnapshot`, one helper that folds AI fields
into the snapshot on every response that returns one).

**Why this over (B)** despite the latency cost: the entire point of this
milestone was to wire AI **without re-enabling the cloud/sign-in flow or
storing new secrets.** (B) requires either backend auth (violates the
signed-out constraint) or a fresh key-input path (adds more UX surface
than the AI feature itself). (A) is the constraint-respecting answer.

## Migration paths

Because `AIService.ask(prompt:model:)` is the only interface callers
depend on, switching backends is a local refactor of `AIService`:

- **To (B): direct Anthropic API.** Replace the `runClaude(...)` body
  with a `URLSession` call using `APIKeyService.currentAnthropicKey`.
  Keep the error taxonomy — the same `AIServiceError` cases map onto
  HTTP errors from `api.anthropic.com`. Estimated effort: 2–3 hours,
  plus a pass on key-onboarding UX if we want this to work signed-out.

- **To (C): Agent SDK via Node bridge.** Replace `runClaude(...)` with a
  call into `ACPBridge` (already in-process, already long-lived). More
  work if we want the full SDK tool-calling path; minimal if we just
  want streaming deltas. Estimated effort: half a day to wire,
  full day to expose streaming via server-sent events on `/ai/ask`.

- **To (D): multi-provider.** Extract `AIService` as a protocol, add
  `ClaudeCLIProvider`, `AnthropicAPIProvider`, `OllamaProvider`
  conforming types. Add a settings page that writes the selected
  provider to `UserDefaults("ai_provider")`. Estimated effort: 2–3 days
  including UI and storage. Not recommended until we have a second
  caller asking for a specific provider.

## Post-shipping refinement: route minutes-agent enrichment through `AIService`

`minutes-agent/scripts/v2/lib/enrich.ts` currently calls `claude -p`
directly. The `PostMeetingService` Swift port called out in Phase 3 of
`OMI_CONSOLIDATION.md` can route through `AIService.ask(...)` instead of
re-implementing the subprocess plumbing. That gives us one place to fix
timeouts / buffer caps / error taxonomy, and one place to swap backends.

This is not part of the current milestone — the TS pipeline works today
and Phase 3's own swap is scheduled independently. Flagged here so
whoever does the Phase 3 port sees the opportunity.

## Operational notes

- **Timeout & buffer:** 90s and 8 MiB, hardcoded to mirror
  `claude-runner.ts`. Any change needs matching edits on the
  minutes-agent side.
- **Health caching:** `/ai/health` probes `claude --version` with a 3s
  timeout; result cached for 30s to keep `/state` polls cheap.
- **Escape hatches:** `OMI_CLAUDE_BIN_OVERRIDE` (absolute path, highest
  priority) and `OMI_CLAUDE_PATH_OVERRIDE` (PATH-style search list).
  The override env vars are the supported way to test missing-claude
  behaviour in CI.
- **PATH augmentation:** `AIService.augmentedPath()` prepends
  `~/.claude/local`, every `~/.nvm/versions/node/*/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin` before the inherited PATH. Matches
  `MinutesSubprocess.augmentedPath()` from `MinutesBridge.swift`. This
  is needed because LaunchServices strips the shell PATH.

## Files

- `Desktop/Sources/AIService.swift` — the actor + subprocess plumbing.
- `Desktop/Sources/AIBridge.swift` — router, handlers, state-merge helper.
- `Desktop/Sources/DesktopAutomationBridge.swift` — +3 snapshot fields,
  one dispatch stanza, one `snapshotWithAI()` helper call per snapshot
  return path. No other edits.
- `test/bridge_ai.sh` — smoke test.
- `BRIDGE_API.md` — public-facing API reference (§ AI).
