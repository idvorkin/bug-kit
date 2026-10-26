import Foundation

/// How dictated words join what was typed (CG #239): after it, with one space; nothing typed, just the words.
public enum DictationText {
  public static func merge(before: String, spoken: String) -> String {
    let typed = before.trimmingCharacters(in: .whitespacesAndNewlines)
    return typed.isEmpty ? spoken : "\(typed) \(spoken)"
  }
}

/// Speaking after a pause adds to the note, never replaces it (CG #249: "when I stop talking the input gets
/// replaced"). The recogniser can start a fresh transcription after a pause (on-device recognition does), each
/// result then holding only the new stretch of speech. The note is what was typed, then every finished stretch, then
/// the one being heard. Whether a restart after a pause is the cause is what `dictation_pause` is there to show.
public struct DictationJoin: Equatable, Sendable {
  /// What was typed when listening began, then every finished stretch of speech.
  public var kept: String { completed.reduce(typed) { Self.join($0, $1.text) } }
  /// The stretch being heard now, as the recogniser last gave it.
  public private(set) var current = ""
  private var currentStart: Double?
  private var currentObservedAudioEnd: Double?
  private let typed: String
  /// Finished stretches with their clock range; an untimed stretch ends at the audio submitted before it.
  private var completed: [Stretch] = []
  /// When the stretch being heard last ended, in seconds from the start of listening.
  public private(set) var currentEnd: Double = 0

  public init(typed: String) {
    self.typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The whole note so far.
  public var note: String { Self.join(kept, current) }

  /// One result from the recogniser: its text and when its first and last words were spoken, in seconds from the
  /// start of listening. Pass isFinal for the recognizer's final result so text corrections do not look
  /// like a restarted partial. observedAudioEnd is the duration of audio already submitted when this
  /// result is observed; it bounds an untimed transcript. Without either word timing or this bound,
  /// results are treated as revisions. Returns true when a new stretch begins.
  @discardableResult
  public mutating func update(text: String, firstStart: Double, lastEnd: Double, isFinal: Bool = false, observedAudioEnd: Double? = nil) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Empty terminal results carry no replacement words.
    guard !text.isEmpty else { return false }
    var fresh = false
    var after = false
    if let start = currentStart, !current.isEmpty, !text.isEmpty {
      // A result outside the prior timed interval is new speech. A shorter non-final result on a
      // reset clock preserves the existing on-device pause/restart behavior.
      // On-device partials can report zero-duration segments until their timing is revised. A later
      // timestamp alone cannot prove new speech if the earlier stretch never had a valid duration.
      let timed = currentEnd > start
      if timed {
        after = firstStart >= currentEnd - 0.05 && firstStart > start
      } else if let bound = currentObservedAudioEnd, bound > start {
        // All previously recognized words must lie within the submitted audio. A revised start
        // inside that audio is not evidence of a new stretch, even if the first word changes.
        after = firstStart >= bound && firstStart > start
      }
      let restarted = !isFinal && timed
        && text.count < current.count && Self.firstWord(text) != Self.firstWord(current)
      fresh = after || restarted
    }
    // A final transcript may revise the completed stretches as well as the current one. When it reaches
    // the current end from before the current start, and every stretch so far lies in order on one clock,
    // it replaces the stretches it overlaps; earlier untouched ones stay. After a clock reset or without
    // ranges the overlap is ambiguous, so completed speech is kept and the final revises the current stretch.
    if isFinal, !after, let start = currentStart, firstStart < start, lastEnd >= currentEnd - 0.05,
       Self.ordered(completed + [Stretch(text: current, start: start, end: max(currentEnd, start))]),
       let covered = completed.firstIndex(where: { $0.end > firstStart }) {
      completed.removeSubrange(covered...)
    }
    if fresh, let start = currentStart {
      completed.append(Stretch(text: current, start: start,
        end: currentEnd > start ? currentEnd : currentObservedAudioEnd ?? start))
    }
    current = text
    currentStart = firstStart
    currentEnd = lastEnd
    currentObservedAudioEnd = observedAudioEnd
    return fresh
  }

  private struct Stretch: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
  }

  private static func ordered(_ stretches: [Stretch]) -> Bool {
    zip(stretches, stretches.dropFirst()).allSatisfy { $0.end > $0.start && $1.start >= $0.end - 0.05 }
  }

  private static func join(_ a: String, _ b: String) -> String {
    a.isEmpty ? b : b.isEmpty ? a : "\(a) \(b)"
  }

  private static func firstWord(_ s: String) -> Substring {
    s.split(separator: " ").first.map { $0.lowercased()[...] } ?? ""
  }
}

#if canImport(UIKit) && os(iOS)
  import AVFoundation
  import Combine
  import Speech

  /// Dictates through Apple Speech by default, or an app-supplied streaming provider.
  /// Microphone picks apply to the next dictation. Stop/Log it drains final words; cancel discards late callbacks.
  @MainActor
  public final class NoteDictation: ObservableObject {
    @Published public private(set) var listening = false {
      didSet { if !listening { meter.reset(); inputLevel = 0 } }
    }
    /// How loud the microphone is while listening: 0 (silence) to 1 (full scale), smoothed and updated about 20
    /// times a second. 0 whenever not listening. `BugInputLevelMeter` draws it.
    @Published public private(set) var inputLevel = 0.0
    @Published public private(set) var starting = false
    @Published public private(set) var refreshingMicrophones = false
    @Published public private(set) var processing = false
    @Published public private(set) var problem: String?
    @Published public private(set) var problemState: [String: JSONValue] = [:]
    @Published public private(set) var microphones: [BugMicrophone] = []
    @Published public private(set) var selectedMicrophoneID: String?

    public var busy: Bool { starting || listening || processing || refreshingMicrophones }
    public var selectedMicrophoneName: String {
      microphones.first { $0.id == selectedMicrophoneID }?.name
        ?? (selectedMicrophoneID == nil ? "Automatic" : "Saved microphone")
    }
    private static let microphoneKey = "bugkit.dictation_microphone"
    private let logger: BugLogger
    private let factory: @MainActor @Sendable () -> any BugDictationProvider
    private let capture: any DictationCapture
    private let permissions: DictationPermissions
    private let defaults: UserDefaults
    let hostMicrophoneBusy: @MainActor () -> Bool
    private var meter = DictationLevel()
    private var provider: (any BugDictationProvider)?
    private var startTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var finishTask: Task<Bool, Never>?
    private var owner = UUID()
    private var typed = ""
    private var onText: (@MainActor @Sendable (String) -> Void)?

    public convenience init(logger: @escaping BugLogger,
      providerFactory: (@MainActor @Sendable () -> any BugDictationProvider)? = nil,
      defaults: UserDefaults = .standard,
      hostMicrophoneBusy: @escaping @MainActor () -> Bool = { false }) {
      self.init(logger: logger, providerFactory: providerFactory ?? { AppleDictationProvider(logger: logger) },
                capture: AVDictationCapture(logger: logger), permissions: .system, defaults: defaults,
                hostMicrophoneBusy: hostMicrophoneBusy)
    }

    init(logger: @escaping BugLogger, providerFactory: @escaping @MainActor @Sendable () -> any BugDictationProvider,
         capture: any DictationCapture, permissions: DictationPermissions, defaults: UserDefaults,
         hostMicrophoneBusy: @escaping @MainActor () -> Bool = { false }) {
      self.logger = logger; self.factory = providerFactory; self.capture = capture
      self.permissions = permissions; self.defaults = defaults
      self.hostMicrophoneBusy = hostMicrophoneBusy
      selectedMicrophoneID = defaults.string(forKey: Self.microphoneKey)
      capture.onFailure = { [weak self] message in
        guard let self, self.listening else { return }
        self.fail(message, ["where": "audio_route"])
        Task { _ = await self.finish(why: "input_lost") }
      }
    }

    /// Refreshes iOS inputs without recording. Category/mode/options/preferred input are restored afterward.
    /// Skipped while the host records, because listing inputs reconfigures the shared audio session.
    /// `hostMicrophoneBusy` is checked live: again after the permission prompt, right before listing.
    public func refreshMicrophones() async {
      guard !busy, !hostMicrophoneBusy() else { return }
      let generation = owner
      refreshingMicrophones = true
      defer { if owner == generation { refreshingMicrophones = false } }
      let granted = await permissions.microphone()
      guard owner == generation, !Task.isCancelled else { return }
      refreshingMicrophones = false
      guard granted else { fail("The microphone is off for this app (Settings)", ["mic": "denied"]); return }
      guard !hostMicrophoneBusy() else { return }
      do {
        microphones = try capture.availableMicrophones()
        if let selectedMicrophoneID, !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
          selectMicrophone(nil)
          logger("dictation_input_unavailable", [:])
        }
      } catch { fail("Microphones could not be listed", ["where": "inputs"]) }
    }

    public func selectMicrophone(_ id: String?) {
      guard !busy, id == nil || microphones.contains(where: { $0.id == id }) else { return }
      selectedMicrophoneID = id
      defaults.set(id, forKey: Self.microphoneKey)
      logger("dictation_input_selected", ["input": id.map(JSONValue.string) ?? .null])
    }

    public func toggle(note: String, onText: @escaping @MainActor @Sendable (String) -> Void) {
      if listening { Task { _ = await finish(why: "tap") } }
      else if !busy, !hostMicrophoneBusy() { start(note: note, onText: onText) }
    }

    private func start(note: String, onText: @escaping @MainActor @Sendable (String) -> Void) {
      problem = nil; problemState = [:]
      owner = UUID()
      let generation = owner
      typed = note; self.onText = onText
      let backend = factory()
      provider = backend
      starting = true
      startTask = Task { [weak self] in
        guard let self else { return }
        do {
          if backend.requiresSpeechAuthorization, !(await self.permissions.speech()) {
            throw DictationPermissionError.speech
          }
          try Task.checkCancellation()
          guard await self.permissions.microphone() else { throw DictationPermissionError.microphone }
          try Task.checkCancellation()
          guard self.owner == generation else { return }
          guard !self.hostMicrophoneBusy() else { throw DictationPermissionError.microphoneBusy }
          let results = try await backend.start()
          try Task.checkCancellation()
          guard self.owner == generation else { await backend.cancel(); return }
          let onDevice = await backend.onDeviceRecognition
          try Task.checkCancellation()
          guard self.owner == generation else { await backend.cancel(); return }
          guard !self.hostMicrophoneBusy() else { throw DictationPermissionError.microphoneBusy }
          let audio = try self.capture.start(preferredInputID: self.selectedMicrophoneID)
          self.starting = false; self.listening = true
          self.logger("dictation_start", ["provider": .string(backend.name),
            "input": self.capture.currentInputID.map(JSONValue.string) ?? .null,
            "on_device": onDevice.map(JSONValue.bool) ?? .null])
          self.audioTask = Task { [weak self] in
            do {
              for await chunk in audio {
                try Task.checkCancellation()
                self?.hear(chunk, generation)
                try await backend.appendAudio(chunk)
              }
            } catch {
              guard let self, self.owner == generation, !Task.isCancelled else { return }
              self.fail("Speech recognition stopped receiving audio", ["where": "audio_send"])
              self.stop(why: "error")
            }
          }
          self.resultTask = Task { [weak self] in
            do {
              for try await spoken in results {
                guard let self, self.owner == generation, !Task.isCancelled else { return }
                self.onText?(DictationText.merge(before: self.typed, spoken: spoken))
              }
              if let self, self.owner == generation, self.listening { self.stop(why: "final") }
            } catch {
              guard let self, self.owner == generation, !Task.isCancelled else { return }
              self.fail("The speech service stopped unexpectedly", ["where": "recognizer"])
              self.stop(why: "error")
            }
          }
        } catch {
          guard self.owner == generation, !Task.isCancelled else { await backend.cancel(); return }
          let message = (error as? DictationPermissionError)?.localizedDescription ?? "Voice input could not start"
          self.fail(message, ["where": "start", "provider": .string(backend.name)])
          self.stop(why: "error")
        }
      }
    }

    /// Stop capturing and wait for the provider's final words. Concurrent callers share one finish operation.
    /// Returns false after a failure or cancellation; a save should then leave the dialog open for retry.
    @discardableResult
    public func finish(why: String) async -> Bool {
      if let finishTask { return await finishTask.value }
      guard !starting else { stop(why: why); return false }
      guard let backend = provider else { return !processing }
      let generation = owner
      listening = false; processing = true
      capture.stop(); capture.restore()
      let sender = audioTask, results = resultTask
      let work = Task { [weak self] () -> Bool in
        do {
          await sender?.value
          try Task.checkCancellation()
          try await backend.finish()
          await results?.value
          guard let self, self.owner == generation, !Task.isCancelled else { return false }
          self.complete(why: why)
          return true
        } catch {
          guard let self, self.owner == generation, !Task.isCancelled else { return false }
          self.fail("Speech recognition could not finish. Your note is still here.", ["where": "finish"])
          self.stop(why: "error")
          return false
        }
      }
      finishTask = work
      let timeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(10))
        guard let self, !Task.isCancelled, self.owner == generation, self.processing else { return }
        self.fail("Speech recognition took too long. Your note is still here.", ["where": "finish_timeout"])
        self.stop(why: "timeout")
      }
      let success = await work.value
      timeout.cancel()
      if owner == generation { finishTask = nil }
      return success
    }

    /// Cancel/close stops immediately, invalidates permission/network callbacks, and preserves the current note.
    public func stop(why: String) {
      let wasBusy = busy
      owner = UUID()
      startTask?.cancel(); startTask = nil
      audioTask?.cancel(); audioTask = nil
      resultTask?.cancel(); resultTask = nil
      finishTask?.cancel(); finishTask = nil
      capture.stop(); capture.restore()
      let backend = provider; provider = nil
      Task { await backend?.cancel() }
      listening = false; starting = false; processing = false; refreshingMicrophones = false; onText = nil
      if wasBusy { logger("dictation_stop", ["why": .string(why)]) }
    }

    private func hear(_ chunk: Data, _ generation: UUID) {
      guard owner == generation, listening,
            let level = meter.hear(pcm16: chunk, at: ProcessInfo.processInfo.systemUptime) else { return }
      inputLevel = level
    }

    private func complete(why: String) {
      provider = nil; audioTask = nil; resultTask = nil; onText = nil
      listening = false; starting = false; processing = false
      logger("dictation_stop", ["why": .string(why)])
    }

    private func fail(_ message: String, _ fields: [String: JSONValue]) {
      problem = message; problemState = fields
      logger("dictation_error", fields.merging(["message": .string(message)]) { first, _ in first })
    }
  }

  struct DictationPermissions {
    var speech: @MainActor () async -> Bool
    var microphone: @MainActor () async -> Bool
    static let system = Self(
      speech: { await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
      } },
      microphone: { await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
      } })
  }

  private enum DictationPermissionError: Error, LocalizedError {
    case speech, microphone, microphoneBusy
    var errorDescription: String? {
      switch self {
      case .speech: "Speech recognition is off for this app (Settings)"
      case .microphone: "The microphone is off for this app (Settings)"
      case .microphoneBusy: "The microphone is in use by this app"
      }
    }
  }
#endif
