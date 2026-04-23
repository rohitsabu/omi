import Foundation

// MARK: - AIBridge
//
// HTTP surface for the Omi Desktop AI wiring. Backed by `AIService`, which
// shells out to `claude -p --dangerously-skip-permissions`. See
// `AI_WIRING.md` and `AIService.swift` for the full rationale.
//
// This module is deliberately separate from `DesktopAutomationBridge` so
// the Phase 3 `MinutesLifecycle` work happening in parallel doesn't
// collide. The only edit to `DesktopAutomationBridge.swift` is a five-line
// dispatch stanza + state-snapshot wiring — every other piece of the AI
// surface lives in this file.
//
// Routes:
//   POST /ai/ask     — ask the model a question
//   GET  /ai/health  — is claude installed, is it ready, what version
//
// State extension:
//   The router also exposes `AIBridgeState.currentAIFields()` which
//   `DesktopAutomationBridge.route(_:)` folds into its `GET /state`
//   response so external tooling can decide whether to call `/ai/ask`
//   without a separate round-trip to `/ai/health`.

// MARK: Request / response shapes

struct AIAskRequest: Codable {
  let prompt: String
  let model: String?
}

struct AIAskSuccess: Codable {
  let ok: Bool
  let text: String
  /// The model actually invoked. Echoed back so callers can log what they got.
  let model: String?
}

struct AIAskError: Codable {
  let ok: Bool
  let error: String   // short code, e.g. "claude_not_authenticated"
  let message: String // human-readable detail
}

struct AIHealthResponse: Codable {
  let ok: Bool
  let provider: String
  let ready: Bool
  let claudeVersion: String?
  let claudePath: String?
  let error: String?
}

/// The fields `GET /state` merges into its snapshot. Kept in a tiny
/// struct so the only touch point in `DesktopAutomationBridge` is one
/// call to `AIBridgeState.currentAIFields()`.
struct AIStateFields: Codable, Sendable {
  let aiProvider: String      // "claude-cli" | "none"
  let aiReady: Bool
  let aiError: String?
}

// MARK: - Router

enum AIBridgeRouter {
  /// Returns a JSON body + HTTP status for the given AI route, or nil if
  /// the (method, path) pair is not an AI route. Path matching is exact.
  static func handle(method: String, path: String, body: Data) async -> (Data, Int)? {
    // Strip query string for path matching (no AI routes use query args
    // today but keep the parity with MinutesBridgeRouter for future-proofing).
    let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

    guard DesktopAutomationLaunchOptions.isEnabled else {
      if pathOnly.hasPrefix("/ai/") {
        return (
          AIBridgeRouter.errorBody(
            "bridge_disabled", "OMI_ENABLE_LOCAL_AUTOMATION is not set"), 503
        )
      }
      return nil
    }

    switch (method, pathOnly) {
    case ("POST", "/ai/ask"):
      return await AIBridgeHandlers.ask(body: body)
    case ("GET", "/ai/health"):
      return await AIBridgeHandlers.health()
    default:
      return nil
    }
  }

  static func errorBody(_ code: String, _ message: String) -> Data {
    let payload = AIAskError(ok: false, error: code, message: message)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? enc.encode(payload)) ?? Data("{\"ok\":false}".utf8)
  }

  static func successBody<T: Encodable>(_ value: T) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? enc.encode(value)) ?? Data("{\"ok\":true}".utf8)
  }
}

// MARK: - Handlers

enum AIBridgeHandlers {
  static func ask(body: Data) async -> (Data, Int) {
    // Decode body. 400 on malformed JSON, 400 on empty prompt.
    let req: AIAskRequest
    do {
      req = try JSONDecoder().decode(AIAskRequest.self, from: body)
    } catch {
      return (
        AIBridgeRouter.errorBody("bad_request", "invalid JSON body: \(error)"), 400
      )
    }

    let trimmed = req.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return (AIBridgeRouter.errorBody("empty_prompt", "prompt must not be empty"), 400)
    }

    // Invalidate the health cache on explicit /ai/ask — gives the user a
    // way to force a re-probe by retrying the call after fixing their env.
    await AIService.shared.invalidateHealth()

    do {
      let text = try await AIService.shared.ask(prompt: trimmed, model: req.model)
      let payload = AIAskSuccess(ok: true, text: text, model: req.model)
      return (AIBridgeRouter.successBody(payload), 200)
    } catch let e as AIServiceError {
      let status: Int
      switch e {
      case .emptyPrompt: status = 400
      case .claudeNotInstalled: status = 503
      case .claudeNotAuthenticated: status = 503
      case .timeout: status = 504
      case .invocationFailed: status = 500
      case .badJSON: status = 500
      }
      return (AIBridgeRouter.errorBody(e.code, e.description), status)
    } catch {
      return (
        AIBridgeRouter.errorBody(
          "invocation_failed", "unexpected error: \(error.localizedDescription)"), 500
      )
    }
  }

  static func health() async -> (Data, Int) {
    let health = await AIService.shared.health(forceRefresh: true)
    let payload = AIHealthResponse(
      ok: health.ready,
      provider: health.provider,
      ready: health.ready,
      claudeVersion: health.claudeVersion,
      claudePath: health.claudePath,
      error: health.error
    )
    return (AIBridgeRouter.successBody(payload), health.ready ? 200 : 503)
  }
}

// MARK: - State merge helper

enum AIBridgeState {
  /// Build the AI fields that `GET /state` folds into its snapshot. Uses
  /// the cached health if fresh, otherwise probes (3s max).
  static func currentAIFields() async -> AIStateFields {
    let h = await AIService.shared.health(forceRefresh: false)
    return AIStateFields(
      aiProvider: h.provider,
      aiReady: h.ready,
      aiError: h.error
    )
  }
}
