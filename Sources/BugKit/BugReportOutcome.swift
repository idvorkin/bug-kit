import Foundation

/// What became of a report the person opened (#120), so an app can confirm exactly that ("Sent ✓") instead of
/// assuming a closed dialog means a saved report. `BugReporter` publishes each one as `lastOutcome` and passes it
/// to `onOutcome`. Outcomes arrive in the order they finish, not the order the person acted: a save finishes
/// asynchronously, so a report's `saved` or `failed` can arrive after a later `cancelled` (say, "Log it and another"
/// then Cancel). Show "Sent ✓" on any `saved` rather than resolving on the first outcome after opening the dialog.
public enum BugReportOutcome: Equatable, Sendable {
  /// bugs.jsonl holds the report, so the listener files it. `queued`: the writer's delivery (CloudKit) took it to
  /// upload; false when the app has no delivery or the hand-off failed (the report stays local and is pulled from
  /// the device). The upload itself happens later and is not reported here.
  case saved(id: UUID, queued: Bool)
  /// bugs.jsonl did not take the report: only the session log has it, and nothing will file it.
  case failed(id: UUID)
  /// The dialog closed (Cancel, a swipe down, or a dialog the system removed) without saving its current note, or an
  /// open could not show it (no window, or the presentation was dropped).
  /// It says nothing about reports already logged from the dialog: each gets its own `saved` or `failed`, which can
  /// arrive after this `cancelled` because saves finish asynchronously.
  case cancelled

  /// True for `saved`.
  public var isSaved: Bool {
    if case .saved = self { return true }
    return false
  }
}
