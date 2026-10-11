#if canImport(UIKit) && os(iOS)
  import CoreMotion
  import SwiftUI
  import UIKit

  /// The app's side of a report: everything BugKit cannot know by itself.
  public struct BugReporterHooks {
    /// The current screen's name ("home", "playback"), as the app's log names it.
    public var screen: @MainActor () -> String
    /// What the app attaches, read at the moment the dialog opens (EA: exercise, playhead; MM: mode, replay time).
    public var context: @MainActor () -> [String: JSONValue]
    /// The session log's path under Documents and the milliseconds since it began; nil when the app has none.
    /// With BugKit's `SessionLog`: `{ log.position }`.
    public var sessionLog: @MainActor () -> (path: String, tMs: Int)?
    /// The app's logger. It receives `bug_report_open`, `bug_report`, `bug_report_cancel`, `shake`, the
    /// `dictation_*` events and `error` events.
    public var logger: BugLogger
    /// Extra files for the report's folder (a clip, video segments); nil for none.
    public var extraFiles: BugExtraFiles?
    /// True while something else holds the microphone (a call): the dictation button is off then (CG #239).
    public var microphoneBusy: @MainActor () -> Bool
    /// Called before a save that copies the session log, so queued events reach the file (`log.flush()`).
    public var flushLog: @MainActor () -> Void
    /// A fresh streaming recognizer for each dictation; nil uses Apple Speech.
    /// The app owns vendor credentials and can supply a server-backed provider.
    public var dictationProvider: (@MainActor @Sendable () -> any BugDictationProvider)?

    public init(
      screen: @escaping @MainActor () -> String = { "" },
      context: @escaping @MainActor () -> [String: JSONValue] = { [:] },
      sessionLog: @escaping @MainActor () -> (path: String, tMs: Int)? = { nil },
      logger: @escaping BugLogger,
      extraFiles: BugExtraFiles? = nil,
      microphoneBusy: @escaping @MainActor () -> Bool = { false },
      flushLog: @escaping @MainActor () -> Void = {},
      dictationProvider: (@MainActor @Sendable () -> any BugDictationProvider)? = nil
    ) {
      self.screen = screen; self.context = context; self.sessionLog = sessionLog; self.logger = logger
      self.extraFiles = extraFiles; self.microphoneBusy = microphoneBusy; self.flushLog = flushLog
      self.dictationProvider = dictationProvider
    }
  }

  /// Opens the report dialog and saves what it says. One per app, created at launch:
  ///
  ///     let reporter = BugReporter(hooks: BugReporterHooks(logger: log.logger))
  ///     ContentView().bugReporting(reporter)
  @MainActor
  @available(iOSApplicationExtension, unavailable, message: "Link BugKit only into the host app; extensions cannot present the app reporter.")
  public final class BugReporter: ObservableObject {
    @Published public var flow = BugReportFlow()
    /// The moment the dialog opened: the screen as it was, and the context then.
    @Published public private(set) var screenshot: UIImage?
    @Published public private(set) var context: [String: JSONValue] = [:]
    /// What the last save says, for a status line or a toast.
    @Published public private(set) var lastStatus: String?

    public let hooks: BugReporterHooks
    public let options: BugReporterOptions
    public let writer: BugReportWriter
    /// Retained across report sheets; cancellation invalidates old permission and service callbacks.
    public private(set) lazy var dictation = NoteDictation(
      logger: hooks.logger, providerFactory: hooks.dictationProvider,
      hostMicrophoneBusy: hooks.microphoneBusy)
    /// Saves reports the app makes by itself; see `autoReport`.
    public private(set) lazy var auto = BugAutoReporter(writer: writer, options: options.auto)

    /// Saves a report without a dialog or a screenshot, when the app's own check says something went wrong. The
    /// screen and session log come from the hooks; `files` (a big log) are copied in within `options.auto.maxBytes`.
    /// At most one report per reason per `options.auto.window`; a skip is logged as `bug_report_auto_skipped`.
    public func autoReport(reason: String, context: [String: JSONValue] = [:], files: [URL] = []) {
      hooks.flushLog()
      let auto = auto, screen = hooks.screen(), log = hooks.sessionLog()
      Task { await auto.report(reason: reason, screen: screen, context: context, files: files, log: log) }
    }

    /// Set false to ignore shakes (EA's instrumented run, story 037: a phone in a pocket shakes).
    public var shakeEnabled = true
    private var screen = ""
    private var diagnostics = BugDiagnosticsSnapshot()
    private var capturedLogPosition: (path: String, tMs: Int)?
    private var breadcrumbs: InteractionBreadcrumbs
    private let diagnosticsStarted = ProcessInfo.processInfo.systemUptime
    private lazy var interactions = InteractionCapture { [weak self] event, fields in
      self?.recordInteraction(event, fields: fields)
    }
    private weak var presented: UIViewController?
    private let dismissWatcher = DismissWatcher()
    private lazy var motion = ShakeMotion { [weak self] peak in
      self?.hooks.logger("shake", ["source": "motion", "peak_g": .double((peak * 100).rounded() / 100)])
      self?.open(from: .shake)
    }

    public init(
      hooks: BugReporterHooks, options: BugReporterOptions = BugReporterOptions(), store: BugStore = BugStore(),
      info: BugAppInfo? = nil, delivery: (any BugReportDelivery)? = nil
    ) {
      self.hooks = hooks
      self.options = options
      self.breadcrumbs = InteractionBreadcrumbs(capacity: options.interactionLimit)
      let device = "\(BugAppInfo.hardwareModel()) \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
      self.writer = BugReportWriter(
        store: store, info: info ?? .fromMainBundle(device: device), logger: hooks.logger,
        copySessionLog: options.copySessionLog, writeReportJSON: options.writeReportJSON, delivery: delivery)
      dismissWatcher.onDismiss = { [weak self] in self?.dismissedBySwipe() }
    }

    /// Captures the screen first, then presents the dialog from the topmost view controller, so it opens over any
    /// sheet, cover or dialog already up instead of replacing it or being swallowed (EA #41, CG #182).
    public func open(from source: BugReportFlow.Source) {
      if source == .shake, !shakeEnabled {
        hooks.logger("bug_report_open", ["source": "shake", "ignored": true])
        return
      }
      guard flow.open(from: source) else {
        hooks.logger("bug_report_open", ["source": .string(source.rawValue), "already_open": true])
        return
      }
      present(source: source)
    }

    private func present(source: BugReportFlow.Source) {
      let window = Self.keyWindow()
      diagnostics = diagnosticsSnapshot(in: window)
      capturedLogPosition = hooks.sessionLog()
      screenshot = options.screenshot { window.map(Self.snapshot) }
      context = hooks.context()
      screen = hooks.screen()
      guard let top = window?.rootViewController.map(Self.topmost) else {
        hooks.logger("error", ["where": "bug_report_open", "message": "no window to present from"])
        flow.cancel()
        return
      }
      let host = UIHostingController(rootView: BugReportSheet(reporter: self))
      host.modalPresentationStyle = .formSheet
      host.presentationController?.delegate = dismissWatcher
      presented = host
      top.present(host, animated: true)
      hooks.logger(
        "bug_report_open",
        [
          "source": .string(source.rawValue), "screen": .string(screen), "screenshot": .bool(screenshot != nil),
          "over": .string(String(describing: type(of: top))),
        ])
    }

    /// "Log it" or "Log it and another". The save runs in a Task; the dialog closes, empties, or (`.recapture`)
    /// closes and reopens over a fresh picture of the screen.
    public func log(another: Bool) {
      guard let note = flow.log(another: another, style: options.another) else { return }
      let png = screenshot?.pngData()
      let screenshotDropped = flow.screenshotDropped
      let screen = screen, context = context, sessionLog = capturedLogPosition
      let diagnostics = diagnostics
      let writer = writer, extra = hooks.extraFiles
      if options.copySessionLog { hooks.flushLog() }
      Task { @MainActor in
        let report = await writer.save(
          note: note, screen: screen, context: context, screenshotPNG: png, log: sessionLog, extraFiles: extra,
          diagnostics: diagnostics, screenshotDropped: screenshotDropped)
        self.lastStatus = report.folder.isEmpty ? "Problem noted in the log only" : "Problem logged. Thanks."
      }
      guard !flow.isPresented else { return }  // keepMoment: the dialog stays, empty
      let host = presented
      presented = nil
      screenshot = nil
      // The next report's picture is of the screen underneath, so it waits for this dialog to be gone.
      host?.dismiss(animated: true) { [weak self] in
        guard let self, self.flow.reopenIfPending() else { return }
        self.present(source: .another)
      }
    }

    /// Remove the image from the current moment; context and other evidence remain attached.
    public func dropScreenshot() {
      guard flow.isPresented, screenshot != nil else { return }
      flow.dropScreenshot()
      screenshot = nil
    }

    public func cancel() {
      hooks.logger("bug_report_cancel", ["saved": .int(flow.savedThisTime)])
      flow.cancel()
      presented?.dismiss(animated: true)
      presented = nil
      screenshot = nil
    }

    /// Runs the simulator hooks once, at launch: `<PREFIX>_BUG` saves reports, `<PREFIX>_SHAKE_AFTER` opens the
    /// dialog. Logs `bug_hook` with what it found.
    public func runLaunchHooks(_ env: [String: String] = ProcessInfo.processInfo.environment) {
      guard let prefix = options.launchHookPrefix else { return }
      let hooks = BugLaunchHooks.parse(env, prefix: prefix)
      guard !hooks.isEmpty else { return }
      self.hooks.logger(
        "bug_hook",
        ["notes": .int(hooks.notes.count), "bug_after": .double(hooks.bugAfter),
         "shake_after": hooks.shakeAfter.map(JSONValue.double) ?? .null])
      if let after = hooks.shakeAfter {
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(after))
          self.open(from: .hook)
        }
      }
      guard !hooks.notes.isEmpty else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(hooks.bugAfter))  // allow the app to finish loading its target screen
        let png = self.options.screenshot { Self.keyWindow().map(Self.snapshot)?.pngData() }
        let diagnostics = self.diagnosticsSnapshot(in: Self.keyWindow())
        if self.options.copySessionLog { self.hooks.flushLog() }
        for note in hooks.notes {
          _ = await self.writer.save(
            note: note, screen: self.hooks.screen(), context: self.hooks.context(), screenshotPNG: png,
            log: self.hooks.sessionLog(), extraFiles: self.hooks.extraFiles, diagnostics: diagnostics)
        }
      }
    }

    /// The gentle shake runs only while the scene is active (the `.bugReporting` modifier calls this).
    func sceneActive(_ active: Bool) {
      recordInteraction("ui_scene", fields: ["active": .bool(active)])
      if options.recordInteractions {
        if active, let window = Self.keyWindow() { interactions.start(in: window) }
        else { interactions.stop() }
      }
      if options.gentleShake {
        if active { motion.start() } else { motion.stop() }
      }
    }

    /// Add semantic actions for custom SwiftUI controls, keyboard shortcuts or accessibility activation.
    /// Automatic touch breadcrumbs describe physical input; they cannot identify every virtual SwiftUI action.
    public func recordInteraction(_ action: String, fields: [String: JSONValue] = [:]) {
      guard options.recordInteractions else { return }
      var fields = fields
      fields["screen"] = .string(hooks.screen())
      let t = hooks.sessionLog()?.tMs ?? Int((ProcessInfo.processInfo.systemUptime - diagnosticsStarted) * 1_000)
      breadcrumbs.record(action, tMs: t, fields: fields)
      hooks.logger(action, fields)
    }

    private func diagnosticsSnapshot(in window: UIWindow?) -> BugDiagnosticsSnapshot {
      BugDiagnosticsSnapshot(
        interactions: options.recordInteractions ? breadcrumbs.jsonLines : nil,
        accessibility: options.captureAccessibility ? window.map { AccessibilitySnapshot.capture($0) } : nil)
    }

    private func dismissedBySwipe() {
      guard flow.isPresented else { return }
      hooks.logger("bug_report_cancel", ["saved": .int(flow.savedThisTime), "swipe": true])
      flow.cancel()
      presented = nil
      screenshot = nil
    }

    static func keyWindow() -> UIWindow? {
      let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
      return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    static func snapshot(_ window: UIWindow) -> UIImage {
      UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
      }
    }

    /// The view controller on top of every presented one: present from here, or UIKit refuses (or, with SwiftUI's
    /// `.sheet` on the root, swaps out the sheet that is up).
    public static func topmost(_ root: UIViewController) -> UIViewController {
      var top = root
      while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
      return top
    }
  }

  /// Swipe-to-dismiss on the sheet counts as Cancel.
  @MainActor
  private final class DismissWatcher: NSObject, UIAdaptivePresentationControllerDelegate {
    var onDismiss: (() -> Void)?
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss?() }
  }

  /// Feeds Core Motion's user acceleration to `ShakeGesture` at 50 Hz. The gesture's state is touched only on the
  /// motion queue (one operation at a time).
  final class ShakeMotion: @unchecked Sendable {
    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private var gesture = ShakeGesture()
    private let onShake: @MainActor (Double) -> Void

    init(onShake: @escaping @MainActor (Double) -> Void) {
      self.onShake = onShake
      queue.maxConcurrentOperationCount = 1
    }

    func start() {
      guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
      motion.deviceMotionUpdateInterval = 1.0 / 50
      motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
        guard let self, let data else { return }
        let a = data.userAcceleration
        if let peak = self.gesture.feed(x: a.x, y: a.y, z: a.z, t: data.timestamp) {
          let onShake = self.onShake
          Task { @MainActor in onShake(peak) }
        }
      }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
  }

  /// The dialog: a note (typed or spoken), the screenshot, what is attached, and "Log it" / "Log it and another".
  @available(iOSApplicationExtension, unavailable)
  public struct BugReportSheet: View {
    @ObservedObject var reporter: BugReporter
    @ObservedObject private var dictation: NoteDictation
    @FocusState private var noteFocused: Bool

    public init(reporter: BugReporter) {
      self.reporter = reporter
      _dictation = ObservedObject(wrappedValue: reporter.dictation)
    }

    public var body: some View {
      NavigationStack {
        Form {
          Section("What went wrong?") {
            HStack(alignment: .top, spacing: 10) {
              TextField(reporter.options.placeholder, text: $reporter.flow.note, axis: .vertical)
                .lineLimit(3...8)
                .focused($noteFocused)
                .id(reporter.flow.draft)
                .accessibilityIdentifier("report-note")
              if reporter.options.dictation { micButton }
            }
            if dictation.listening {
              Text("Listening… tap stop when done").font(.footnote).foregroundStyle(.secondary)
            }
            if dictation.starting || dictation.processing {
              HStack {
                ProgressView()
                Text(dictation.starting ? "Starting voice input…" : "Finishing voice input…")
              }.font(.footnote).foregroundStyle(.secondary)
            }
            if reporter.options.dictation { microphonePicker }
            if let problem = dictation.problem {
              if reporter.options.copyableErrors {
                BugProblemView(
                  problem: BugProblem(
                    message: problem, context: "BugReportSheet.dictation", build: reporter.writer.info.buildLine,
                    extra: dictation.problemState.merging(["mic_busy": .bool(reporter.hooks.microphoneBusy())]) {
                      a, _ in a
                    }),
                  logger: reporter.hooks.logger)
              } else {
                Text(problem).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
              }
            }
            if reporter.flow.savedThisTime > 0 {
              Text("\(reporter.flow.savedThisTime) logged from this moment").font(.footnote).foregroundStyle(.secondary)
            }
            // Under the note too, so it is above the keyboard (a bottom bar sits behind it; CG story 142).
            Button("Log it and another") { logIt(another: true) }
              .disabled(!reporter.flow.canLog || dictation.starting || dictation.processing)
              .accessibilityIdentifier("report-log-it-and-another")
          }
          Section {
            if let shot = reporter.screenshot {
              Image(uiImage: shot).resizable().scaledToFit().frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("The screen as it was")
                .overlay(alignment: .topTrailing) {
                  Button(action: reporter.dropScreenshot) {
                    Image(systemName: "xmark.circle.fill")
                      .font(.title2).symbolRenderingMode(.palette)
                      .foregroundStyle(.white, .black.opacity(0.75))
                      .frame(width: 44, height: 44)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Remove screenshot")
                  .accessibilityIdentifier("report-remove-screenshot")
                }
            }
            ForEach(reporter.context.sorted(by: { $0.key < $1.key }), id: \.key) { item in
              LabeledContent(item.key, value: item.value.display)
            }
          } header: {
            Text("Attached automatically")
          } footer: {
            if let note = reporter.options.privacyNote { Text(note) }
          }
        }
        .navigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              dictation.stop(why: "cancel")
              reporter.cancel()
            }
            .keyboardShortcut(reporter.options.dialogKeys ? .cancelAction : nil)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Log it") { logIt(another: false) }
              .disabled(!reporter.flow.canLog || dictation.starting || dictation.processing)
              .keyboardShortcut(reporter.options.dialogKeys ? KeyboardShortcut(.return, modifiers: .command) : nil)
              .accessibilityIdentifier("report-log-it")
          }
        }
        .background {
          if reporter.options.dialogKeys {
            Button("Log it and another") { logIt(another: true) }
              .keyboardShortcut(.return, modifiers: [.command, .shift])
              .disabled(!reporter.flow.canLog || dictation.starting || dictation.processing)
              .opacity(0)
              .accessibilityHidden(true)
          }
        }
        .onAppear {
          noteFocused = true
        }
        .onDisappear { dictation.stop(why: "closed") }  // a swipe down
      }
    }

    private var micButton: some View {
      let busy = reporter.hooks.microphoneBusy()
      return Button {
        dictation.toggle(note: reporter.flow.note) { reporter.flow.note = $0 }
      } label: {
        Image(systemName: dictation.listening ? "stop.circle.fill" : "mic.circle.fill")
          .font(.title)
          .symbolEffect(.pulse, isActive: dictation.listening)
          .foregroundStyle(dictation.listening ? Color.red : Color.accentColor)
      }
      .buttonStyle(.borderless)
      .disabled((busy && !dictation.listening) || dictation.starting || dictation.processing)
      .accessibilityLabel(
        dictation.listening ? "Stop dictating" : busy ? "Dictation is off while the microphone is in use" : "Speak the note")
      .accessibilityIdentifier("report-dictate")
    }

    private var microphonePicker: some View {
      Menu {
        Button { dictation.selectMicrophone(nil) } label: {
          if dictation.selectedMicrophoneID == nil { Label("Automatic", systemImage: "checkmark") }
          else { Text("Automatic") }
        }
        ForEach(dictation.microphones) { microphone in
          Button { dictation.selectMicrophone(microphone.id) } label: {
            if dictation.selectedMicrophoneID == microphone.id { Label(microphone.name, systemImage: "checkmark") }
            else { Text(microphone.name) }
          }
        }
        Button("Refresh microphones") {
          Task { await dictation.refreshMicrophones() }
        }
      } label: {
        LabeledContent("Microphone", value: dictation.selectedMicrophoneName)
      }
      .disabled(dictation.busy || reporter.hooks.microphoneBusy())
      .accessibilityLabel("Microphone: \(dictation.selectedMicrophoneName)")
      .accessibilityIdentifier("report-microphone-picker")
    }

    private func logIt(another: Bool) {
      if !dictation.busy {
        reporter.log(another: another)
        if another { noteFocused = true }
        return
      }
      let draft = reporter.flow.draft
      Task { @MainActor in
        guard await dictation.finish(why: "log_it"), reporter.flow.isPresented,
              reporter.flow.draft == draft else { return }
        reporter.log(another: another)
        if another { noteFocused = true }
      }
    }
  }

  /// For when shaking is awkward (an iPad on a stand, a phone on a tripod).
  @available(iOSApplicationExtension, unavailable)
  public struct BugReportButton: View {
    @ObservedObject var reporter: BugReporter
    let title: String

    public init(_ title: String = "Report a problem", reporter: BugReporter) {
      self.title = title; self.reporter = reporter
    }

    public var body: some View {
      Button { reporter.open(from: .button) } label: { Label(title, systemImage: "ladybug") }
    }
  }

  /// Calls `onShake` on iOS's own shake gesture. Sits invisibly in the view tree and holds first responder.
  public struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    public init(onShake: @escaping () -> Void) { self.onShake = onShake }

    public final class Controller: UIViewController {
      var onShake: (() -> Void)?
      override public var canBecomeFirstResponder: Bool { true }
      override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
      }
      override public func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() }
        super.motionEnded(motion, with: event)
      }
    }

    public func makeUIViewController(context: Context) -> Controller {
      let controller = Controller()
      controller.onShake = onShake
      controller.view.isUserInteractionEnabled = false
      return controller
    }

    public func updateUIViewController(_ controller: Controller, context: Context) {
      controller.onShake = onShake
    }
  }

  @available(iOSApplicationExtension, unavailable)
  private struct BugReporting: ViewModifier {
    @ObservedObject var reporter: BugReporter
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
      content
        .background {
          ZStack {
            if reporter.options.systemShake {
              ShakeDetector {
                reporter.hooks.logger("shake", ["source": "system"])
                reporter.open(from: .shake)
              }
            }
            if reporter.options.commandI {
              Button("Report a problem") { reporter.open(from: .key) }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
            }
          }
          .frame(width: 0, height: 0)
        }
        .onAppear { reporter.sceneActive(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in reporter.sceneActive(phase == .active) }
    }
  }

  extension View {
    /// A shake (hard or, with `gentleShake`, gentle) or ⌘I opens the report dialog.
    @available(iOSApplicationExtension, unavailable)
    public func bugReporting(_ reporter: BugReporter) -> some View {
      modifier(BugReporting(reporter: reporter))
    }
  }
#endif
