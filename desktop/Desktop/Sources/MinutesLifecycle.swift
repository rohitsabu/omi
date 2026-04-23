import Foundation

// MARK: - MinutesLifecycle
//
// Phase 3 of the minutes×omi merge. Ports the record/stop lifecycle
// (previously implemented as `scripts/record-now.ts` + `scripts/stop-now.ts`
// in `minutes-agent`) into a native Swift actor that lives inside the Omi
// app.
//
// Scope:
//   * Spawn `npx minutes-mcp` as a long-lived subprocess and speak the MCP
//     JSON-RPC 2.0 protocol over newline-delimited JSON on stdio. That's
//     the same protocol the TS `@modelcontextprotocol/sdk` StdioClientTransport
//     speaks — we hand-roll a minimal client here because Omi doesn't already
//     ship a reusable MCP abstraction (ACPBridge speaks a custom line protocol,
//     not MCP JSON-RPC).
//   * Own an in-memory registry of active/recently-active recordings keyed by
//     the caller-owned `manual-<iso>` correlation handle (see
//     `MINUTES_MCP_PROTOCOL.md` — Minutes doesn't return a durable id, so the
//     caller mints one).
//   * Mirror the TS folder conventions so everything downstream (the TS
//     enricher, any folder-organiser consumers, audit tooling) keeps working
//     without knowing which implementation produced the folder.
//   * Persist state to `~/Library/Application Support/minutes-agent/state.json`
//     using the *same* schema as `scripts/lib/state.ts`. Decision: we did
//     not migrate to an Omi-owned store because (a) the TS fallback path must
//     keep working under `OMI_MINUTES_LIFECYCLE=ts`, and (b) two stores in
//     Phase 3 would mean reconciling them. Phase 4, when the TS goes away,
//     can move this to an Omi-owned location or onto GRDB.
//   * Provide a fire-and-forget invocation path for the TS enricher
//     (`scripts/v2/post-meeting-enrich.ts`). The enricher stays in TS for now
//     — Phase 3 explicitly doesn't port it.
//
// Out of scope:
//   * Snapshot / full-video promotion (driven by transcript keywords in
//     `scripts/transcript-watcher.ts`). Not needed for the `/minutes/*` bridge
//     surface; if we want this inside Omi later, it lands as a separate
//     service.
//   * Post-meeting enrichment logic. The Swift side just spawns the TS script.
//
// HTTP contract: unchanged from Phase 1. Every byte of every response from
// `/minutes/start|stop|transcript|enrich` matches what `MinutesBridge.swift`
// already returned via the TS shell-out path.

// MARK: - JSON-RPC framing types

/// MCP's stdio transport is newline-delimited JSON per the 2024-11-05 /
/// 2025-03-26 MCP spec. Each message is a complete JSON-RPC 2.0 object on one
/// line terminated by `\n`. No Content-Length framing, no chunking. Messages
/// that span multiple lines would be a protocol violation.
private struct JSONRPCEnvelope: Encodable {
  let jsonrpc: String
  let id: Int?
  let method: String?
  let params: JSONRPCParams?
}

private enum JSONRPCParams: Encodable {
  case dict([String: JSONValue])
  case none

  func encode(to encoder: Encoder) throws {
    switch self {
    case .dict(let d):
      try d.encode(to: encoder)
    case .none:
      var c = encoder.singleValueContainer()
      try c.encodeNil()
    }
  }
}

/// Loose-typed JSON value for params/args — the MCP argument shapes are
/// per-tool and we don't want to type each tool call's input schema here.
indirect enum JSONValue: Encodable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null
  case dict([String: JSONValue])
  case array([JSONValue])

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .int(let i): try c.encode(i)
    case .double(let d): try c.encode(d)
    case .bool(let b): try c.encode(b)
    case .null: try c.encodeNil()
    case .dict(let d): try c.encode(d)
    case .array(let a): try c.encode(a)
    }
  }

  static func from(_ any: Any?) -> JSONValue {
    guard let any = any else { return .null }
    if let s = any as? String { return .string(s) }
    if let b = any as? Bool { return .bool(b) }
    if let i = any as? Int { return .int(i) }
    if let d = any as? Double { return .double(d) }
    if let dict = any as? [String: Any] {
      var out: [String: JSONValue] = [:]
      for (k, v) in dict { out[k] = JSONValue.from(v) }
      return .dict(out)
    }
    if let arr = any as? [Any] {
      return .array(arr.map { JSONValue.from($0) })
    }
    return .null
  }
}

// MARK: - MCP stdio client

/// Minimal MCP JSON-RPC 2.0 client over subprocess stdio.
///
/// Threading model: all stdin writes go through the actor. A dedicated
/// `DispatchQueue` reads stdout and hands parsed envelopes back to the actor
/// via `Task { await ... }`. Request/response correlation is by id; pending
/// continuations sit in `pending[id]`.
///
/// Lifetime: one `MinutesMCPClient` per `MinutesLifecycleService`. We launch
/// lazily on first use and keep the process alive for the lifetime of the
/// Omi app — spawning `npx minutes-mcp` takes multiple seconds on cold start,
/// and a long-lived process matches how the TS side works (one MCP per agent
/// invocation, reused for the duration).
actor MinutesMCPClient {
  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var nextId: Int = 1
  private var pending: [Int: CheckedContinuation<String, Error>] = [:]
  private var readBuffer = Data()
  private var running = false

  /// Launch the MCP subprocess if it isn't already running. Sends the MCP
  /// `initialize` handshake + `notifications/initialized` before returning.
  /// Safe to call repeatedly — the second call is a no-op. If a prior launch
  /// failed, a subsequent call retries from scratch.
  func ensureStarted() async throws {
    if running { return }

    let env = MinutesLifecycleEnv.augmented()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["npx", "minutes-mcp"]
    proc.environment = env

    let sin = Pipe()
    let sout = Pipe()
    let serr = Pipe()
    proc.standardInput = sin
    proc.standardOutput = sout
    proc.standardError = serr

    do {
      try proc.run()
    } catch {
      throw error
    }
    process = proc
    stdinPipe = sin
    stdoutPipe = sout
    stderrPipe = serr
    running = true

    // Stdout reader loop. Parks on a background queue and forwards every
    // complete line to `handleLine` on the actor. We use a pipe readability
    // handler rather than a blocking Task to avoid holding an actor context
    // while waiting on FD data.
    sout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        // EOF — the subprocess exited. Fail all pending calls.
        Task { [weak self] in await self?.handleEOF() }
        return
      }
      Task { [weak self] in await self?.append(data: data) }
    }

    // Drain stderr so the kernel buffer doesn't fill up (which would block
    // minutes-mcp). We log it under `minutes-mcp-stderr` for post-mortems.
    serr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
      for line in s.split(separator: "\n") {
        log("MinutesLifecycle: mcp-stderr: \(line)")
      }
    }

    // MCP handshake. Without this, `tools/call` returns a server error because
    // the server treats the session as un-initialised.
    //
    //   → initialize
    //   ← { result: { capabilities, serverInfo, ... } }
    //   → notifications/initialized
    do {
      _ = try await request(
        method: "initialize",
        params: .dict([
          "protocolVersion": .string("2024-11-05"),
          "capabilities": .dict([:]),
          "clientInfo": .dict([
            "name": .string("omi-minutes-bridge"),
            "version": .string("0.1.0"),
          ]),
        ]),
        timeoutSec: 20
      )
    } catch {
      running = false
      throw error
    }
    try sendNotification(
      method: "notifications/initialized",
      params: .dict([:])
    )
    log("MinutesLifecycle: MCP client initialized")
  }

  /// Call an MCP tool. Returns the concatenated text of every `text` part in
  /// the response content array — matches the TS `callTool` helper's
  /// flattening behaviour so the parsers we inherit from `record-now.ts` /
  /// `stop-now.ts` continue to work unchanged.
  func callTool(name: String, arguments: [String: JSONValue], timeoutSec: TimeInterval = 60) async throws -> String {
    try await ensureStarted()
    let raw = try await request(
      method: "tools/call",
      params: .dict([
        "name": .string(name),
        "arguments": .dict(arguments),
      ]),
      timeoutSec: timeoutSec
    )
    return flattenContentText(raw)
  }

  /// Cleanly shut down the subprocess. Intended for `applicationWillTerminate`.
  /// Sends SIGTERM first, waits up to 2s, then SIGKILL. Clears pending
  /// continuations.
  func shutdown() async {
    guard let proc = process, running else { return }
    running = false

    // Close stdin so the MCP server sees EOF and exits cleanly on its own.
    stdinPipe?.fileHandleForWriting.closeFile()

    // Give it a beat to exit on its own.
    let deadline = Date().addingTimeInterval(2.0)
    while proc.isRunning, Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if proc.isRunning {
      proc.terminate()
      let hardDeadline = Date().addingTimeInterval(1.5)
      while proc.isRunning, Date() < hardDeadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    // Last resort.
    if proc.isRunning {
      kill(proc.processIdentifier, SIGKILL)
    }

    // Fail any outstanding requests so callers don't hang forever.
    let outstanding = pending
    pending.removeAll()
    for (_, cont) in outstanding {
      cont.resume(throwing: MinutesMCPError.shutdown)
    }

    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    process = nil
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
    log("MinutesLifecycle: MCP client shut down")
  }

  // MARK: - Internal

  private func request(
    method: String,
    params: JSONRPCParams,
    timeoutSec: TimeInterval
  ) async throws -> Any {
    let id = nextId
    nextId += 1

    let envelope = JSONRPCEnvelope(jsonrpc: "2.0", id: id, method: method, params: params)
    let enc = JSONEncoder()
    let data = try enc.encode(envelope)
    var line = data
    line.append(0x0A)  // '\n'

    try write(line)

    // Race the response against the timeout. `withThrowingTaskGroup` would be
    // heavier here than needed; we just detach a sleep task that cancels the
    // pending continuation.
    let timeoutTask = Task {
      try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
      if !Task.isCancelled {
        await self.failPending(id: id, error: MinutesMCPError.timeout(method: method, seconds: timeoutSec))
      }
    }

    let text: String = try await withCheckedThrowingContinuation { cont in
      pending[id] = cont
    }
    timeoutTask.cancel()

    // `text` is the stringified `result` JSON. Parse it so the caller can
    // read structured fields like `content`.
    guard let asData = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: asData)
    else {
      throw MinutesMCPError.badResponse("result did not decode as JSON")
    }
    return obj
  }

  private func sendNotification(method: String, params: JSONRPCParams) throws {
    let envelope = JSONRPCEnvelope(jsonrpc: "2.0", id: nil, method: method, params: params)
    let data = try JSONEncoder().encode(envelope)
    var line = data
    line.append(0x0A)
    try write(line)
  }

  private func write(_ line: Data) throws {
    guard let stdin = stdinPipe?.fileHandleForWriting else {
      throw MinutesMCPError.notRunning
    }
    // `write(contentsOf:)` is available on FileHandle on macOS 10.15.4+ and
    // throws on pipe closure, which is what we want.
    try stdin.write(contentsOf: line)
  }

  private func append(data: Data) {
    readBuffer.append(data)
    // Split on newlines; keep the trailing partial line in the buffer.
    var start = readBuffer.startIndex
    while let nlIdx = readBuffer[start...].firstIndex(of: 0x0A) {
      let lineData = readBuffer[start..<nlIdx]
      start = readBuffer.index(after: nlIdx)
      if !lineData.isEmpty {
        handleLine(Data(lineData))
      }
    }
    if start > readBuffer.startIndex {
      readBuffer.removeSubrange(readBuffer.startIndex..<start)
    }
  }

  private func handleLine(_ line: Data) {
    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      log("MinutesLifecycle: mcp stdout garbled: \(String(data: line, encoding: .utf8) ?? "<binary>")")
      return
    }
    // Notifications don't carry an id — ignore.
    guard let id = obj["id"] as? Int else { return }
    guard let cont = pending.removeValue(forKey: id) else { return }

    if let errorObj = obj["error"] as? [String: Any] {
      let code = (errorObj["code"] as? Int) ?? 0
      let message = (errorObj["message"] as? String) ?? "unknown error"
      cont.resume(throwing: MinutesMCPError.rpcError(code: code, message: message))
      return
    }
    // Re-serialise `result` so the caller gets a string view it can decode.
    let result = obj["result"] ?? [:]
    guard let data = try? JSONSerialization.data(withJSONObject: result),
          let text = String(data: data, encoding: .utf8)
    else {
      cont.resume(throwing: MinutesMCPError.badResponse("result not re-encodable"))
      return
    }
    cont.resume(returning: text)
  }

  private func failPending(id: Int, error: Error) {
    guard let cont = pending.removeValue(forKey: id) else { return }
    cont.resume(throwing: error)
  }

  private func handleEOF() {
    running = false
    let outstanding = pending
    pending.removeAll()
    for (_, cont) in outstanding {
      cont.resume(throwing: MinutesMCPError.eof)
    }
  }

  /// Flatten the `content: [{type, text}]` array the MCP tools return into
  /// one string. Mirrors the behaviour of `scripts/lib/mcp.ts::callTool`.
  private func flattenContentText(_ raw: Any) -> String {
    guard let dict = raw as? [String: Any],
          let content = dict["content"] as? [[String: Any]]
    else {
      // Some tools might return a bare string — pass through.
      if let s = raw as? String { return s }
      if let data = try? JSONSerialization.data(withJSONObject: raw),
         let s = String(data: data, encoding: .utf8) { return s }
      return ""
    }
    return content
      .compactMap { item -> String? in
        guard (item["type"] as? String) == "text" else { return nil }
        return item["text"] as? String
      }
      .joined(separator: "\n")
  }
}

enum MinutesMCPError: Error, CustomStringConvertible {
  case notRunning
  case eof
  case shutdown
  case timeout(method: String, seconds: TimeInterval)
  case rpcError(code: Int, message: String)
  case badResponse(String)
  case failedStart(String)

  var description: String {
    switch self {
    case .notRunning: return "MCP client not running"
    case .eof: return "MCP subprocess exited"
    case .shutdown: return "MCP client shutting down"
    case .timeout(let m, let s): return "MCP call timed out (\(m) after \(Int(s))s)"
    case .rpcError(let c, let m): return "MCP rpc error \(c): \(m)"
    case .badResponse(let m): return "MCP bad response: \(m)"
    case .failedStart(let m): return "MCP failed to start: \(m)"
    }
  }
}

// MARK: - Persistent state (mirrors scripts/lib/state.ts schema)

/// The single recording entry in `state.json`. Field names match the TS
/// `ActiveRecording` interface byte-for-byte so the TS fallback and the Swift
/// implementation can both read/write the same file.
struct MinutesStateRecording: Codable {
  var eventId: String
  var calendarId: String
  var meetingId: String
  var meetingFolder: String
  var meetingPath: String?
  var jobId: String?
  var recordingPid: Int?
  var startedAt: String
  var endsAt: String
  var captureMode: String  // "snapshot" | "full_video"
  var capturePid: Int?
  var transcriptPid: Int?
  var briefed: Bool
  var confirmedByUser: Bool
  var source: String?
  var meetingTitle: String?
  /// Phase 3 addition. Values: "active" | "finalizing" | "completed". The TS
  /// side doesn't read this field — it's additive, for Swift bookkeeping.
  var status: String?
  /// Phase 3 addition. Absolute path to the meeting audio .wav if Minutes
  /// surfaces one (it doesn't today, but the field is reserved for symmetry
  /// with the /minutes/stop response shape).
  var audioPath: String?
  /// Phase 3 addition. Absolute path to `<meetingFolder>/transcript.md`.
  /// Cached once the transcript is copied out of Minutes' meetings dir.
  var transcriptPath: String?
}

struct MinutesStateFile: Codable {
  var version: Int
  var activeRecordings: [String: MinutesStateRecording]
  var processedEvents: [String]
  var pendingCleanup: [String]
  // Other fields (lastDetector, lastError, firstRecordingConfirmedOn,
  // lastDigestSentOn) are intentionally omitted — this Swift service doesn't
  // own them. If the TS side wrote them, we preserve them via the opaque
  // pass-through below.

  private enum CodingKeys: String, CodingKey {
    case version, activeRecordings, processedEvents, pendingCleanup
  }

  static let empty = MinutesStateFile(
    version: 1, activeRecordings: [:], processedEvents: [], pendingCleanup: [])
}

/// Atomic state-file I/O. We go through `JSONSerialization` rather than
/// `JSONEncoder` because we want to preserve unknown top-level fields the TS
/// side might add without us having to model every field. Round-trip pattern:
///
///   - read → Any (full object tree)
///   - merge our known fields
///   - write .tmp → rename (atomic)
enum MinutesStateStore {
  static func path() -> String {
    let home = NSHomeDirectory()
    let dir = (home as NSString)
      .appendingPathComponent("Library/Application Support/minutes-agent")
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    return (dir as NSString).appendingPathComponent("state.json")
  }

  /// Load the state file, returning the full top-level dict (so we can
  /// preserve unknown keys) and a typed `activeRecordings` map.
  static func load() -> (raw: [String: Any], recordings: [String: MinutesStateRecording]) {
    let p = path()
    guard FileManager.default.fileExists(atPath: p),
          let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return ([
        "version": 1,
        "activeRecordings": [:] as [String: Any],
        "processedEvents": [] as [Any],
        "pendingCleanup": [] as [Any],
      ], [:])
    }
    var recordings: [String: MinutesStateRecording] = [:]
    if let ar = obj["activeRecordings"] as? [String: Any] {
      for (k, v) in ar {
        guard let vDict = v as? [String: Any],
              let vData = try? JSONSerialization.data(withJSONObject: vDict),
              let rec = try? JSONDecoder().decode(MinutesStateRecording.self, from: vData)
        else { continue }
        recordings[k] = rec
      }
    }
    return (obj, recordings)
  }

  /// Atomic write. Preserves unknown top-level keys.
  static func save(mutating: ([String: Any], inout [String: MinutesStateRecording]) -> [String: Any]) {
    let (raw, recordings) = load()
    var recordings2 = recordings
    var nextRaw = mutating(raw, &recordings2)

    // Re-serialise activeRecordings from the typed map so we don't drop
    // fields Swift owns.
    var arJson: [String: Any] = [:]
    for (k, v) in recordings2 {
      guard let vData = try? JSONEncoder().encode(v),
            let vObj = try? JSONSerialization.jsonObject(with: vData) as? [String: Any]
      else { continue }
      arJson[k] = vObj
    }
    nextRaw["activeRecordings"] = arJson
    if nextRaw["version"] == nil { nextRaw["version"] = 1 }
    if nextRaw["processedEvents"] == nil { nextRaw["processedEvents"] = [] as [Any] }
    if nextRaw["pendingCleanup"] == nil { nextRaw["pendingCleanup"] = [] as [Any] }

    let data: Data
    do {
      data = try JSONSerialization.data(
        withJSONObject: nextRaw,
        options: [.prettyPrinted, .sortedKeys])
    } catch {
      log("MinutesLifecycle: state save serialise failed: \(error)")
      return
    }
    // `Data.write(options:.atomic)` writes to a sibling temp file and atomically
    // swaps it into place via rename(). Matches the TS `fs.writeFileSync(tmp);
    // fs.renameSync(tmp, p)` pattern but without the two-step footgun.
    do {
      try data.write(to: URL(fileURLWithPath: path()), options: [.atomic])
    } catch {
      log("MinutesLifecycle: state save write failed: \(error)")
    }
  }
}

// MARK: - Filesystem conventions (mirrors scripts/lib/fs.ts)

enum MinutesFS {
  /// Slugify a title the same way the TS side does: NFKD decompose, strip
  /// combining marks, lowercase, strip quotes, non-alphanumeric → dash,
  /// trim edge dashes, cap at 60 chars.
  static func slugify(_ input: String) -> String {
    // Decompose (NFKD) and strip combining marks.
    let decomposed = input.decomposedStringWithCompatibilityMapping
    var stripped = ""
    for scalar in decomposed.unicodeScalars {
      if !(0x0300...0x036F ~= scalar.value) {
        stripped.unicodeScalars.append(scalar)
      }
    }
    let lowered = stripped.lowercased()
    // Strip quotes first (TS removes ' " ` explicitly before the dash pass).
    let noQuotes = lowered.replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "\"", with: "")
      .replacingOccurrences(of: "`", with: "")
    // Everything non-[a-z0-9] becomes a dash run, which collapses on replacement.
    var dashed = ""
    var lastWasDash = false
    for ch in noQuotes {
      if ch.isASCII, ch.isLetter || ch.isNumber {
        dashed.append(ch)
        lastWasDash = false
      } else {
        if !lastWasDash {
          dashed.append("-")
          lastWasDash = true
        }
      }
    }
    // Trim edge dashes.
    while dashed.hasPrefix("-") { dashed.removeFirst() }
    while dashed.hasSuffix("-") { dashed.removeLast() }
    return String(dashed.prefix(60))
  }

  /// Resolve the meetings root using the same precedence as `scripts/lib/fs.ts`:
  /// env override → default Drive path (`~/Library/CloudStorage/GoogleDrive-rohit.sabu@gmail.com/My Drive/Meetings`)
  /// → first `GoogleDrive-*` mount. Falls back to `~/Meetings/` with a warning
  /// if nothing is mountable — the TS throws, but we'd rather degrade in dev
  /// than 500 the bridge.
  static func meetingsRoot() -> String {
    if let override = ProcessInfo.processInfo.environment["MINUTES_AGENT_MEETINGS_ROOT"],
       !override.isEmpty
    {
      let abs = (override as NSString).expandingTildeInPath
      try? FileManager.default.createDirectory(
        atPath: abs, withIntermediateDirectories: true)
      ensureSubdirs(abs)
      return abs
    }

    let home = NSHomeDirectory()
    let cloud = (home as NSString).appendingPathComponent("Library/CloudStorage")
    let primary = (cloud as NSString)
      .appendingPathComponent("GoogleDrive-rohit.sabu@gmail.com/My Drive/Meetings")
    let primaryParent = (primary as NSString).deletingLastPathComponent
    if FileManager.default.fileExists(atPath: primaryParent) {
      try? FileManager.default.createDirectory(
        atPath: primary, withIntermediateDirectories: true)
      ensureSubdirs(primary)
      return primary
    }

    // Try any GoogleDrive-* mount
    if FileManager.default.fileExists(atPath: cloud) {
      if let entries = try? FileManager.default.contentsOfDirectory(atPath: cloud) {
        for entry in entries {
          guard entry.hasPrefix("GoogleDrive-") else { continue }
          let candidate = (cloud as NSString)
            .appendingPathComponent(entry)
            .appending("/My Drive/Meetings")
          try? FileManager.default.createDirectory(
            atPath: candidate, withIntermediateDirectories: true)
          ensureSubdirs(candidate)
          return candidate
        }
      }
    }

    // Dev fallback — TS throws here. Swift degrades so the bridge can still
    // smoke-test on a clean machine without Drive.
    let fallback = (home as NSString).appendingPathComponent("Meetings")
    log("MinutesLifecycle: meetingsRoot falling back to \(fallback) — no Drive mount detected")
    try? FileManager.default.createDirectory(
      atPath: fallback, withIntermediateDirectories: true)
    ensureSubdirs(fallback)
    return fallback
  }

  private static func ensureSubdirs(_ root: String) {
    for sub in ["_inbox", "by-project", "by-person"] {
      let p = (root as NSString).appendingPathComponent(sub)
      try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    }
  }

  /// Compute the per-meeting folder path, creating it + a `screenshots/` child.
  /// Matches `scripts/lib/fs.ts::meetingFolderFor`.
  static func meetingFolder(start: Date, title: String, attendees: [String]) -> String {
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year, .month, .day], from: start)
    let y = String(format: "%04d", comps.year ?? 1970)
    let m = String(format: "%02d", comps.month ?? 1)
    let d = String(format: "%02d", comps.day ?? 1)

    let dateStr = "\(y)-\(m)-\(d)"
    let names = attendees.prefix(3).map { email -> String in
      email.split(separator: "@").first.map(String.init) ?? email
    }.joined(separator: "-")
    let folderName = "\(dateStr) — \(slugify(title)) — \(slugify(names))"
    let full = (meetingsRoot() as NSString)
      .appendingPathComponent("\(y)/\(m)/\(folderName)")
    try? FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(
      atPath: (full as NSString).appendingPathComponent("screenshots"),
      withIntermediateDirectories: true)
    return full
  }
}

// MARK: - Env / PATH helpers

enum MinutesLifecycleEnv {
  /// Mirror the PATH augmentation in `MinutesSubprocess.augmentedPath` so
  /// `npx`, `tsx`, `minutes-mcp`, and `node` all resolve even when Omi was
  /// launched via LaunchServices (which strips shell PATH).
  static func augmentedPath() -> String {
    let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var paths: [String] = []
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

  /// Full env for spawning Node tooling — process env + augmented PATH +
  /// minutes-agent's `node_modules/.bin` on the PATH so the pinned
  /// `minutes-mcp@0.13.3` dependency resolves without a network npx fetch.
  static func augmented() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let agentRoot = MinutesSubprocess.minutesAgentRoot()
    let agentBin = (agentRoot as NSString).appendingPathComponent("node_modules/.bin")
    let augmented = augmentedPath()
    if FileManager.default.fileExists(atPath: agentBin) {
      env["PATH"] = "\(agentBin):\(augmented)"
    } else {
      env["PATH"] = augmented
    }
    return env
  }

  /// Lifecycle mode selector. Phase 3 adds this flag so we can fall back to
  /// the Phase 1 TS shell-out path instantly if the Swift lifecycle
  /// regresses. Default: `swift`. Override with `OMI_MINUTES_LIFECYCLE=ts`.
  enum LifecycleMode: String { case swift, ts }
  static func lifecycleMode() -> LifecycleMode {
    let raw = ProcessInfo.processInfo.environment["OMI_MINUTES_LIFECYCLE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? "swift"
    return LifecycleMode(rawValue: raw) ?? .swift
  }
}

// MARK: - Lifecycle actor

/// Owns the MCP client, the in-memory recording registry, and state-file
/// persistence. One instance per Omi app via `.shared`.
actor MinutesLifecycleService {
  static let shared = MinutesLifecycleService()

  private let userEmail = "rohit.sabu@gmail.com"
  private let client = MinutesMCPClient()
  private var recordings: [String: MinutesStateRecording] = [:]
  private var hasHydratedFromDisk = false

  // MARK: - Start / Stop

  struct StartOutcome {
    let meetingId: String
    let folder: String
    let startedAt: Date
    let title: String
  }

  func start(title: String, source: String) async throws -> StartOutcome {
    hydrateIfNeeded()

    let now = Date()
    // Correlation handle matches the TS `manual-${iso}` convention so state.json
    // and downstream consumers don't care which side minted it.
    let meetingId = "manual-\(Self.iso(now))"
    let endsAt = now.addingTimeInterval(60 * 60)  // default 60min duration

    let folder = MinutesFS.meetingFolder(
      start: now, title: title, attendees: [userEmail])

    // Call start_recording. The Minutes MCP `start_recording` tool takes
    // {title?} (other keys silently ignored — see MINUTES_MCP_PROTOCOL.md).
    // Response is plain text containing `Recording started (PID: <n>). …`.
    let responseText: String
    do {
      responseText = try await client.callTool(
        name: "start_recording",
        arguments: ["title": .string(title)],
        timeoutSec: 30
      )
    } catch {
      log("MinutesLifecycle: start_recording failed: \(error)")
      throw MinutesLifecycleError.captureFailed("start_recording call failed: \(error)")
    }

    guard let pid = Self.extractPid(responseText) else {
      log("MinutesLifecycle: start_recording response did not report a PID: \(responseText)")
      throw MinutesLifecycleError.captureFailed(
        "start_recording did not report 'Recording started ... PID: N'. response: \(responseText.prefix(500))")
    }

    var rec = MinutesStateRecording(
      eventId: meetingId,
      calendarId: "manual",
      meetingId: meetingId,
      meetingFolder: folder,
      meetingPath: nil,
      jobId: nil,
      recordingPid: pid,
      startedAt: Self.iso(now),
      endsAt: Self.iso(endsAt),
      captureMode: "snapshot",
      capturePid: nil,
      transcriptPid: nil,
      briefed: true,
      confirmedByUser: true,
      source: source,
      meetingTitle: title,
      status: "active",
      audioPath: nil,
      transcriptPath: nil
    )
    rec.transcriptPath = (folder as NSString).appendingPathComponent("transcript.md")
    recordings[meetingId] = rec
    persistRecordings()

    log("MinutesLifecycle: start meetingId=\(meetingId) folder=\(folder) pid=\(pid)")
    return StartOutcome(meetingId: meetingId, folder: folder, startedAt: now, title: title)
  }

  struct StopOutcome {
    let meetingId: String
    let stoppedAt: Date
    let durationSec: Int
    let transcriptPath: String  // absolute path to <folder>/transcript.md
    let audioPath: String?
    let startedAt: Date
  }

  func stop(meetingId: String) async throws -> StopOutcome {
    hydrateIfNeeded()

    guard let rec = recordings[meetingId] else {
      throw MinutesLifecycleError.unknownMeeting(meetingId)
    }

    // Call stop_recording. Response is plain text; parse with the same
    // patterns as `scripts/stop-now.ts::parseStopResponse`.
    let responseText: String
    do {
      responseText = try await client.callTool(
        name: "stop_recording",
        arguments: [:],
        timeoutSec: 90
      )
    } catch {
      log("MinutesLifecycle: stop_recording failed: \(error)")
      throw MinutesLifecycleError.stopFailed("stop_recording call failed: \(error)")
    }

    let parsed = Self.parseStopResponse(responseText)
    log("MinutesLifecycle: stop_recording result filePath=\(parsed.filePath ?? "nil") jobId=\(parsed.jobId ?? "nil") queued=\(parsed.queued)")

    let now = Date()
    var updated = rec
    updated.meetingPath = parsed.filePath
    updated.jobId = parsed.jobId
    updated.status = parsed.filePath != nil ? "finalizing" : "finalizing"
    recordings[meetingId] = updated
    persistRecordings()

    // Transcript finalisation. We always place the final transcript at
    // `<folder>/transcript.md` because that's what the enricher + the
    // `/minutes/transcript` route read. If `stop_recording` gave us the
    // source path synchronously, copy it now. Otherwise kick off a detached
    // task that polls for up to 120s (matches TS post-meeting.ts settle).
    let folderTranscript = (rec.meetingFolder as NSString)
      .appendingPathComponent("transcript.md")

    let startedAfter = Self.parseIso(rec.startedAt) ?? now.addingTimeInterval(-3600)

    if let src = parsed.filePath, FileManager.default.fileExists(atPath: src) {
      do {
        if FileManager.default.fileExists(atPath: folderTranscript) {
          try FileManager.default.removeItem(atPath: folderTranscript)
        }
        try FileManager.default.copyItem(atPath: src, toPath: folderTranscript)
        markTranscriptFinal(meetingId: meetingId, transcriptPath: folderTranscript)
      } catch {
        log("MinutesLifecycle: failed to copy transcript \(src) → \(folderTranscript): \(error). Will poll.")
        spawnFinalizationPoller(
          meetingId: meetingId,
          folderTranscript: folderTranscript,
          hintedPath: parsed.filePath,
          startedAfter: startedAfter
        )
      }
    } else {
      // No synchronous path — poll. On Minutes CLI v0.10.0 stop_recording
      // returns neither `**Saved:**` nor a `Job:` id, so the poller falls
      // back to scanning ~/meetings/ for recently-modified .md files.
      spawnFinalizationPoller(
        meetingId: meetingId,
        folderTranscript: folderTranscript,
        hintedPath: parsed.filePath,
        startedAfter: startedAfter
      )
    }

    // Start time round-trip (we stored it as ISO). Fallback to now if parse fails.
    let startedAt = Self.parseIso(rec.startedAt) ?? now
    let durationSec = Int(now.timeIntervalSince(startedAt))
    return StopOutcome(
      meetingId: meetingId,
      stoppedAt: now,
      durationSec: durationSec,
      transcriptPath: folderTranscript,
      audioPath: nil,
      startedAt: startedAt
    )
  }

  /// Lookup for the `/minutes/transcript` route and the bridge `session()` helper.
  func recording(_ meetingId: String) -> MinutesStateRecording? {
    hydrateIfNeeded()
    return recordings[meetingId]
  }

  /// Current session folder — used by the bridge transcript handler.
  func folder(_ meetingId: String) -> String? {
    recording(meetingId)?.meetingFolder
  }

  /// Is the transcript final? (Stopped + file exists.) Matches the TS
  /// definition of isFinal in the bridge response.
  func transcriptIsFinal(_ meetingId: String) -> Bool {
    guard let rec = recordings[meetingId] else { return false }
    if rec.status == "completed" { return true }
    let p = rec.transcriptPath
      ?? (rec.meetingFolder as NSString).appendingPathComponent("transcript.md")
    return FileManager.default.fileExists(atPath: p)
  }

  // MARK: - Enrichment (fire-and-forget)

  /// Invoke the TS enricher. The enricher stays in TS for Phase 3 per the
  /// plan; Swift just spawns it with an augmented env and returns the job id
  /// immediately. The caller gets 202 + jobId; output sidecars land in the
  /// meeting folder when the enricher finishes (30-90s typical).
  func enrich(transcriptPath: String, meetingId: String) -> UUID {
    let jobId = UUID()
    log("MinutesLifecycle: enrich job \(jobId) meetingId=\(meetingId) transcript=\(transcriptPath)")
    Task.detached(priority: .utility) {
      let outcome = await MinutesSubprocess.run(
        script: "scripts/v2/post-meeting-enrich.ts",
        args: ["--meeting", transcriptPath, "--no-notify"],
        captureStdout: false,
        detach: false,
        timeoutSec: 900  // generous cap; enrichment can take 1-2min on a cold Claude-cli
      )
      log("MinutesLifecycle: enrich job \(jobId) exited \(outcome.exitCode) meetingId=\(meetingId)")
    }
    return jobId
  }

  // MARK: - Shutdown

  /// Graceful shutdown — called from `AppDelegate.applicationWillTerminate`.
  /// If any recording is still `active`, attempt a clean MCP stop so the
  /// Minutes server finalises the WAV and writes the meeting .md. Then
  /// persist state so the next launch can observe finalisation status.
  func gracefulShutdown() async {
    hydrateIfNeeded()
    let active = recordings.values.filter { $0.status == "active" }
    if !active.isEmpty {
      log("MinutesLifecycle: gracefulShutdown — \(active.count) active recording(s) to stop")
    }
    for rec in active {
      do {
        let text = try await client.callTool(
          name: "stop_recording",
          arguments: [:],
          timeoutSec: 30
        )
        let parsed = Self.parseStopResponse(text)
        var updated = rec
        updated.meetingPath = parsed.filePath
        updated.jobId = parsed.jobId
        updated.status = "recoverable"
        recordings[rec.meetingId] = updated
      } catch {
        log("MinutesLifecycle: gracefulShutdown stop_recording failed for \(rec.meetingId): \(error)")
        var updated = rec
        updated.status = "recoverable"
        recordings[rec.meetingId] = updated
      }
    }
    persistRecordings()
    await client.shutdown()
  }

  // MARK: - Internals

  /// One-shot rehydration from `state.json` so we pick up any entries written
  /// by a previous Swift run (or by the TS side under `OMI_MINUTES_LIFECYCLE=ts`).
  private func hydrateIfNeeded() {
    if hasHydratedFromDisk { return }
    hasHydratedFromDisk = true
    let (_, recs) = MinutesStateStore.load()
    recordings = recs
    log("MinutesLifecycle: hydrated \(recordings.count) recording(s) from \(MinutesStateStore.path())")
  }

  private func persistRecordings() {
    let snapshot = recordings
    MinutesStateStore.save { raw, typed in
      typed = snapshot
      // Preserve every top-level key the TS side (or us, previously) wrote —
      // `activeRecordings` is re-serialised from `typed` by the store.
      return raw
    }
  }

  /// Mark a transcript as final on the actor (state dict + disk).
  private func markTranscriptFinal(meetingId: String, transcriptPath: String) {
    guard var rec = recordings[meetingId] else { return }
    rec.status = "completed"
    rec.transcriptPath = transcriptPath
    recordings[meetingId] = rec
    persistRecordings()
    log("MinutesLifecycle: transcript finalised meetingId=\(meetingId) path=\(transcriptPath)")
  }

  /// Background-poll for the finalised transcript. Checks, every 2s for up to
  /// 120s:
  ///   1. `<folderTranscript>` on disk (someone else may have copied it)
  ///   2. `<hintedPath>` if stop_recording gave us one (v0.13.3 sync path)
  ///   3. newest .md under `~/meetings/` modified after `startedAfter` — the
  ///      Minutes CLI v0.10.0 fallback, where stop_recording returns neither
  ///      path nor job id but Minutes still persists to its default output
  ///      dir. See MINUTES_MCP_PROTOCOL.md § CLI version skew.
  /// First hit copies → folderTranscript and marks the session completed.
  nonisolated private func spawnFinalizationPoller(
    meetingId: String,
    folderTranscript: String,
    hintedPath: String?,
    startedAfter: Date
  ) {
    Task.detached(priority: .utility) { [weak self] in
      let deadline = Date().addingTimeInterval(120)
      while Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        // (1) someone else copied it
        if FileManager.default.fileExists(atPath: folderTranscript) {
          await self?.markTranscriptFinal(meetingId: meetingId, transcriptPath: folderTranscript)
          return
        }
        // (2) hinted path from stop_recording
        if let src = hintedPath, FileManager.default.fileExists(atPath: src) {
          do {
            try FileManager.default.copyItem(atPath: src, toPath: folderTranscript)
            await self?.markTranscriptFinal(meetingId: meetingId, transcriptPath: folderTranscript)
            return
          } catch {
            log("MinutesLifecycle: finalization poller copy failed (hinted): \(error)")
          }
        }
        // (3) scan ~/meetings/ for recently-modified .md
        if let src = Self.newestMeetingMarkdown(after: startedAfter),
           FileManager.default.fileExists(atPath: src)
        {
          do {
            try FileManager.default.copyItem(atPath: src, toPath: folderTranscript)
            await self?.markTranscriptFinal(meetingId: meetingId, transcriptPath: folderTranscript)
            log("MinutesLifecycle: finalization poller recovered transcript from ~/meetings/ (CLI v0.10.0 fallback): \(src)")
            return
          } catch {
            log("MinutesLifecycle: finalization poller copy failed (~/meetings/ scan): \(error)")
          }
        }
      }
      log("MinutesLifecycle: finalization poller timed out after 120s for \(meetingId)")
    }
  }

  /// Scan `~/meetings/` for the newest `.md` file whose mtime is after
  /// `after`. Returns nil if none exists or the dir is missing. Matches the
  /// TS post-meeting.ts settle behaviour when Minutes CLI v0.10.0 reports
  /// neither path nor job id on stop.
  private static func newestMeetingMarkdown(after: Date) -> String? {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent("meetings")
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir)
    else { return nil }
    var best: (path: String, mtime: Date)? = nil
    for entry in entries where entry.hasSuffix(".md") {
      let full = (dir as NSString).appendingPathComponent(entry)
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
            let mtime = attrs[.modificationDate] as? Date,
            mtime > after
      else { continue }
      if best == nil || mtime > best!.mtime {
        best = (full, mtime)
      }
    }
    return best?.path
  }

  // MARK: - Parsers (shared with the TS regexes for contract parity)

  /// Extract PID from `Recording started[...]PID: 12345`. Matches the regex
  /// in `scripts/record-now.ts`.
  static func extractPid(_ text: String) -> Int? {
    // "Recording started" must be present — without it we treat it as a hard
    // failure (cf. MINUTES_MCP_PROTOCOL.md § Silent-fallback bug pattern).
    guard text.contains("Recording started") else { return nil }
    if let range = text.range(of: "PID:\\s*(\\d+)", options: .regularExpression) {
      let match = text[range]
      if let pidRange = match.range(of: "\\d+", options: .regularExpression) {
        return Int(match[pidRange])
      }
    }
    return nil
  }

  struct StopParseResult {
    let filePath: String?
    let jobId: String?
    let queued: Bool
    let text: String
  }

  /// Parse `stop_recording` response text. Matches TS
  /// `scripts/stop-now.ts::parseStopResponse`.
  static func parseStopResponse(_ text: String) -> StopParseResult {
    // `**Saved:** /abs/path` on its own line — sync success.
    let filePath = firstCapture(
      in: text,
      pattern: #"^\s*\*\*Saved:\*\*\s+(.+)$"#,
      options: [.anchorsMatchLines]
    )
    // `Job: <job_id>` — async queued.
    let jobId = firstCapture(in: text, pattern: #"Job:\s+([^.\s]+)"#)
    let queued = text.range(of: "Processing queued") != nil
    return StopParseResult(filePath: filePath, jobId: jobId, queued: queued, text: text)
  }

  /// Run `pattern` against `text` and return the first capture group's text
  /// (trimmed of whitespace), or nil if no match / no group.
  private static func firstCapture(
    in text: String,
    pattern: String,
    options: NSRegularExpression.Options = []
  ) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
      return nil
    }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges >= 2
    else { return nil }
    return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
  }

  static func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }

  static func parseIso(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
  }
}

// MARK: - Error surface

enum MinutesLifecycleError: Error, CustomStringConvertible {
  case captureFailed(String)
  case stopFailed(String)
  case unknownMeeting(String)
  case transcriptMissing(String)

  var description: String {
    switch self {
    case .captureFailed(let m): return m
    case .stopFailed(let m): return m
    case .unknownMeeting(let id): return "no active session for meetingId=\(id)"
    case .transcriptMissing(let p): return "transcript does not exist at \(p) (meeting may not be stopped yet)"
    }
  }
}
