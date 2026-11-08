import Foundation

/// The microphone as `NoteDictation` sees it: the system's (`AVDictationCapture`, iOS) or a test's.
@MainActor
protocol DictationCapture: AnyObject {
  var onFailure: (@MainActor (String) -> Void)? { get set }
  var currentInputID: String? { get }
  func availableMicrophones() throws -> [BugMicrophone]
  func start(preferredInputID: String?) throws -> AsyncStream<Data>
  func stop()
  func restore()
}

#if canImport(UIKit) && os(iOS)
import AVFoundation

@MainActor
final class AVDictationCapture: DictationCapture {
  var onFailure: (@MainActor (String) -> Void)?
  var currentInputID: String? { AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid }
  private let logger: BugLogger
  private var engine = AVAudioEngine()
  private var tapInstalled = false
  private var generation = UUID()
  private var audio: AsyncStream<Data>.Continuation?
  private var saved: SessionState?
  private var inputAtStart: String?
  private var startedAt = 0.0
  private let observations = DictationObservations()

  private struct SessionState {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let preferred: AVAudioSessionPortDescription?
    init(_ session: AVAudioSession) {
      category = session.category; mode = session.mode; options = session.categoryOptions
      preferred = session.preferredInput
    }
    func restore(_ session: AVAudioSession, deactivate: Bool) throws {
      let inputCategories: [AVAudioSession.Category] = [.playAndRecord, .record, .multiRoute]
      if inputCategories.contains(session.category), !inputCategories.contains(category) {
        try session.setPreferredInput(nil)
      }
      try session.setCategory(category, mode: mode, options: options)
      if category == .playAndRecord || category == .record || category == .multiRoute {
        let input = preferred.flatMap { preferred in session.availableInputs?.first { $0.uid == preferred.uid } }
        try session.setPreferredInput(input)
      }
      if deactivate, category == .ambient || category == .soloAmbient {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
      }
    }

    func restoreAfterDiscovery(_ session: AVAudioSession, activated: Bool) throws {
      if activated, !AVDictationCapture.keepsDiscoveryActivation(category: category, options: options) {
        // Release our temporary mixing session before restoring a non-mixing or ducking/
        // interrupting category, so an inactive host cannot acquire exclusive audio just by listing inputs.
        // Explicit Refresh may stop a non-mixing host's I/O; do not discard the inputs
        // when AVAudioSession reports that its I/O was busy during deactivation.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
      }
      try restore(session, deactivate: false)
    }
  }

  /// Only hosts that mix without ducking or interrupting others may keep discovery's activation.
  /// `contains`, not `intersection`: interruptSpokenAudioAndMixWithOthers shares mixWithOthers' bit.
  nonisolated static func keepsDiscoveryActivation(
    category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions
  ) -> Bool {
    DictationRules.keepsDiscoveryActivation(
      ambient: category == .ambient, mixesWithOthers: options.contains(.mixWithOthers),
      ducksOthers: options.contains(.duckOthers),
      interruptsSpokenAudio: options.contains(.interruptSpokenAudioAndMixWithOthers))
  }

  init(logger: @escaping BugLogger) {
    self.logger = logger
    observations.add(NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.tapInstalled,
              ProcessInfo.processInfo.systemUptime - self.startedAt > 0.5,
              self.currentInputID != self.inputAtStart else { return }
        self.onFailure?("The microphone changed. Dictation stopped; your note is still here.")
      }
    })
    observations.add(NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.tapInstalled, !self.engine.isRunning else { return }
        self.onFailure?("The microphone stopped. Your note is still here.")
      }
    })
    observations.add(NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
      Task { @MainActor in
        guard let self, self.tapInstalled else { return }
        self.onFailure?("The microphone was interrupted. Your note is still here.")
      }
    })
  }

  private func configure(_ session: AVAudioSession) throws {
    try session.setCategory(.playAndRecord, mode: .default,
      options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
  }

  func availableMicrophones() throws -> [BugMicrophone] {
    let session = AVAudioSession.sharedInstance()
    let before = SessionState(session)
    var activated = false
    do {
      try configure(session)
      try session.setActive(true)
      activated = true
      let inputs = (session.availableInputs ?? []).map {
        BugMicrophone(id: $0.uid, name: $0.portName, kind: $0.portType.rawValue)
      }
      try before.restoreAfterDiscovery(session, activated: activated)
      return inputs
    } catch {
      try? before.restoreAfterDiscovery(session, activated: activated)
      throw error
    }
  }

  func start(preferredInputID: String?) throws -> AsyncStream<Data> {
    stop(); restore()
    let session = AVAudioSession.sharedInstance()
    saved = SessionState(session)
    do {
      try configure(session)
      try session.setActive(true)
      let preferred = session.availableInputs?.first { $0.uid == preferredInputID }
      if preferredInputID != nil, preferred == nil { throw CaptureError.microphoneUnavailable }
      try session.setPreferredInput(preferred)
      engine = AVAudioEngine()
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noAudioFormat }
      let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(32))
      let encoder = try DictationPCMEncoder(input: format)
      audio = continuation
      let owner = UUID(); generation = owner
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
        guard let data = encoder.encode(buffer) else { return }
        if case .dropped = continuation.yield(data) {
          continuation.finish()
          Task { @MainActor in
            guard let self, self.generation == owner else { return }
            self.onFailure?(DictationProviderError.audioOverflow.localizedDescription)
          }
        }
      }
      tapInstalled = true
      engine.prepare()
      try engine.start()
      inputAtStart = currentInputID
      startedAt = ProcessInfo.processInfo.systemUptime
      return stream
    } catch { stop(); restore(); throw error }
  }

  func stop() {
    generation = UUID()
    if engine.isRunning { engine.stop() }
    if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
    tapInstalled = false
    audio?.finish(); audio = nil
  }

  func restore() {
    guard let saved else { return }
    self.saved = nil
    do { try saved.restore(AVAudioSession.sharedInstance(), deactivate: true) }
    catch { logger("error", ["where": "dictation_restore", "message": "Audio session settings could not be restored"]) }
  }

  private enum CaptureError: Error {
    case microphoneUnavailable, noAudioFormat
  }
}

/// Accessed only by the serial audio tap, which converts before transferring owned Data across actors.
private final class DictationPCMEncoder: @unchecked Sendable {
  private let format: AVAudioFormat
  private let converter: AVAudioConverter
  init(input: AVAudioFormat) throws {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                    channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: input, to: format) else { throw DictationProviderError.invalidResponse }
    self.format = format; self.converter = converter
  }
  func encode(_ input: AVAudioPCMBuffer) -> Data? {
    let count = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if fed { status.pointee = .noDataNow; return nil }
      fed = true; status.pointee = .haveData; return input
    }
    guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return nil }
    return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
  }
}

private final class DictationObservations: @unchecked Sendable {
  private var tokens: [NSObjectProtocol] = []
  func add(_ token: NSObjectProtocol) { tokens.append(token) }
  deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
#endif
