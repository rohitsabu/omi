import EventKit
import Foundation

// MARK: - CalendarAccessManager
//
// Phase 2 of the minutes×omi merge. Owns the one `EKEventStore` in the app and
// serializes the "do we have calendar TCC yet?" dance.
//
// Why this exists separately from `CalendarBridge.swift`:
//   * EventKit's `EKEventStore` is designed to be long-lived. Apple's guidance
//     is one-store-per-app. Keeping ownership here keeps the bridge file a
//     plain router.
//   * The TCC prompt is fired by the *first* access request macOS sees from
//     the app. If we scatter `requestFullAccessToEvents` calls across multiple
//     call sites we get a race where two prompts can be queued. One actor,
//     one request.
//   * `EKEventStore.authorizationStatus(for:)` is a cheap class method (a TCC
//     plist lookup) so we don't need to mirror the state in an actor — the
//     snapshot just re-queries whenever it's rebuilt. The actor is purely for
//     serializing the one-shot `ensureAccess()` call.
//
// Notes:
//   * We only use the macOS-14+ `requestFullAccessToEvents` API. `LSMinimumSystemVersion`
//     is pinned to 14.0 in Info.plist so the legacy `requestAccess(to:)` path
//     is unreachable. If the deployment target is ever bumped back to 13 we
//     must add that fallback + the legacy `NSCalendarsUsageDescription` key.
//   * The actor is NOT a SwiftUI observable object. Bridge handlers call
//     `ensureAccess()` and then read events via `eventStore()`. UI code that
//     wants live status should watch `EKEventStoreChanged` notifications.

enum CalendarAccessManager {
  /// String enum matching the `calendarAccess` field on DesktopAutomationSnapshot.
  enum Status: String {
    case granted
    case denied
    case restricted
    case notDetermined

    fileprivate init(_ ek: EKAuthorizationStatus) {
      switch ek {
      case .authorized, .fullAccess: self = .granted
      case .denied: self = .denied
      case .restricted: self = .restricted
      case .notDetermined: self = .notDetermined
      case .writeOnly: self = .denied  // write-only is useless for read routes; treat as denied
      @unknown default: self = .notDetermined
      }
    }
  }

  /// Synchronous snapshot of the current authorization status. Cheap — just a
  /// TCC plist read. Safe to call from any thread / actor.
  static func currentStatus() -> Status {
    Status(EKEventStore.authorizationStatus(for: .event))
  }

  /// String form of `currentStatus()`, used directly in
  /// `DesktopAutomationSnapshot.calendarAccess`.
  static func currentStatusString() -> String { currentStatus().rawValue }

  /// Singleton-ish actor that owns the EKEventStore. Use `store()` to grab the
  /// live instance after the one-shot `ensureAccess()` request has been made.
  actor Gate {
    static let shared = Gate()

    private var storeInstance: EKEventStore?
    private var didRequest = false

    /// Ensure we've run the access-request flow at least once. Returns the
    /// current status after the request completes. Safe to call repeatedly;
    /// the underlying `requestFullAccessToEvents` is only invoked when TCC
    /// still has no decision on record.
    @discardableResult
    func ensureAccess() async -> Status {
      // If TCC has already recorded a decision, short-circuit — EventKit
      // won't show a prompt for granted / denied / restricted, so there's
      // no point invoking requestFullAccessToEvents again.
      let current = Status(EKEventStore.authorizationStatus(for: .event))
      if current != .notDetermined {
        // Even if already granted, make sure we have a live store. Apple
        // recommends reusing a single EKEventStore for the app lifetime.
        if storeInstance == nil { storeInstance = EKEventStore() }
        didRequest = true
        return current
      }

      // Still notDetermined. If we've already attempted a request in this
      // process and the status is *still* notDetermined, a concurrent caller
      // is probably mid-request — serialize by re-checking the status (actor
      // reentrancy suspends us, so by the time we're back here the first
      // request may have resolved). But do NOT permanently flip didRequest
      // to true on a notDetermined outcome — the user may not have seen the
      // prompt yet (onboarding intercepts, app wasn't frontmost, etc.) and
      // we want the next /calendar/* hit to re-fire it.
      let store = storeInstance ?? EKEventStore()
      storeInstance = store

      do {
        // Fires the TCC prompt if `.notDetermined`. `NSCalendarsFullAccessUsageDescription`
        // in Info.plist is mandatory for macOS 14+ — without it the system
        // silently denies without prompting.
        let granted = try await store.requestFullAccessToEvents()
        let post = Status(EKEventStore.authorizationStatus(for: .event))
        log(
          "CalendarAccessManager: requestFullAccessToEvents returned granted=\(granted) (status=\(post.rawValue))"
        )
        if post != .notDetermined {
          didRequest = true
        }
        return post
      } catch {
        log(
          "CalendarAccessManager: requestFullAccessToEvents threw \(error.localizedDescription) — falling through to status read"
        )
        return Status(EKEventStore.authorizationStatus(for: .event))
      }
    }

    /// Return the managed EKEventStore, or nil if access has not been granted.
    /// Bridge handlers should use this and 503 if nil.
    func store() -> EKEventStore? {
      guard Status(EKEventStore.authorizationStatus(for: .event)) == .granted else {
        return nil
      }
      if storeInstance == nil { storeInstance = EKEventStore() }
      return storeInstance
    }
  }

  /// Called from `AppDelegate.applicationDidFinishLaunching`. Fires the TCC
  /// prompt on first-ever launch of a freshly-installed bundle. Subsequent
  /// launches are no-ops because TCC already has a decision recorded.
  ///
  /// The guardrail: if this is the *only* place we call `ensureAccess()` and
  /// the app is rebuilt/resigned into a new bundle id without a prompt ever
  /// firing (e.g. the UI never reached a state that triggered the launch
  /// path), `calendarAccess` stays at `notDetermined` forever. Defensively,
  /// the bridge handlers also call `ensureAccess()` on first /calendar/*
  /// hit — see `CalendarBridge.swift`.
  static func requestAccessOnLaunch() {
    Task.detached(priority: .utility) {
      let status = await Gate.shared.ensureAccess()
      log("CalendarAccessManager: launch-time ensureAccess → \(status.rawValue)")
    }
  }
}
