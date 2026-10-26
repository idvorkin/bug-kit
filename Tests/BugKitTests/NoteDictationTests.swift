#if canImport(UIKit) && os(iOS)
import AVFoundation
import Foundation
import Testing
@testable import BugKit

@MainActor
@Test func dictationCustomProviderSkipsSpeechPermissionAndUsesSelectedMicrophone() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  await fixture.dictation.refreshMicrophones()
  fixture.dictation.selectMicrophone("usb")
  fixture.dictation.toggle(note: "typed") { fixture.note.value = $0 }
  try await fixture.until { fixture.dictation.listening }
  #expect(fixture.permissions.speech == 0)
  #expect(fixture.capture.preferred == "usb")
  await fixture.provider.emit("spoken")
  try await fixture.until { fixture.note.value == "typed spoken" }
  let saved = await fixture.dictation.finish(why: "log_it")
  #expect(saved)
  #expect(fixture.note.value == "typed spoken final")
  #expect(!fixture.dictation.busy)
  #expect(fixture.capture.restores > 0)
}

@MainActor
@Test func dictationCancelWhilePermissionPendingCannotStartLater() async throws {
  let gate = MicrophonePermissionGate()
  let fixture = try DictationFixture(microphone: { await gate.wait() })
  defer { fixture.cleanup() }
  fixture.dictation.toggle(note: "typed") { fixture.note.value = $0 }
  try await fixture.until { gate.waiting }
  fixture.dictation.stop(why: "closed")
  gate.release()
  try await Task.sleep(for: .milliseconds(30))
  #expect(await fixture.provider.starts == 0)
  #expect(fixture.capture.starts == 0)
  #expect(!fixture.dictation.busy)
  #expect(fixture.note.value == "")
}

@MainActor
@Test func dictationFailureRestoresCaptureAndKeepsNote() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  fixture.dictation.toggle(note: "typed") { fixture.note.value = $0 }
  try await fixture.until { fixture.dictation.listening }
  await fixture.provider.emit("spoken")
  try await fixture.until { fixture.note.value == "typed spoken" }
  await fixture.provider.fail()
  try await fixture.until { !fixture.dictation.busy }
  #expect(fixture.note.value == "typed spoken")
  #expect(fixture.dictation.problem != nil)
  #expect(fixture.capture.restores > 0)
}

@MainActor
@Test func dictationRemovedMicrophoneReturnsPickerToAutomatic() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  await fixture.dictation.refreshMicrophones()
  fixture.dictation.selectMicrophone("usb")
  fixture.capture.inputs.removeAll { $0.id == "usb" }
  await fixture.dictation.refreshMicrophones()
  #expect(fixture.dictation.selectedMicrophoneID == nil)
  #expect(fixture.dictation.selectedMicrophoneName == "Automatic")
  #expect(fixture.defaults.string(forKey: "bugkit.dictation_microphone") == nil)
}

@MainActor
@Test func dictationHostRecordingSkipsMicrophoneDiscovery() async throws {
  let host = HostRecording()
  host.busy = true
  let fixture = try DictationFixture(hostMicrophoneBusy: { host.busy })
  defer { fixture.cleanup() }
  await fixture.dictation.refreshMicrophones()
  #expect(fixture.capture.lists == 0)
  #expect(fixture.permissions.microphone == 0)
  #expect(fixture.dictation.microphones.isEmpty)
  host.busy = false
  await fixture.dictation.refreshMicrophones()
  #expect(fixture.permissions.microphone == 1)
  #expect(fixture.capture.lists == 1)
}

@MainActor
@Test func dictationHostRecordingStartedDuringPermissionPromptSkipsDiscovery() async throws {
  let gate = MicrophonePermissionGate()
  let host = HostRecording()
  let fixture = try DictationFixture(microphone: { await gate.wait() }, hostMicrophoneBusy: { host.busy })
  defer { fixture.cleanup() }
  let refresh = Task { await fixture.dictation.refreshMicrophones() }
  try await fixture.until { gate.waiting }
  host.busy = true
  gate.release()
  await refresh.value
  #expect(fixture.permissions.microphone == 1)
  #expect(fixture.capture.lists == 0)
  #expect(fixture.dictation.microphones.isEmpty)
  #expect(!fixture.dictation.refreshingMicrophones)
}

@MainActor
@Test func discoveryKeepsActivationOnlyForPlainMixingHosts() {
  #expect(AVDictationCapture.keepsDiscoveryActivation(category: .playback, options: .mixWithOthers))
  #expect(AVDictationCapture.keepsDiscoveryActivation(category: .ambient, options: []))
  #expect(!AVDictationCapture.keepsDiscoveryActivation(category: .playback, options: [.mixWithOthers, .duckOthers]))
  #expect(!AVDictationCapture.keepsDiscoveryActivation(
    category: .playback, options: .interruptSpokenAudioAndMixWithOthers))
  #expect(!AVDictationCapture.keepsDiscoveryActivation(category: .ambient, options: .duckOthers))
  #expect(!AVDictationCapture.keepsDiscoveryActivation(category: .soloAmbient, options: []))
  #expect(!AVDictationCapture.keepsDiscoveryActivation(category: .playback, options: []))
}

@Test func appleNoSpeechEndsQuietlyOnlyAfterFinish() {
  let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1110)
  let ended = NSError(domain: "kAFAssistantErrorDomain", code: 301)
  let network = NSError(domain: "kAFAssistantErrorDomain", code: 1101)
  #expect(AppleDictationProvider.endsQuietly(noSpeech, finishing: true))
  #expect(AppleDictationProvider.endsQuietly(ended, finishing: true))
  #expect(!AppleDictationProvider.endsQuietly(noSpeech, finishing: false))
  #expect(!AppleDictationProvider.endsQuietly(network, finishing: true))
  #expect(!AppleDictationProvider.endsQuietly(NSError(domain: NSURLErrorDomain, code: 1110), finishing: true))
  #expect(!AppleDictationProvider.endsQuietly(nil, finishing: true))
}

@MainActor
@Test func dictationSavedMicrophoneIsShownBeforeExplicitRefresh() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  await fixture.dictation.refreshMicrophones()
  fixture.dictation.selectMicrophone("usb")
  let reopened = NoteDictation(logger: { _, _ in }, providerFactory: { [provider = fixture.provider] in provider },
    capture: fixture.capture,
    permissions: DictationPermissions(speech: { true }, microphone: { true }),
    defaults: fixture.defaults)
  defer { reopened.stop(why: "test_closed") }
  #expect(reopened.selectedMicrophoneID == "usb")
  #expect(reopened.selectedMicrophoneName == "Saved microphone")
  #expect(reopened.microphones.isEmpty)
  #expect(fixture.capture.lists == 1)
  await reopened.refreshMicrophones()
  #expect(reopened.selectedMicrophoneName == "USB Microphone")
}

@MainActor
@Test func dictationBusyHostSkipsPermissionsAndProviderStart() async throws {
  let fixture = try DictationFixture(hostMicrophoneBusy: { true })
  defer { fixture.cleanup() }
  fixture.dictation.toggle(note: "typed") { fixture.note.value = $0 }
  await fixture.dictation.refreshMicrophones()
  #expect(fixture.permissions.microphone == 0)
  #expect(await fixture.provider.starts == 0)
  #expect(fixture.capture.starts == 0)
  #expect(fixture.capture.lists == 0)
  #expect(!fixture.dictation.busy)
}

@MainActor
@Test func dictationHostRecordingStartedDuringStartupNeverCaptures() async throws {
  for waitForProvider in [false, true] {
    let gate = MicrophonePermissionGate()
    let host = HostRecording()
    let fixture = try DictationFixture(microphone: {
                                        if waitForProvider { return true }
                                        return await gate.wait()
                                      },
                                      hostMicrophoneBusy: { host.busy })
    defer { gate.release(); fixture.cleanup() }
    if waitForProvider { await fixture.provider.holdStart { _ = await gate.wait() } }
    fixture.dictation.toggle(note: "typed") { fixture.note.value = $0 }
    try await fixture.until { gate.waiting }
    host.busy = true
    gate.release()
    try await fixture.until { !fixture.dictation.busy }
    #expect(fixture.capture.starts == 0)
    #expect(await fixture.provider.starts == (waitForProvider ? 1 : 0))
    #expect(fixture.dictation.problem == "The microphone is in use by this app")
    for _ in 0..<100 {
      if await fixture.provider.cancellations > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fixture.provider.cancellations > 0)
  }
}

@MainActor
@Test func dictationFinalRevisionReplacesPartialBeforeFinishReturns() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  fixture.dictation.toggle(note: "Typed:") { fixture.note.value = $0 }
  try await fixture.until { fixture.dictation.listening }
  let words = "I guess settings can be a button now"
  await fixture.provider.emitRecognition(words, firstStart: 0, lastEnd: 0)
  try await fixture.until { fixture.note.value == "Typed: " + words }
  await fixture.provider.setFinalRecognition(words, firstStart: 0.96, lastEnd: 4.1)
  let saved = await fixture.dictation.finish(why: "log_it")
  #expect(saved)
  #expect(fixture.note.value == "Typed: " + words)
  #expect(!fixture.dictation.busy)
}

// #48: Log it is enabled only by `flow.canLog`, and a Log it during dictation saves through `flow.log` after
// `finish`, so a recording that heard nothing or failed cannot save an empty report.
@MainActor
@Test func dictationThatFailsOnAnEmptyNoteCannotSaveAReport() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  var flow = BugReportFlow()
  flow.open(from: .shake)
  fixture.dictation.toggle(note: flow.note) { fixture.note.value = $0 }
  try await fixture.until { fixture.dictation.listening }
  flow.note = fixture.note.value
  #expect(!flow.canLog)
  await fixture.provider.fail()
  try await fixture.until { !fixture.dictation.busy }
  flow.note = fixture.note.value
  #expect(fixture.dictation.problem != nil)
  #expect(flow.log(another: false) == nil)
  #expect(flow.isPresented && flow.savedThisTime == 0)
}

@MainActor
@Test func dictationThatFinishesSilentCannotSaveAReport() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  var flow = BugReportFlow()
  flow.open(from: .shake)
  fixture.dictation.toggle(note: flow.note) { fixture.note.value = $0 }
  try await fixture.until { fixture.dictation.listening }
  await fixture.provider.setFinalRecognition("", firstStart: 0, lastEnd: 0)
  #expect(await fixture.dictation.finish(why: "log_it"))
  flow.note = fixture.note.value
  #expect(flow.log(another: false) == nil)
  #expect(flow.isPresented && flow.savedThisTime == 0)
}

@MainActor
@Test func dictationInputLevelRisesWithSoundAndEmptiesWhenListeningEnds() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  #expect(fixture.dictation.inputLevel == 0)
  fixture.dictation.toggle(note: "") { fixture.note.value = $0 }
  try await fixture.until { fixture.dictation.listening }
  let fullScale = Data((0..<320).flatMap { _ in [UInt8(0xFF), UInt8(0x7F)] })  // Int16.max, little-endian
  // The meter publishes about 20 times a second, so keep sending until a loud buffer is due.
  for _ in 0..<40 where fixture.dictation.inputLevel < 0.9 {
    fixture.capture.send(fullScale)
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(fixture.dictation.inputLevel > 0.9)
  #expect(await fixture.dictation.finish(why: "log_it"))
  #expect(fixture.dictation.inputLevel == 0)
}

@MainActor
@Test func dictationInputLevelEmptiesOnCancel() async throws {
  let fixture = try DictationFixture()
  defer { fixture.cleanup() }
  fixture.dictation.toggle(note: "") { fixture.note.value = $0 }
  try await fixture.until { fixture.dictation.listening }
  let fullScale = Data((0..<320).flatMap { _ in [UInt8(0xFF), UInt8(0x7F)] })
  for _ in 0..<40 where fixture.dictation.inputLevel < 0.9 {
    fixture.capture.send(fullScale)
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(fixture.dictation.inputLevel > 0.9)
  fixture.dictation.stop(why: "cancel")
  #expect(fixture.dictation.inputLevel == 0)
}

@MainActor
private final class DictationFixture {
  let capture = TestDictationCapture()
  let provider = TestNoteProvider()
  let note = NoteValue()
  let permissions = PermissionCounts()
  let defaults: UserDefaults
  let suite: String
  let dictation: NoteDictation
  init(microphone: (@MainActor () async -> Bool)? = nil,
       hostMicrophoneBusy: @escaping @MainActor () -> Bool = { false }) throws {
    suite = "BugKit-dictation-\(UUID())"
    defaults = try #require(UserDefaults(suiteName: suite))
    let counts = permissions
    dictation = NoteDictation(logger: { _, _ in }, providerFactory: { [provider] in provider }, capture: capture,
      permissions: DictationPermissions(speech: { counts.speech += 1; return true },
        microphone: { counts.microphone += 1; return await microphone?() ?? true }),
      defaults: defaults, hostMicrophoneBusy: hostMicrophoneBusy)
  }
  func until(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<2_000 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("dictation did not reach expected state")
    throw TestNoteError.failed
  }
  func cleanup() { dictation.stop(why: "test_closed"); defaults.removePersistentDomain(forName: suite) }
}

@MainActor private final class NoteValue { var value = "" }
@MainActor private final class HostRecording { var busy = false }
@MainActor private final class PermissionCounts { var speech = 0; var microphone = 0 }
@MainActor private final class MicrophonePermissionGate {
  var waiting = false
  private var continuation: CheckedContinuation<Bool, Never>?
  func wait() async -> Bool { waiting = true; return await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(returning: true); continuation = nil }
}

@MainActor private final class TestDictationCapture: DictationCapture {
  var onFailure: (@MainActor (String) -> Void)?
  var currentInputID: String? { preferred ?? "built-in" }
  var inputs = [BugMicrophone(id: "built-in", name: "iPhone Microphone", kind: "builtInMic"),
                BugMicrophone(id: "usb", name: "USB Microphone", kind: "usbAudio")]
  var preferred: String?
  var starts = 0, restores = 0, lists = 0
  private var audio: AsyncStream<Data>.Continuation?
  func availableMicrophones() throws -> [BugMicrophone] { lists += 1; return inputs }
  func start(preferredInputID: String?) throws -> AsyncStream<Data> {
    starts += 1; preferred = preferredInputID
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    audio = continuation; continuation.yield(Data([0, 0]))
    return stream
  }
  func stop() { audio?.finish(); audio = nil }
  func restore() { restores += 1 }
  func send(_ data: Data) { audio?.yield(data) }
}

private enum TestNoteError: Error { case failed }
private actor TestNoteProvider: BugDictationProvider {
  nonisolated let name = "Test server"
  nonisolated let requiresSpeechAuthorization = false
  private var results: AsyncThrowingStream<String, Error>.Continuation?
  private(set) var starts = 0
  private(set) var cancellations = 0
  private var startGate: (@Sendable () async -> Void)?
  private var join = DictationJoin(typed: "")
  private var finalRecognition: (String, Double, Double)?
  func holdStart(_ gate: @escaping @Sendable () async -> Void) { startGate = gate }
  func start() async throws -> AsyncThrowingStream<String, Error> {
    starts += 1
    await startGate?()
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    results = continuation; return stream
  }
  func appendAudio(_ pcm16: Data) async throws {}
  func emit(_ text: String) { results?.yield(text) }
  func emitRecognition(_ text: String, firstStart: Double, lastEnd: Double) {
    join.update(text: text, firstStart: firstStart, lastEnd: lastEnd)
    results?.yield(join.note)
  }
  func setFinalRecognition(_ text: String, firstStart: Double, lastEnd: Double) {
    finalRecognition = (text, firstStart, lastEnd)
  }
  func fail() { results?.finish(throwing: TestNoteError.failed); results = nil }
  func finish() async throws {
    if let (text, start, end) = finalRecognition {
      join.update(text: text, firstStart: start, lastEnd: end, isFinal: true)
      results?.yield(join.note)
    } else { results?.yield("spoken final") }
    results?.finish(); results = nil
  }
  func cancel() async { cancellations += 1; results?.finish(); results = nil }
}
#endif
