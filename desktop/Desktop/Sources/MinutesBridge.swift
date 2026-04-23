import Foundation

// MARK: - MinutesBridge
//
// Phase 1 of the minutes×omi merge. This file bolts a `/minutes/*` surface onto
// the existing `DesktopAutomationBridge` so external tooling (curl, scheduled
// cowork jobs, the old minutes-agent TS watchers during the transition) can
// drive the meeting lifecycle without shelling out or file-watching from the
// consumer side.
//
// Mechanism: we wrap the existing minutes-agent TypeScript pipeline.
//   POST /minutes/start   → `scripts/record-now.ts  --title "…"`
//   POST /minutes/stop    → `scripts/stop-now.ts    --event-id <id>`
//   GET  /minutes/transcript → read `<folder>/transcript.md` from disk
//   POST /minutes/enrich  → `scripts/v2/post-meeting-enrich.ts --meeting <path>`
//
// Why wrap the TS scripts instead of calling the Minutes MCP directly, or
// inventing a new Swift capture path?
//   * The TS scripts are the only path that is *solid today* — they already
//     handle Minutes MCP handshake, capture-controller + transcript-watcher
//     child processes, `state.json` bookkeeping, and the exact folder layout
//     `PostMeetingService` expects downstream.
//   * Re-implementing in Swift now would duplicate work that Phase 3 of
//     OMI_CONSOLIDATION.md is going to rewrite anyway. Phase 1 is about
//     exposing an API surface, not porting capture.
//   * Calling the Minutes MCP directly from Swift would require a second MCP
//     client in the app and would miss the state-file and sidecar behavior
//     minutes-agent adds on top.
//
// This file is deliberately self-contained — no changes to AppState, no new
// dependencies. The only touch outside this file is four case statements added
// to `DesktopAutomationBridge.route(_:)`.

// MARK: Request / Response shapes

struct MinutesStartRequest: Codable {
  let meetingId: String?
  let title: String?
  let source: String?  // "calendar" | "manual" (free-form; forwarded as-is)
}

struct MinutesStartResult: Codable {
  let ok: Bool
  let meetingId: String
  let startedAt: String
  let outputPath: String  // meeting folder where transcript.md + sidecars will land
  let title: String?
}

struct MinutesStopRequest: Codable {
  let meetingId: String
}

struct MinutesStopResult: Codable {
  let ok: Bool
  let meetingId: String
  let stoppedAt: String
  let durationSec: Int
  let transcriptPath: String?  // path where the transcript will be written; may not exist yet
  let audioPath: String?  // not separately written by minutes-agent; kept nullable per contract
}

struct MinutesTranscriptResult: Codable {
  let text: String
  let isFinal: Bool
  let meetingId: String
  let transcriptPath: String
}

struct MinutesEnrichRequest: Codable {
  let meetingId: String
  let transcriptPath: String?
}

struct MinutesEnrichResult: Codable {
  let ok: Bool
  let jobId: String
  let meetingId: String
  let transcriptPath: String
}

// MARK: - Session cache

/// In-memory cache of active/recently-active minutes sessions.
/// Keyed by the `meetingId` returned from record-now (always the `manual-<iso>`
/// correlation handle; see minutes-agent/scripts/record-now.ts).
actor MinutesBridgeService {
  static let shared = MinutesBridgeService()

  struct Session {
    let meetingId: String
    let folder: String
    let title: String?
    let source: String
    let startedAt: Date
    var stoppedAt: Date?
  }

  private var sessions: [String: Session] = [:]
  private var enrichJobs: [String: UUID] = [:]  // meetingId → jobId

  func register(_ session: Session) {
    sessions[session.meetingId] = session
  }

  func markStopped(_ meetingId: String, at date: Date) -> Session? {
    guard var s = sessions[meetingId] else { return nil }
    s.stoppedAt = date
    sessions[meetingId] = s
    return s
  }

  func session(_ meetingId: String) -> Session? {
    sessions[meetingId]
  }

  func recordEnrichJob(_ jobId: UUID, for meetingId: String) {
    enrichJobs[meetingId] = jobId
  }
}

// MARK: - Top-level router called from DesktopAutomationBridge

enum MinutesBridgeRouter {
  /// Returns a JSON body + HTTP status for the given minutes route, or nil if
  /// the (method, path) pair is not a minutes route.
  static func handle(method: String, path: String, body: Data) async -> (Data, Int)? {
    // Strip the query string once so path matching is simple.
    let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

    guard DesktopAutomationLaunchOptions.isEnabled else {
      if pathOnly.hasPrefix("/minutes/") {
        return (MinutesBridgeRouter.errorBody(
          "bridge_disabled", "OMI_ENABLE_LOCAL_AUTOMATION is not set"), 503)
      }
      return nil
    }

    switch (method, pathOnly) {
    case ("POST", "/minutes/start"):
      return await MinutesBridgeHandlers.start(body: body)
    case ("POST", "/minutes/stop"):
      return await MinutesBridgeHandlers.stop(body: body)
    case ("GET", "/minutes/transcript"):
      return await MinutesBridgeHandlers.transcript(rawPath: path)
    case ("POST", "/minutes/enrich"):
      return await MinutesBridgeHandlers.enrich(body: body)
    default:
      return nil
    }
  }

  static func errorBody(_ code: String, _ message: String) -> Data {
    let payload: [String: Any] = ["ok": false, "error": code, "message": message]
    return (try? JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data("{\"ok\":false}".utf8)
  }

  static func successBody<T: Codable>(_ value: T) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? enc.encode(value)) ?? Data("{\"ok\":true}".utf8)
  }
}

// MARK: - Handlers
//
// Phase 3 change: each handler dispatches on `MinutesLifecycleEnv.lifecycleMode()`
// to pick either the native Swift actor (`MinutesLifecycleService.shared`, the
// default) or the Phase 1 TS shell-out path (retained for instant rollback
// behind `OMI_MINUTES_LIFECYCLE=ts`). The HTTP response shape is identical in
// both modes — see `BRIDGE_API.md § Phase 3 note`.

enum MinutesBridgeHandlers {
  static func start(body: Data) async -> (Data, Int) {
    let req: MinutesStartRequest
    if body.isEmpty {
      req = MinutesStartRequest(meetingId: nil, title: nil, source: nil)
    } else {
      do {
        req = try JSONDecoder().decode(MinutesStartRequest.self, from: body)
      } catch {
        return (MinutesBridgeRouter.errorBody("bad_request", "invalid JSON body: \(error)"), 400)
      }
    }

    let title = req.title ?? "Manual capture \(Self.hhmm(Date()))"
    let source = req.source ?? "manual"

    switch MinutesLifecycleEnv.lifecycleMode() {
    case .swift:
      return await startSwift(title: title, source: source)
    case .ts:
      return await startTS(title: title, source: source)
    }
  }

  /// Phase 3 default path — native Swift MCP client + state persistence.
  private static func startSwift(title: String, source: String) async -> (Data, Int) {
    do {
      let outcome = try await MinutesLifecycleService.shared.start(
        title: title, source: source)
      // Also register a bridge-side session so the existing TS-era consumers
      // that call `MinutesBridgeService.shared.session(...)` keep working.
      // Dual-writing is cheap and avoids a migration.
      let session = MinutesBridgeService.Session(
        meetingId: outcome.meetingId,
        folder: outcome.folder,
        title: outcome.title,
        source: source,
        startedAt: outcome.startedAt,
        stoppedAt: nil
      )
      await MinutesBridgeService.shared.register(session)
      log("MinutesBridge(swift): /minutes/start → meetingId=\(outcome.meetingId) folder=\(outcome.folder)")
      let payload = MinutesStartResult(
        ok: true,
        meetingId: outcome.meetingId,
        startedAt: Self.iso(outcome.startedAt),
        outputPath: outcome.folder,
        title: outcome.title
      )
      return (MinutesBridgeRouter.successBody(payload), 200)
    } catch let err as MinutesLifecycleError {
      log("MinutesBridge(swift): /minutes/start failed: \(err)")
      return (MinutesBridgeRouter.errorBody("capture_failed", String(describing: err)), 500)
    } catch {
      log("MinutesBridge(swift): /minutes/start unexpected error: \(error)")
      return (MinutesBridgeRouter.errorBody("capture_failed", String(describing: error)), 500)
    }
  }

  /// Phase 1 legacy path — shells out to `scripts/record-now.ts`. Retained as
  /// the `OMI_MINUTES_LIFECYCLE=ts` fallback until Phase 4 deletes the TS.
  private static func startTS(title: String, source: String) async -> (Data, Int) {
    let result = await MinutesSubprocess.run(
      script: "scripts/record-now.ts",
      args: ["--title", title],
      captureStdout: true,
      detach: false,
      timeoutSec: 30
    )

    guard result.exitCode == 0 else {
      log("MinutesBridge(ts): /minutes/start record-now.ts exited \(result.exitCode): \(result.stderr.prefix(500))")
      return (MinutesBridgeRouter.errorBody(
        "capture_failed",
        "record-now.ts exited \(result.exitCode). stderr: \(String(result.stderr.prefix(500)))"), 500)
    }

    guard let (meetingId, folder) = Self.parseRecordNowOutput(result.stdout) else {
      log("MinutesBridge(ts): /minutes/start could not parse record-now.ts stdout: \(result.stdout.prefix(500))")
      return (MinutesBridgeRouter.errorBody(
        "capture_parse_failed", "record-now.ts stdout did not contain a meetingId JSON line"), 500)
    }

    let now = Date()
    let session = MinutesBridgeService.Session(
      meetingId: meetingId,
      folder: folder,
      title: title,
      source: source,
      startedAt: now,
      stoppedAt: nil
    )
    await MinutesBridgeService.shared.register(session)
    log("MinutesBridge(ts): /minutes/start → meetingId=\(meetingId) folder=\(folder)")

    let payload = MinutesStartResult(
      ok: true,
      meetingId: meetingId,
      startedAt: Self.iso(now),
      outputPath: folder,
      title: title
    )
    return (MinutesBridgeRouter.successBody(payload), 200)
  }

  static func stop(body: Data) async -> (Data, Int) {
    let req: MinutesStopRequest
    do {
      req = try JSONDecoder().decode(MinutesStopRequest.self, from: body)
    } catch {
      return (MinutesBridgeRouter.errorBody("bad_request", "invalid JSON body: \(error)"), 400)
    }

    switch MinutesLifecycleEnv.lifecycleMode() {
    case .swift:
      return await stopSwift(meetingId: req.meetingId)
    case .ts:
      return await stopTS(meetingId: req.meetingId)
    }
  }

  private static func stopSwift(meetingId: String) async -> (Data, Int) {
    do {
      let outcome = try await MinutesLifecycleService.shared.stop(meetingId: meetingId)
      _ = await MinutesBridgeService.shared.markStopped(meetingId, at: outcome.stoppedAt)
      log("MinutesBridge(swift): /minutes/stop meetingId=\(meetingId) durationSec=\(outcome.durationSec)")
      let payload = MinutesStopResult(
        ok: true,
        meetingId: meetingId,
        stoppedAt: Self.iso(outcome.stoppedAt),
        durationSec: outcome.durationSec,
        transcriptPath: outcome.transcriptPath,
        audioPath: outcome.audioPath
      )
      return (MinutesBridgeRouter.successBody(payload), 200)
    } catch MinutesLifecycleError.unknownMeeting(let id) {
      return (MinutesBridgeRouter.errorBody(
        "unknown_meeting", "no active session for meetingId=\(id)"), 404)
    } catch let err as MinutesLifecycleError {
      log("MinutesBridge(swift): /minutes/stop failed: \(err)")
      return (MinutesBridgeRouter.errorBody("stop_failed", String(describing: err)), 500)
    } catch {
      log("MinutesBridge(swift): /minutes/stop unexpected error: \(error)")
      return (MinutesBridgeRouter.errorBody("stop_failed", String(describing: error)), 500)
    }
  }

  private static func stopTS(meetingId: String) async -> (Data, Int) {
    guard let session = await MinutesBridgeService.shared.session(meetingId) else {
      return (MinutesBridgeRouter.errorBody(
        "unknown_meeting", "no active session for meetingId=\(meetingId)"), 404)
    }

    let result = await MinutesSubprocess.run(
      script: "scripts/stop-now.ts",
      args: ["--event-id", meetingId],
      captureStdout: true,
      detach: false,
      timeoutSec: 60
    )

    guard result.exitCode == 0 else {
      log("MinutesBridge(ts): /minutes/stop stop-now.ts exited \(result.exitCode): \(result.stderr.prefix(500))")
      return (MinutesBridgeRouter.errorBody(
        "stop_failed",
        "stop-now.ts exited \(result.exitCode). stderr: \(String(result.stderr.prefix(500)))"), 500)
    }

    let now = Date()
    _ = await MinutesBridgeService.shared.markStopped(meetingId, at: now)
    let durationSec = Int(now.timeIntervalSince(session.startedAt))
    let transcriptPath = (session.folder as NSString).appendingPathComponent("transcript.md")
    log("MinutesBridge(ts): /minutes/stop meetingId=\(meetingId) durationSec=\(durationSec)")

    let payload = MinutesStopResult(
      ok: true,
      meetingId: meetingId,
      stoppedAt: Self.iso(now),
      durationSec: durationSec,
      transcriptPath: transcriptPath,
      audioPath: nil
    )
    return (MinutesBridgeRouter.successBody(payload), 200)
  }

  static func transcript(rawPath: String) async -> (Data, Int) {
    guard let query = rawPath.split(separator: "?", maxSplits: 1).dropFirst().first,
          let meetingId = Self.queryParam(String(query), key: "meetingId"),
          !meetingId.isEmpty
    else {
      return (MinutesBridgeRouter.errorBody(
        "bad_request", "missing ?meetingId=… query parameter"), 400)
    }

    // Try the Swift lifecycle first so we resolve sessions started under
    // `OMI_MINUTES_LIFECYCLE=swift`; fall through to the TS-era bridge cache
    // so sessions started under `=ts` still resolve.
    var folder: String? = nil
    var isFinalFromActor: Bool? = nil
    if MinutesLifecycleEnv.lifecycleMode() == .swift {
      if let rec = await MinutesLifecycleService.shared.recording(meetingId) {
        folder = rec.meetingFolder
        isFinalFromActor = await MinutesLifecycleService.shared.transcriptIsFinal(meetingId)
      }
    }
    var session: MinutesBridgeService.Session? = nil
    if folder == nil {
      session = await MinutesBridgeService.shared.session(meetingId)
      folder = session?.folder
    }

    guard let folder else {
      return (MinutesBridgeRouter.errorBody(
        "unknown_meeting", "no session for meetingId=\(meetingId)"), 404)
    }

    let transcriptPath = (folder as NSString).appendingPathComponent("transcript.md")
    let exists = FileManager.default.fileExists(atPath: transcriptPath)
    let text: String
    if exists {
      text = (try? String(contentsOfFile: transcriptPath, encoding: .utf8)) ?? ""
    } else {
      text = ""
    }
    // `isFinal` semantics: transcript.md exists AND the session has been
    // stopped. Swift actor tracks its own finalisation state; TS sessions
    // fall back to the bridge cache's stoppedAt.
    let isFinal: Bool
    if let actor = isFinalFromActor {
      isFinal = actor && exists
    } else {
      isFinal = exists && session?.stoppedAt != nil
    }

    let payload = MinutesTranscriptResult(
      text: text,
      isFinal: isFinal,
      meetingId: meetingId,
      transcriptPath: transcriptPath
    )
    return (MinutesBridgeRouter.successBody(payload), 200)
  }

  static func enrich(body: Data) async -> (Data, Int) {
    let req: MinutesEnrichRequest
    do {
      req = try JSONDecoder().decode(MinutesEnrichRequest.self, from: body)
    } catch {
      return (MinutesBridgeRouter.errorBody("bad_request", "invalid JSON body: \(error)"), 400)
    }

    // Resolve transcript path: explicit override wins; else try Swift
    // lifecycle folder; else fall back to the TS-era bridge cache.
    var transcriptPath: String? = nil
    if let explicit = req.transcriptPath, !explicit.isEmpty {
      transcriptPath = explicit
    } else if MinutesLifecycleEnv.lifecycleMode() == .swift,
              let rec = await MinutesLifecycleService.shared.recording(req.meetingId)
    {
      transcriptPath = (rec.meetingFolder as NSString).appendingPathComponent("transcript.md")
    } else if let session = await MinutesBridgeService.shared.session(req.meetingId) {
      transcriptPath = (session.folder as NSString).appendingPathComponent("transcript.md")
    }

    guard let transcriptPath else {
      return (MinutesBridgeRouter.errorBody(
        "unknown_meeting",
        "no session for meetingId=\(req.meetingId) and no transcriptPath override"), 404)
    }

    guard FileManager.default.fileExists(atPath: transcriptPath) else {
      return (MinutesBridgeRouter.errorBody(
        "transcript_missing",
        "transcript does not exist at \(transcriptPath) (meeting may not be stopped yet)"), 409)
    }

    // The enricher stays in TS in both modes — Phase 3 doesn't port it.
    // Under `swift` we delegate to `MinutesLifecycleService.enrich(...)` so
    // the jobId is tracked alongside other lifecycle state; under `ts` we
    // preserve the Phase 1 behaviour exactly.
    let jobId: UUID
    switch MinutesLifecycleEnv.lifecycleMode() {
    case .swift:
      jobId = await MinutesLifecycleService.shared.enrich(
        transcriptPath: transcriptPath, meetingId: req.meetingId)
    case .ts:
      jobId = UUID()
      await MinutesBridgeService.shared.recordEnrichJob(jobId, for: req.meetingId)
      Task.detached(priority: .utility) {
        let outcome = await MinutesSubprocess.run(
          script: "scripts/v2/post-meeting-enrich.ts",
          args: ["--meeting", transcriptPath, "--no-notify"],
          captureStdout: false,
          detach: false,
          timeoutSec: 600
        )
        log("MinutesBridge(ts): enrich job \(jobId) exited \(outcome.exitCode) for meetingId=\(req.meetingId)")
      }
    }

    let payload = MinutesEnrichResult(
      ok: true,
      jobId: jobId.uuidString,
      meetingId: req.meetingId,
      transcriptPath: transcriptPath
    )
    return (MinutesBridgeRouter.successBody(payload), 202)
  }

  // MARK: - Parsing helpers

  static func parseRecordNowOutput(_ stdout: String) -> (meetingId: String, folder: String)? {
    // Walk stdout line-by-line looking for a JSON object with meetingId.
    for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      let trimmed = String(line).trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { continue }
      guard let data = trimmed.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let meetingId = obj["meetingId"] as? String,
            let folder = obj["folder"] as? String
      else { continue }
      return (meetingId, folder)
    }
    return nil
  }

  static func queryParam(_ query: String, key: String) -> String? {
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, parts[0] == Substring(key) else { continue }
      return String(parts[1]).removingPercentEncoding ?? String(parts[1])
    }
    return nil
  }

  private static func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }

  private static func hhmm(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: date)
  }
}

// MARK: - Subprocess runner for minutes-agent TS scripts

enum MinutesSubprocess {
  struct Outcome {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
  }

  /// Resolve the minutes-agent checkout root. Overridable via `OMI_MINUTES_AGENT_DIR`
  /// for parallel checkouts / CI; defaults to the sibling-of-omi layout on Rohit's
  /// machine.
  static func minutesAgentRoot() -> String {
    if let override = ProcessInfo.processInfo.environment["OMI_MINUTES_AGENT_DIR"],
       !override.isEmpty
    {
      return (override as NSString).expandingTildeInPath
    }
    let home = NSHomeDirectory()
    return (home as NSString).appendingPathComponent(
      "Developer/entropy-negative/minutes-agent")
  }

  /// Augment PATH so Homebrew and nvm-installed node/npx are resolvable even
  /// when the app was launched via LaunchServices (which strips shell PATH).
  static func augmentedPath() -> String {
    let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var paths: [String] = []
    // Prepend the most-likely locations for `node`/`npx`/`tsx` first.
    let home = NSHomeDirectory()
    let nvmBase = (home as NSString).appendingPathComponent(".nvm/versions/node")
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
      let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      for v in sorted {
        paths.append((nvmBase as NSString).appendingPathComponent("\(v)/bin"))
      }
    }
    paths.append("/opt/homebrew/bin")
    paths.append("/usr/local/bin")
    paths.append("/usr/bin")
    paths.append("/bin")
    if !existing.isEmpty {
      paths.append(existing)
    }
    return paths.joined(separator: ":")
  }

  /// Run `npx tsx <script> <args...>` inside the minutes-agent checkout and
  /// return the outcome. `timeoutSec` kills the process group on timeout.
  static func run(
    script: String,
    args: [String],
    captureStdout: Bool,
    detach: Bool,
    timeoutSec: TimeInterval
  ) async -> Outcome {
    let root = minutesAgentRoot()
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = augmentedPath()

    let process = Process()
    process.currentDirectoryURL = URL(fileURLWithPath: root)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx", "tsx", script] + args
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

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

    if detach {
      // Fire-and-forget path (not used in Phase 1, but kept for future hooks).
      return Outcome(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }

    // Poll exit + enforce timeout. We intentionally avoid Process.waitUntilExit
    // blocking the caller's thread — this is async.
    let deadline = Date().addingTimeInterval(timeoutSec)
    var timedOut = false
    while process.isRunning {
      if Date() >= deadline {
        process.terminate()
        timedOut = true
        break
      }
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    }
    // If terminate() was called but the process is still around, give it a beat.
    if timedOut {
      let hardDeadline = Date().addingTimeInterval(3)
      while process.isRunning, Date() < hardDeadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = captureStdout ? (String(data: stdoutData, encoding: .utf8) ?? "") : ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    return Outcome(
      exitCode: process.terminationStatus,
      stdout: stdout,
      stderr: stderr,
      timedOut: timedOut
    )
  }
}
