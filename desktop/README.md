# OMI Desktop

macOS app for OMI — always-on AI companion. Swift/SwiftUI frontend, Rust backend.

## Structure

```
Desktop/          Swift/SwiftUI macOS app (SPM package)
Backend-Rust/     Rust API server (Firestore, Redis, auth, LLM)
acp-bridge/       ACP bridge for Claude integration (TypeScript)
agent-cloud/      Cloud agent service
dmg-assets/       DMG installer resources
```

## Development

Requires macOS 14.0+, Rust toolchain, and code signing with an Apple Developer ID.

```bash
# Run (builds Swift app, starts Rust backend, launches app)
./run.sh

# Run with clean slate (resets onboarding, permissions, UserDefaults)
./reset-and-run.sh
```

The app is signed with `Developer ID Application: Matthew Diakonov (S6DP5HF77G)`. You need access to this signing identity to build and run.

## Automation bridge & AI

When `OMI_ENABLE_LOCAL_AUTOMATION=1` (auto-set by `./run.sh --yolo`) the
app exposes a local HTTP bridge on `127.0.0.1:47777`. See
[`BRIDGE_API.md`](./BRIDGE_API.md) for the full route reference
(minutes lifecycle, calendar, AI).

AI wiring on this fork is a local subprocess that shells out to the
user's signed-in Claude Code CLI — no API keys stored, the Omi app
stays signed-out against Omi's own cloud backend. See
[`AI_WIRING.md`](./AI_WIRING.md) for the decision record and migration
paths to alternative backends.

## License

MIT
