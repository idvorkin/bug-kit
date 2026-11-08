#if canImport(UIKit) && os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import BugKit

private final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [(String, [String: JSONValue])] = []
  func append(_ event: String, _ fields: [String: JSONValue]) { lock.withLock { events.append((event, fields)) } }
  func opens() -> [[String: JSONValue]] { lock.withLock { events.filter { $0.0 == "bug_report_open" }.map(\.1) } }
  func names() -> [String] { lock.withLock { events.map(\.0) } }
}

private final class Sheet: UIViewController {}
private final class OtherWindowRoot: UIViewController {}

/// A `.bugReporting` app in a key window with a sheet up. The sheet, not BugKit, heads the responder chain (#62).
@MainActor private func appWithSheet(systemShake: Bool = true) async throws
  -> (window: UIWindow, sheet: Sheet, field: UITextField, reporter: BugReporter, events: Events, restore: () -> Void)
{
  let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
  let original = scene.windows.first { $0.isKeyWindow }
  let events = Events()
  var options = BugReporterOptions()
  options.systemShake = systemShake
  options.gentleShake = false
  options.captureScreenshots = false
  let reporter = BugReporter(hooks: BugReporterHooks(logger: { events.append($0, $1) }), options: options,
                             store: BugStore(documents: FileManager.default.temporaryDirectory
                               .appendingPathComponent(UUID().uuidString)))
  let window = UIWindow(windowScene: scene)
  window.rootViewController = UIHostingController(rootView: Color.clear.bugReporting(reporter))
  window.makeKeyAndVisible()
  // A previous test's keyboard can hold key status for a moment; the report presents from the key window.
  for _ in 0..<100 where BugReporter.keyWindow() !== window {
    window.makeKey()
    try await Task.sleep(for: .milliseconds(20))
  }
  let sheet = Sheet()
  let field = UITextField()
  sheet.view.addSubview(field)
  await withCheckedContinuation { done in
    window.rootViewController?.present(sheet, animated: false) { done.resume() }
  }
  try await Task.sleep(for: .milliseconds(100))  // let SwiftUI subscribe
  let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    .map { "\(type(of: $0)) key=\($0.isKeyWindow) hidden=\($0.isHidden) mine=\($0 === window)" }
  #expect(BugReporter.keyWindow() === window, "windows: \(windows)")
  return (window, sheet, field, reporter, events, {
    field.resignFirstResponder()
    window.rootViewController?.dismiss(animated: false)
    window.rootViewController = nil  // its .bugReporting stops observing shakes
    window.isHidden = true
    original?.makeKeyAndVisible()
  })
}

@MainActor private func waitForOpen(_ events: Events) async throws {
  for _ in 0..<50 where events.opens().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
}

// One window at a time: each test makes its own window key and presents in it.
@MainActor @Suite(.serialized) struct ShakeTests {
  @Test func shakeOverASheetOpensTheReportOverThatSheet() async throws {
    let app = try await appWithSheet()
    defer { app.restore() }
    app.sheet.motionEnded(.motionShake, with: nil)
    try await waitForOpen(app.events)
    #expect(app.reporter.flow.isPresented)
    #expect(app.reporter.flow.source == .shake)
    #expect(app.events.opens().first?["over"] == "Sheet")
    app.reporter.cancel()
    try await Task.sleep(for: .milliseconds(500))  // the report sheet's dismissal animation
  }

  @Test func shakeInAFocusedTextFieldInsideASheetOpensTheReport() async throws {
    let app = try await appWithSheet()
    defer { app.restore() }
    app.field.becomeFirstResponder()
    app.field.motionEnded(.motionShake, with: nil)
    try await waitForOpen(app.events)
    #expect(app.reporter.flow.isPresented)
    app.reporter.cancel()
    // The keyboard holds key status while it hides; the next test needs its own window to be key.
    let hidden = NotificationCenter.default.notifications(named: UIResponder.keyboardDidHideNotification)
    app.field.resignFirstResponder()
    _ = await withTaskGroup(of: Void.self) { group in
      group.addTask { for await _ in hidden { return } }
      group.addTask { try? await Task.sleep(for: .seconds(2)) }
      await group.next()
      group.cancelAll()
    }
    try await Task.sleep(for: .milliseconds(500))  // the report sheet's dismissal animation
  }

  @Test func shakeOverAnAlertOpensTheReport() async throws {
    let app = try await appWithSheet()
    defer { app.restore() }
    let alert = UIAlertController(title: "Alert", message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    await withCheckedContinuation { done in app.sheet.present(alert, animated: false) { done.resume() } }
    alert.motionEnded(.motionShake, with: nil)
    try await waitForOpen(app.events)
    #expect(app.reporter.flow.isPresented)
    #expect(app.events.opens().first?["over"] == "UIAlertController")
    app.reporter.cancel()
    try await Task.sleep(for: .milliseconds(500))  // the report sheet's dismissal animation
  }

  @Test func theReportOpensOverTheWindowThatWasShakenNotTheKeyOne() async throws {
    let app = try await appWithSheet()
    let scene = try #require(app.window.windowScene)
    let other = UIWindow(windowScene: scene)  // same scene, visible, never made key
    other.rootViewController = OtherWindowRoot()
    other.isHidden = false
    defer {
      other.rootViewController?.dismiss(animated: false)
      other.isHidden = true
      app.restore()
    }
    #expect(!other.isKeyWindow)
    other.motionEnded(.motionShake, with: nil)
    try await waitForOpen(app.events)
    #expect(app.events.opens().first?["over"] == "OtherWindowRoot")
    app.reporter.cancel()
    try await Task.sleep(for: .milliseconds(500))  // the report sheet's dismissal animation
  }

  @Test func aShakeInAnotherScenesWindowLeavesThisSceneAlone() async throws {
    let app = try await appWithSheet()
    defer { app.restore() }
    let elsewhere = UIWindow(frame: .zero)  // not in this app's scene
    elsewhere.rootViewController = OtherWindowRoot()  // something the report could open over
    elsewhere.motionEnded(.motionShake, with: nil)
    try await waitForOpen(app.events)
    #expect(!app.reporter.flow.isPresented)
    #expect(!app.events.names().contains("shake"))
    #expect(app.events.opens().isEmpty)
  }

  // BugKit #96: the report sheet went away with no cancel, save or swipe (a phone lock, or the app dismissing
  // everything it presented). Before the fix, every later shake logged already_open and showed nothing.
  @Test func aReportSheetDismissedBehindBugKitsBackDoesNotBlockTheNext() async throws {
    let app = try await appWithSheet()
    defer { app.restore() }
    app.sheet.motionEnded(.motionShake, with: nil)
    try await waitForOpen(app.events)
    #expect(app.reporter.flow.isPresented)
    await withCheckedContinuation { done in app.sheet.dismiss(animated: false) { done.resume() } }
    #expect(app.reporter.flow.isPresented)  // BugKit was not told
    app.sheet.motionEnded(.motionShake, with: nil)
    for _ in 0..<50 where app.events.opens().count < 2 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(app.events.opens().count == 2)
    #expect(app.events.opens().last?["already_open"] == nil)
    #expect(app.events.opens().last?["over"] == "Sheet")
    app.reporter.cancel()
    try await Task.sleep(for: .milliseconds(500))  // the report sheet's dismissal animation
  }

  // BugKit #107: on the Mac, "Log it and another" ran its reopen while the closed dialog was still presented. The
  // fresh dialog was pictured over the old one and presented onto it, UIKit dropped it, and BugKit thought it open.
  @Test func anotherWaitsForTheClosedDialogToLeave() async throws {
    let app = try await appWithSheet()
    defer { app.restore() }
    app.sheet.motionEnded(.motionShake, with: nil)
    try await waitForOpen(app.events)
    let closed = try #require(app.sheet.presentedViewController)
    app.reporter.flow.note = "first"
    #expect(app.reporter.flow.log(another: true, style: .recapture) == "first")
    app.reporter.reopen(after: closed, in: app.window)  // the Mac's early completion: the dialog is still up
    try await Task.sleep(for: .milliseconds(300))
    #expect(app.events.opens().count == 1)
    await withCheckedContinuation { done in closed.dismiss(animated: false) { done.resume() } }
    for _ in 0..<50 where app.events.opens().count < 2 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(app.events.opens().count == 2)
    #expect(app.events.opens().last?["source"] == "another")
    #expect(app.events.opens().last?["over"] == "Sheet")
    #expect(app.reporter.flow.isPresented)
    app.reporter.cancel()
    try await Task.sleep(for: .milliseconds(500))  // the report sheet's dismissal animation
  }

  @Test func aDialogUIKitRefusesToShowLeavesNoReportOpen() async throws {
    let app = try await appWithSheet()
    defer { app.restore() }
    let offscreen = UIWindow(windowScene: try #require(app.window.windowScene))
    offscreen.rootViewController = UIViewController()  // never shown, so UIKit refuses to present from it
    app.reporter.open(from: .button, in: offscreen)
    #expect(app.events.opens().isEmpty)
    #expect(app.events.names().contains("error"))
    #expect(!app.reporter.flow.isPresented)
  }

  @Test func systemShakeOffIgnoresTheShake() async throws {
    let app = try await appWithSheet(systemShake: false)
    defer { app.restore() }
    app.sheet.motionEnded(.motionShake, with: nil)
    try await waitForOpen(app.events)
    #expect(!app.reporter.flow.isPresented)
  }
}
#endif
