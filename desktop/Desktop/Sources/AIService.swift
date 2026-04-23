import Foundation

// MARK: - AIService
//
// Local AI wiring for the Omi Desktop fork.
//
// Mechanism: shell out to the user's logged-in Claude Code CLI
//   `claude -p --dangerously-skip-permissions [--model …] --output-format text`
// piping the prompt over stdin. Outputs are captured with an 8 MiB stdout
// buffer and a 90s wall-clock timeout. This mirrors the
// `claudeCliCallModel` path inside `minutes-agent/scripts/v2/lib/enrich.ts`
// which is the proven, battle-tested invocation pattern — same flags, same
// timeouts, same buffer size. The result is that the post-meeting
// enrichment pipeline and this HTTP-facing `AIService` converge on one
// invariant the whole codebase already understands.
//
// Why piggyback on Claude Code instead of calling the Anthropic API
// directly or embedding an SDK?
//
//   * The user is already signed into Claude Code. No API key to request,
//     store, scope, or rotate. Zero new secret surface — which means zero
//     new security review overhead on our side.
//   * `claude -p` is the contract minutes-agent already depends on for
//     post-meeting enrichment, so a failure in one is a failure we've seen
//     in the other. One set of error modes to learn.
//   * OMI_CONSOLIDATION.md's Phase 3 explicitly calls out
//     "Phase 3 initial impl shells out to `claude -p` (proven end-to-end)"
//     as the planned trajectory for the post-meeting service. AIService is
//     the generalisation of that same subprocess pattern.
//
// Trade-offs:
//   * Cold-start latency ~1–3s per call (subprocess spawn + Node runtime).
//     Acceptable for the "desktop agent bridge" use case; not acceptable
//     for tight inner loops. If that becomes a bottleneck we can swap the
//     backend to the Anthropic API using `APIKeyService.effectiveAnthropicKey`
//     without changing the `ask(...)` signature.
//   * Buffer cap: 8 MiB stdout. If a caller asks for a gigantic response
//     it will be truncated at 8 MiB — same as minutes-agent's contract.
//   * Timeout: 90s. Anything slower than that throws `.timeout`.
//
// Testability:
//   * `OMI_CLAUDE_PATH_OVERRIDE` env var overrides `claude` lookup for
//     simulating missing-binary conditions without actually uninstalling
//     Claude Code. See `bridge_ai.sh`.
//   * `OMI_CLAUDE_BIN_OVERRIDE` env var can pin an absolute path to a
//     specific `claude` binary if PATH resolution is misbehaving. Exists
//     mainly as a CI escape hatch.

enum AIServiceError: Error, CustomStringConvertible, Sendable {
  /// The `claude` binary isn't on PATH (or the override PATH). User needs
  /// to install Claude Code, or unset `OMI_CLAUDE_PATH_OVERRIDE`.
  case claudeNotInstalled(detail: String)

  /// `claude` is installed but not signed in. Stdout/stderr usually
  /// mentions "not authenticated" or the exit code is non-zero with a
  /// short error. The detail payload echoes that so callers can surface it
  /// in the UI.
  case claudeNotAuthenticated(detail: String)

  /// The subprocess didn't complete within 90s.
  case timeout(seconds: Int)

  /// Structured-output mode asked for JSON decoding but either the
  /// response wasn't JSON at all, or `JSONDecoder` rejected it.
  case badJSON(detail: String, rawOutput: String)

  /// Subprocess failed for a reason outside the three cases above. Exit
  /// code + stderr tail come through in `detail`.
  case invocationFailed(detail: String, exitCode: Int32)

  /// The caller passed an empty prompt. Kept separate from a backend
  /// failure because the bridge layer returns HTTP 400 for this.
  case emptyPrompt

  var description: String {
    switch self {
    case .claudeNotInstalled(let detail): return "claudeNotInstalled: \(detail)"
    case .claudeNotAuthenticated(let detail): return "claudeNotAuthenticated: \(detail)"
    case .timeout(let seconds): return "timeout after \(seconds)s"
    case .badJSON(let detail, _): return "badJSON: \(detail)"
    case .invocationFailed(let detail, let code): return "invocationFailed(exit=\(code)): \(detail)"
    case .emptyPrompt: return "emptyPrompt"
    }
  }

  /// A short, client-safe error code string for HTTP responses.
  var code: String {
    switch self {
    case .claudeNotInstalled: return "claude_not_installed"
    case .claudeNotAuthenticated: return "claude_not_authenticated"
    case .timeout: return "timeout"
    case .badJSON: return "bad_json"
    case .invocationFailed: return "invocation_failed"
    case .emptyPrompt: return "empty_prompt"
    }
  }
}

/// Health probe result, used by `/ai/health` and `/state`.
struct AIHealth: Codable, Sendable {
  let provider: String           // "claude-cli" | "none"
  let ready: Bool
  let claudePath: String?        // resolved path to the `claude` binary, if found
  let claudeVersion: String?     // output of `claude --version`, if found
  let error: String?             // short message when ready=false
}

actor AIService {
  static let shared = AIService()

  /// Hard caps — mirrored from minutes-agent/scripts/v2/lib/enrich.ts
  static let timeoutSeconds: Int = 90
  static let maxStdoutBytes: Int = 8 * 1024 * 1024  // 8 MiB

  /// Cached health result. `nil` means we haven't probed yet.
  private var cachedHealth: AIHealth?
  private var lastHealthCheck: Date?
  private let healthCacheTTL: TimeInterval = 30  // re-probe at most twice a minute

  private init() {}

  // MARK: - Public API

  /// Ask the model a question. Returns the raw text response.
  ///
  /// - Parameter prompt: The full prompt. Non-empty. Sent via stdin.
  /// - Parameter model: Optional model slug (e.g. "claude-sonnet-4-6").
  ///   When nil we fall back to `MINUTES_V2_MODEL` or the claude CLI default.
  func ask(prompt: String, model: String? = nil) async throws -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AIServiceError.emptyPrompt }

    let resolvedModel = model
      ?? ProcessInfo.processInfo.environment["MINUTES_V2_MODEL"]
      ?? "claude-sonnet-4-6"

    let outcome = try runClaude(
      args: [
        "-p",
        "--model", resolvedModel,
        "--output-format", "text",
        "--dangerously-skip-permissions",
      ],
      stdin: prompt
    )

    guard outcome.exitCode == 0 else {
      let stderrTail = String(outcome.stderr.suffix(800))
      // Authentication errors from claude CLI typically print
      // "not authenticated" / "please sign in" / "login" on stderr.
      let lower = stderrTail.lowercased()
      if lower.contains("not authenticated") || lower.contains("please sign in")
        || lower.contains("login") || lower.contains("authentication")
      {
        throw AIServiceError.claudeNotAuthenticated(detail: stderrTail)
      }
      if outcome.timedOut {
        throw AIServiceError.timeout(seconds: Self.timeoutSeconds)
      }
      throw AIServiceError.invocationFailed(detail: stderrTail, exitCode: outcome.exitCode)
    }

    let text = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      // Empty body + zero exit is almost always an auth prompt that got
      // silently swallowed. Surface that explicitly.
      throw AIServiceError.claudeNotAuthenticated(
        detail: "claude -p returned empty text (likely unauthenticated)")
    }
    return text
  }

  /// Ask the model and decode the response into `T`. The prompt is
  /// augmented with a "Respond with JSON only, no prose" suffix — callers
  /// are responsible for supplying a schema description inside their own
  /// prompt text. `JSONDecoder` errors surface as `.badJSON`.
  func askStructured<T: Decodable & Sendable>(
    prompt: String,
    as type: T.Type,
    model: String? = nil
  ) async throws -> T {
    let augmented =
      prompt
      + "\n\nRespond with a single valid JSON object. No markdown fences, "
      + "no prose before or after. Keys must match the schema the caller provided."
    let raw = try await ask(prompt: augmented, model: model)

    // Tolerate ```json fences in case the model still wraps them.
    let stripped = Self.stripCodeFence(raw)
    guard let data = stripped.data(using: .utf8) else {
      throw AIServiceError.badJSON(detail: "utf-8 encode failed", rawOutput: raw)
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw AIServiceError.badJSON(
        detail: "JSONDecoder failed: \(error.localizedDescription)", rawOutput: raw)
    }
  }

  /// Fast health probe. Runs `claude --version` with a 3s timeout. Caches
  /// the result for `healthCacheTTL` so `/state` hits this on every poll
  /// without spawning a subprocess each time.
  func health(forceRefresh: Bool = false) async -> AIHealth {
    if !forceRefresh, let cached = cachedHealth, let last = lastHealthCheck,
      Date().timeIntervalSince(last) < healthCacheTTL
    {
      return cached
    }

    let resolved = Self.resolveClaudeBinary()
    guard let claudePath = resolved else {
      let result = AIHealth(
        provider: "none",
        ready: false,
        claudePath: nil,
        claudeVersion: nil,
        error: "claude binary not found on PATH")
      cachedHealth = result
      lastHealthCheck = Date()
      return result
    }

    let outcome = runBinary(
      path: claudePath, args: ["--version"], stdin: nil, timeoutSec: 3, maxOutBytes: 64 * 1024)
    if outcome.exitCode == 0 {
      let version = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let result = AIHealth(
        provider: "claude-cli",
        ready: true,
        claudePath: claudePath,
        claudeVersion: version.isEmpty ? nil : version,
        error: nil)
      cachedHealth = result
      lastHealthCheck = Date()
      return result
    }

    let result = AIHealth(
      provider: "claude-cli",
      ready: false,
      claudePath: claudePath,
      claudeVersion: nil,
      error: "claude --version exited \(outcome.exitCode): \(outcome.stderr.prefix(200))")
    cachedHealth = result
    lastHealthCheck = Date()
    return result
  }

  /// Bust the cache. Call this from `/ai/ask` when the user explicitly
  /// retries so a transient auth issue can be re-probed.
  func invalidateHealth() {
    cachedHealth = nil
    lastHealthCheck = nil
  }

  // MARK: - Binary resolution

  /// Resolve the `claude` binary. Precedence:
  ///   1. `OMI_CLAUDE_BIN_OVERRIDE` — absolute path (highest priority, CI escape hatch)
  ///   2. `OMI_CLAUDE_PATH_OVERRIDE` — colon-separated PATH to search (test fixture hook)
  ///   3. Augmented PATH (Homebrew + nvm + ~/.claude/local) — production behavior
  nonisolated static func resolveClaudeBinary() -> String? {
    let env = ProcessInfo.processInfo.environment

    if let absolute = env["OMI_CLAUDE_BIN_OVERRIDE"], !absolute.isEmpty {
      if FileManager.default.isExecutableFile(atPath: absolute) { return absolute }
      // Override was set but invalid — deliberately fall through to nothing
      // so /ai/health reports not-installed. This is the missing-claude
      // simulation path used by bridge_ai.sh.
      return nil
    }

    let searchPath: String
    if let override = env["OMI_CLAUDE_PATH_OVERRIDE"], !override.isEmpty {
      searchPath = override
    } else {
      searchPath = augmentedPath()
    }

    for dir in searchPath.split(separator: ":") {
      let candidate = (String(dir) as NSString).appendingPathComponent("claude")
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  /// Augment PATH so a LaunchServices-launched app (which gets a minimal
  /// environment) can still find `claude`, node, npx, etc. This is the
  /// same pattern as `MinutesSubprocess.augmentedPath()` — kept separate
  /// instead of calling through it to avoid coupling AIService to the
  /// minutes pipeline.
  nonisolated static func augmentedPath() -> String {
    let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var paths: [String] = []
    let home = NSHomeDirectory()

    // ~/.claude/local is where `claude` installs itself when the user
    // runs `curl … | sh` from claude.ai/code.
    paths.append((home as NSString).appendingPathComponent(".claude/local"))

    // nvm node versions — most-recent first.
    let nvmBase = (home as NSString).appendingPathComponent(".nvm/versions/node")
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
      let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      for v in sorted {
        paths.append((nvmBase as NSString).appendingPathComponent("\(v)/bin"))
      }
    }

    // System/Homebrew locations. Covers Intel (/usr/local) and Apple Silicon
    // (/opt/homebrew) Homebrew layouts plus the default mac paths.
    paths.append("/opt/homebrew/bin")
    paths.append("/usr/local/bin")
    paths.append("/usr/bin")
    paths.append("/bin")
    if !existing.isEmpty { paths.append(existing) }
    return paths.joined(separator: ":")
  }

  // MARK: - Subprocess plumbing

  private struct Outcome {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
  }

  /// Run `claude` with the given args, feeding `stdin` as the prompt if
  /// provided. Throws `.claudeNotInstalled` up front if we can't find the
  /// binary.
  private func runClaude(args: [String], stdin: String?) throws -> Outcome {
    guard let claudePath = Self.resolveClaudeBinary() else {
      throw AIServiceError.claudeNotInstalled(
        detail:
          "claude binary not found on PATH (augmented: \(Self.augmentedPath())). Install Claude Code from https://claude.ai/code and sign in."
      )
    }
    return runBinary(
      path: claudePath,
      args: args,
      stdin: stdin,
      timeoutSec: Self.timeoutSeconds,
      maxOutBytes: Self.maxStdoutBytes
    )
  }

  /// Core subprocess runner. Mirrors `MinutesSubprocess.run` but:
  ///   * reads streaming stdout with a hard byte cap so a runaway model
  ///     response can't balloon memory;
  ///   * supports stdin for prompt piping;
  ///   * enforces `timeoutSec` with a SIGTERM then a 3s SIGKILL fallback.
  nonisolated private func runBinary(
    path: String,
    args: [String],
    stdin: String?,
    timeoutSec: Int,
    maxOutBytes: Int
  ) -> Outcome {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = Self.augmentedPath()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = stdinPipe

    do {
      try process.run()
    } catch {
      return Outcome(
        exitCode: -1,
        stdout: "",
        stderr: "spawn_failed: \(error.localizedDescription)",
        timedOut: false
      )
    }

    // Feed stdin. Close immediately after write so `claude -p` sees EOF
    // and finalises the prompt.
    if let stdin, !stdin.isEmpty {
      if let data = stdin.data(using: .utf8) {
        stdinPipe.fileHandleForWriting.write(data)
      }
    }
    try? stdinPipe.fileHandleForWriting.close()

    // Drain stdout in a background thread so we can enforce maxOutBytes
    // without blocking the timeout loop.
    var stdoutBuf = Data()
    var stderrBuf = Data()
    let stdoutLock = NSLock()
    let stderrLock = NSLock()

    let stdoutHandle = stdoutPipe.fileHandleForReading
    let stderrHandle = stderrPipe.fileHandleForReading

    let stdoutDrain = Thread {
      while true {
        let chunk = stdoutHandle.availableData
        if chunk.isEmpty { break }
        stdoutLock.lock()
        if stdoutBuf.count < maxOutBytes {
          let room = maxOutBytes - stdoutBuf.count
          stdoutBuf.append(chunk.prefix(room))
        }
        stdoutLock.unlock()
      }
    }
    let stderrDrain = Thread {
      while true {
        let chunk = stderrHandle.availableData
        if chunk.isEmpty { break }
        stderrLock.lock()
        if stderrBuf.count < 256 * 1024 {  // 256 KiB stderr cap
          stderrBuf.append(chunk)
        }
        stderrLock.unlock()
      }
    }
    stdoutDrain.start()
    stderrDrain.start()

    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
    var timedOut = false
    while process.isRunning {
      if Date() >= deadline {
        process.terminate()  // SIGTERM
        timedOut = true
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if timedOut {
      let hardDeadline = Date().addingTimeInterval(3)
      while process.isRunning, Date() < hardDeadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if process.isRunning {
        // Swift's Process doesn't expose SIGKILL directly; this is the
        // nuclear option and matches what minutes-agent does.
        kill(process.processIdentifier, SIGKILL)
        Thread.sleep(forTimeInterval: 0.2)
      }
    }

    // Give the drain threads a brief moment to finish reading the
    // tail of the pipes after the process exits.
    let drainDeadline = Date().addingTimeInterval(0.5)
    while (stdoutDrain.isExecuting || stderrDrain.isExecuting), Date() < drainDeadline {
      Thread.sleep(forTimeInterval: 0.02)
    }

    stdoutLock.lock()
    let stdoutCopy = stdoutBuf
    stdoutLock.unlock()
    stderrLock.lock()
    let stderrCopy = stderrBuf
    stderrLock.unlock()

    let stdout = String(data: stdoutCopy, encoding: .utf8) ?? ""
    let stderr = String(data: stderrCopy, encoding: .utf8) ?? ""
    return Outcome(
      exitCode: process.terminationStatus,
      stdout: stdout,
      stderr: stderr,
      timedOut: timedOut
    )
  }

  // MARK: - Helpers

  /// Strip a leading/trailing ```json fence from a model response so
  /// `JSONDecoder` has a shot at it. No-op if no fences are present.
  nonisolated static func stripCodeFence(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Leading ```json or ``` on its own line.
    let fencePrefixes = ["```json", "```JSON", "```"]
    for prefix in fencePrefixes {
      if s.hasPrefix(prefix) {
        s = String(s.dropFirst(prefix.count))
        // Drop the following newline if any.
        if s.hasPrefix("\n") { s = String(s.dropFirst()) }
        break
      }
    }
    if s.hasSuffix("```") {
      s = String(s.dropLast(3))
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
