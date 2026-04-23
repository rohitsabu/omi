import EventKit
import Foundation

// MARK: - CalendarBridge
//
// Phase 2 of the minutes×omi merge. Exposes a read-only `/calendar/*` surface
// on the existing automation bridge so scheduled jobs, the minutes-agent TS
// poller-during-transition, and future in-app services all read calendar data
// from the same EventKit-backed source.
//
// Routes:
//   GET /calendar/upcoming?withinMinutes=<int>&includeAllDay=<bool>&includeSubscribed=<bool>
//   GET /calendar/active
//   GET /calendar/event?id=<ek-event-id>
//
// Everything is read-only. No writes, no RSVPs, no deletes — intentional for
// this phase. When Phase 3 wires auto-recording it'll still read via these
// routes; write surfaces come later (if at all — Omi's "meeting" concept lives
// on the backend, not in the user's calendar).
//
// Access:
//   * First call to any route will trigger `CalendarAccessManager.Gate.ensureAccess()`
//     if the TCC decision is still `.notDetermined`. This is defensive — the
//     launch-time call in OmiApp already does this, but a bundle rebuild or
//     resign can land the app in a fresh TCC slot where the prompt only fires
//     on the next access. We want curl-able recovery from that state.
//   * If access is `denied` or `restricted` the route returns 503
//     `{ ok: false, error: "calendar_access_denied" }`.
//
// Pattern note: mirrors `MinutesBridge.swift` layout (Router → Handlers →
// Shapes). Not quite copy-paste because the minutes routes wrap subprocesses
// and these wrap a Swift framework, but the shape is the same so future
// readers can navigate either file by the other.

// MARK: Request / Response shapes

/// Shared shape for all three routes. Kept loose on optionals so the response
/// is readable whether the user's calendars have rich metadata (organizer,
/// location, attendees) or are sparse personal events.
struct CalendarEventJSON: Codable {
  let id: String
  let title: String
  let startsAt: String  // ISO-8601
  let endsAt: String
  let location: String?
  let organizer: String?
  let attendees: [String]
  let isOnline: Bool
  let meetingUrl: String?
  let calendarTitle: String
  let isAllDay: Bool
  let notes: String?  // present on /calendar/event only; nil on upcoming/active
}

struct CalendarUpcomingResult: Codable {
  let ok: Bool
  let withinMinutes: Int
  let count: Int
  let events: [CalendarEventJSON]
}

struct CalendarActiveResult: Codable {
  let ok: Bool
  let active: CalendarEventJSON?
  let others: [CalendarEventJSON]  // empty if nothing overlaps; non-empty if 2+ events overlap

  // Custom encoder so `active` is always present in the JSON payload — emitted
  // as explicit `null` when nothing is in progress, rather than being omitted.
  // Consumers can then assume the key exists and test `.active === null`
  // instead of having to disambiguate "no overlap" from "field missing".
  enum CodingKeys: String, CodingKey { case ok, active, others }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(ok, forKey: .ok)
    if let active { try c.encode(active, forKey: .active) }
    else { try c.encodeNil(forKey: .active) }
    try c.encode(others, forKey: .others)
  }
}

struct CalendarEventResult: Codable {
  let ok: Bool
  let event: CalendarEventJSON
}

// MARK: - Router

enum CalendarBridgeRouter {
  /// Returns a JSON body + HTTP status for the given calendar route, or nil if
  /// the (method, path) pair isn't a calendar route.
  static func handle(method: String, path: String, body: Data) async -> (Data, Int)? {
    let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

    guard DesktopAutomationLaunchOptions.isEnabled else {
      if pathOnly.hasPrefix("/calendar/") {
        return (
          errorBody("bridge_disabled", "OMI_ENABLE_LOCAL_AUTOMATION is not set"), 503
        )
      }
      return nil
    }

    switch (method, pathOnly) {
    case ("GET", "/calendar/upcoming"):
      return await CalendarBridgeHandlers.upcoming(rawPath: path)
    case ("GET", "/calendar/active"):
      return await CalendarBridgeHandlers.active(rawPath: path)
    case ("GET", "/calendar/event"):
      return await CalendarBridgeHandlers.event(rawPath: path)
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

enum CalendarBridgeHandlers {
  // MARK: /calendar/upcoming

  static func upcoming(rawPath: String) async -> (Data, Int) {
    // Query: withinMinutes (default 60), includeAllDay (default false),
    // includeSubscribed (default false — user-writeable calendars only).
    let q = queryParams(rawPath)
    let withinMinutes = intParam(q["withinMinutes"], default: 60)
    let includeAllDay = boolParam(q["includeAllDay"], default: false)
    let includeSubscribed = boolParam(q["includeSubscribed"], default: false)

    if withinMinutes < 0 || withinMinutes > 24 * 60 * 30 {
      return (
        CalendarBridgeRouter.errorBody(
          "bad_request",
          "withinMinutes must be between 0 and \(24 * 60 * 30) (30 days)"), 400
      )
    }

    guard let store = await ensureStore() else {
      return (accessDeniedBody(), 503)
    }

    let now = Date()
    let end = now.addingTimeInterval(TimeInterval(withinMinutes * 60))
    let calendars = filteredCalendars(store: store, includeSubscribed: includeSubscribed)
    let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
    let events = store.events(matching: predicate)
      .filter { includeAllDay ? true : !$0.isAllDay }
      .filter { $0.endDate > now }  // predicateForEvents returns events that *overlap* the window; trim past-enders
      .sorted { $0.startDate < $1.startDate }

    let payload = CalendarUpcomingResult(
      ok: true,
      withinMinutes: withinMinutes,
      count: events.count,
      events: events.map { encodeEvent($0, includeNotes: false) }
    )
    return (CalendarBridgeRouter.successBody(payload), 200)
  }

  // MARK: /calendar/active

  static func active(rawPath: String) async -> (Data, Int) {
    let q = queryParams(rawPath)
    let includeSubscribed = boolParam(q["includeSubscribed"], default: false)

    guard let store = await ensureStore() else {
      return (accessDeniedBody(), 503)
    }

    let now = Date()
    // Look back 12h and forward 12h — enough to catch a long-running meeting.
    // predicateForEvents wants both bounds; we filter by "in progress now"
    // afterward.
    let calendars = filteredCalendars(store: store, includeSubscribed: includeSubscribed)
    let windowStart = now.addingTimeInterval(-12 * 3600)
    let windowEnd = now.addingTimeInterval(12 * 3600)
    let predicate = store.predicateForEvents(
      withStart: windowStart, end: windowEnd, calendars: calendars)
    let overlapping = store.events(matching: predicate)
      .filter { !$0.isAllDay }
      .filter { $0.startDate <= now && $0.endDate > now }
      .sorted { $0.startDate < $1.startDate }

    let active = overlapping.first.map { encodeEvent($0, includeNotes: false) }
    let others = overlapping.dropFirst().map { encodeEvent($0, includeNotes: false) }
    let payload = CalendarActiveResult(
      ok: true,
      active: active,
      others: Array(others)
    )
    return (CalendarBridgeRouter.successBody(payload), 200)
  }

  // MARK: /calendar/event

  static func event(rawPath: String) async -> (Data, Int) {
    let q = queryParams(rawPath)
    guard let id = q["id"], !id.isEmpty else {
      return (
        CalendarBridgeRouter.errorBody("bad_request", "missing ?id=<ek-event-id>"), 400
      )
    }

    guard let store = await ensureStore() else {
      return (accessDeniedBody(), 503)
    }

    guard let ev = store.event(withIdentifier: id) else {
      return (
        CalendarBridgeRouter.errorBody(
          "event_not_found", "no event matches the supplied id"), 404
      )
    }

    let payload = CalendarEventResult(ok: true, event: encodeEvent(ev, includeNotes: true))
    return (CalendarBridgeRouter.successBody(payload), 200)
  }

  // MARK: - Helpers

  /// Ensure TCC access is resolved and return the shared EKEventStore, or nil
  /// if the user hasn't granted access. Handlers must 503 on nil.
  private static func ensureStore() async -> EKEventStore? {
    let status = await CalendarAccessManager.Gate.shared.ensureAccess()
    guard status == .granted else { return nil }
    return await CalendarAccessManager.Gate.shared.store()
  }

  private static func accessDeniedBody() -> Data {
    let current = CalendarAccessManager.currentStatusString()
    return CalendarBridgeRouter.errorBody(
      "calendar_access_denied",
      "EventKit access is \"\(current)\". Approve in System Settings → Privacy → Calendars and retry."
    )
  }

  /// Filter calendars down to user-writeable ones by default. Holiday /
  /// birthdays / subscribed calendars are noisy, don't describe meetings the
  /// user actually attends, and are excluded unless `includeSubscribed=true`.
  private static func filteredCalendars(store: EKEventStore, includeSubscribed: Bool)
    -> [EKCalendar]
  {
    let all = store.calendars(for: .event)
    if includeSubscribed { return all }
    return all.filter { cal in
      // Skip read-only subscribed calendars (holidays, US holidays feed, etc).
      if cal.isSubscribed { return false }
      // Skip calendars where the user can't add events — a common proxy for
      // "this is someone else's calendar I'm shadowing".
      if !cal.allowsContentModifications { return false }
      // Birthdays calendar is a special EKCalendar with a known title in
      // most locales. `isSubscribed` also tends to be true, but belt-and-
      // suspenders by type.
      if cal.type == .birthday { return false }
      return true
    }
  }

  /// Render an EKEvent into our JSON shape. `includeNotes` flips the `notes`
  /// field on — only /calendar/event populates it because notes can be long
  /// and we don't want to balloon /upcoming responses.
  private static func encodeEvent(_ ev: EKEvent, includeNotes: Bool) -> CalendarEventJSON {
    let attendees = (ev.attendees ?? []).map { attendee -> String in
      if let name = attendee.name, !name.isEmpty { return name }
      return attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }
    let organizer: String? = ev.organizer.map { org in
      if let name = org.name, !name.isEmpty { return name }
      return org.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }
    let meetingUrl = detectMeetingUrl(ev)

    return CalendarEventJSON(
      id: ev.eventIdentifier ?? "",
      title: ev.title ?? "(Untitled)",
      startsAt: iso(ev.startDate),
      endsAt: iso(ev.endDate),
      location: (ev.location?.isEmpty == false) ? ev.location : nil,
      organizer: organizer,
      attendees: attendees,
      isOnline: meetingUrl != nil,
      meetingUrl: meetingUrl,
      calendarTitle: ev.calendar?.title ?? "",
      isAllDay: ev.isAllDay,
      notes: includeNotes ? ev.notes : nil
    )
  }

  /// Return the first video-meeting URL we can find in the event. Checks the
  /// dedicated `url` field, location, and notes for a zoom/meet/webex/teams
  /// URL. Returns nil for events that aren't online meetings.
  private static func detectMeetingUrl(_ ev: EKEvent) -> String? {
    let candidates: [String] = [
      ev.url?.absoluteString ?? "",
      ev.location ?? "",
      ev.notes ?? "",
    ]
    for candidate in candidates where !candidate.isEmpty {
      if let hit = firstMeetingUrl(in: candidate) { return hit }
    }
    return nil
  }

  /// Scan a string for the first URL matching known video-meeting hosts.
  private static func firstMeetingUrl(in text: String) -> String? {
    // Pre-filter: cheap substring check before spinning up a detector.
    let lc = text.lowercased()
    // Keep in sync with BRIDGE_API.md §Calendar. Adding a host here is a
    // non-breaking change; removing one would flip `isOnline` on existing
    // events so prefer soft-matching via host-suffix (done below).
    let hosts = [
      "zoom.us",
      "meet.google.com",
      "webex.com",
      "teams.microsoft.com",
      "teams.live.com",
      "bluejeans.com",
    ]
    guard hosts.contains(where: { lc.contains($0) }) else { return nil }

    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(text.startIndex..., in: text)
    var first: String?
    detector?.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
      guard let url = match?.url else { return }
      let host = url.host?.lowercased() ?? ""
      if hosts.contains(where: { host.hasSuffix($0) }) {
        first = url.absoluteString
        stop.pointee = true
      }
    }
    return first
  }

  // MARK: - Query-param helpers

  private static func queryParams(_ rawPath: String) -> [String: String] {
    guard let qstr = rawPath.split(separator: "?", maxSplits: 1).dropFirst().first else {
      return [:]
    }
    var out: [String: String] = [:]
    for pair in qstr.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard let key = parts.first else { continue }
      let value = parts.count == 2 ? String(parts[1]) : ""
      out[String(key)] = value.removingPercentEncoding ?? value
    }
    return out
  }

  private static func intParam(_ raw: String?, default defaultValue: Int) -> Int {
    guard let raw, !raw.isEmpty, let parsed = Int(raw) else { return defaultValue }
    return parsed
  }

  private static func boolParam(_ raw: String?, default defaultValue: Bool) -> Bool {
    guard let raw, !raw.isEmpty else { return defaultValue }
    switch raw.lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return defaultValue
    }
  }

  private static func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
  }
}
