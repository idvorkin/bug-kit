import Foundation
import Testing

@testable import BugKit

private func tempDir() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bugkit2-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [(String, [String: JSONValue])] = []
  var logger: BugLogger { { [self] e, f in lock.lock(); items.append((e, f)); lock.unlock() } }
  var all: [(String, [String: JSONValue])] { lock.lock(); defer { lock.unlock() }; return items }
  var names: [String] { all.map(\.0) }
}

// MARK: - The gentle shake (CG story 146, #164)

/// A sine on one axis at `hz`, `g` strong, sampled at 50 Hz for `seconds`; returns the first shake's peak.
private func run(_ g: Double, hz: Double, seconds: Double, start: Double = 0, on gesture: inout ShakeGesture) -> Double? {
  var t = start
  while t < start + seconds {
    if let p = gesture.feed(x: 0.05, y: g * sin(2 * .pi * hz * t), z: 0.1, t: t) { return p }
    t += 0.02
  }
  return nil
}

@Test func aQuickLightShakeIsAShake() throws {
  var g = ShakeGesture()
  let peak = try #require(run(1.8, hz: 4, seconds: 1.5, on: &g))  // lighter than iOS's hard shake
  #expect(peak >= 1.5)
}

@Test func onePushIsNotAShake() {
  var g = ShakeGesture()
  var hit = false
  // Setting the phone down: one hard push the same way, then nothing.
  for i in 0..<50 where g.feed(x: 0, y: i < 5 ? -2.5 : 0, z: 0, t: Double(i) * 0.02) != nil { hit = true }
  #expect(!hit)
}

@Test func aSlowSwayAndAWeakJiggleAreNotShakes() {
  var sway = ShakeGesture()
  #expect(run(1.7, hz: 0.5, seconds: 4, on: &sway) == nil)  // walking's swing
  var jiggle = ShakeGesture()
  #expect(run(1.0, hz: 5, seconds: 3, on: &jiggle) == nil)
}

@Test func oneShakeOpensOneSheet() {
  var g = ShakeGesture()
  #expect(run(2, hz: 4, seconds: 1.2, on: &g) != nil)
  #expect(run(2, hz: 4, seconds: 1.0, start: 1.2, on: &g) == nil)  // still shaking inside the cooldown
}

// MARK: - "Log it and another", the recapture style (CG a85e228)

@Test func recaptureClosesThenReopensAFreshReport() {
  var flow = BugReportFlow()
  flow.open(from: .shake)
  flow.note = "first"
  #expect(flow.log(another: true, style: .recapture) == "first")
  #expect(!flow.isPresented && flow.reopenPending)
  let reopened = flow.reopenIfPending()
  #expect(reopened && flow.isPresented && flow.source == .another && flow.note.isEmpty)
  #expect(!flow.reopenPending)
  flow.note = "second"
  #expect(flow.log(another: false, style: .recapture) == "second")
  let again = flow.reopenIfPending()
  #expect(!again && !flow.isPresented)
}

@Test func cancelClearsAPendingReopen() {
  var flow = BugReportFlow()
  flow.open(from: .key)
  flow.note = "x"
  _ = flow.log(another: true, style: .recapture)
  flow.cancel()
  let reopened = flow.reopenIfPending()
  #expect(!reopened)
}

// MARK: - Dictation joins what was typed (CG #239)

@Test func dictatedWordsGoAfterTheTypedNote() {
  #expect(DictationText.merge(before: "", spoken: "timer skipped") == "timer skipped")
  #expect(DictationText.merge(before: " rest  \n", spoken: "timer skipped") == "rest timer skipped")
}

// MARK: - Simulator hooks (EA SWING_BUG, CG GRABBER_BUG / GRABBER_SHAKE_AFTER)

@Test func launchHooksParseNotesAndShakeAfter() {
  let h = BugLaunchHooks.parse(["APP_BUG": "first | second||", "APP_SHAKE_AFTER": "3.5", "OTHER_BUG": "x"], prefix: "APP")
  #expect(h == BugLaunchHooks(notes: ["first", "second"], shakeAfter: 3.5))
  #expect(BugLaunchHooks.parse(["APP_SHAKE_AFTER": "soon"], prefix: "APP").isEmpty)
  #expect(BugLaunchHooks.parse([:], prefix: "APP").isEmpty)
}

// MARK: - The last N seconds of segments (MM story 040)

@Test func recentSegmentsCoverTheLastNinetySeconds() {
  let segs = (0..<30).map { (id: $0, start: Double($0) * 5, end: Double($0 + 1) * 5) }  // 0…150 s
  let picked = RecentSegments.covering(segs, now: 148, seconds: 90, start: \.start, end: \.end)
  #expect(picked.first?.id == 11)  // 55–60 overlaps 58
  #expect(picked.last?.id == 29)
  #expect(picked.count == 19)
  #expect(RecentSegments.covering(segs, now: 10, seconds: 90, start: \.start, end: \.end).map(\.id) == [0, 1, 2])
}

// MARK: - The writer's folder extras (MM story 040)

@Test func writerCopiesTheSessionLogAndWritesReportJSONWhenAsked() async throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  try FileManager.default.createDirectory(at: docs.appendingPathComponent("logs"), withIntermediateDirectories: true)
  try Data("{\"type\":\"session_start\",\"t\":0}\n".utf8).write(to: docs.appendingPathComponent("logs/app-1.jsonl"))
  let events = Events()
  let writer = BugReportWriter(
    store: BugStore(documents: docs), info: BugAppInfo(app: "T", bundle: "b", build: "1", commit: "c", device: "d"),
    logger: events.logger, copySessionLog: true, writeReportJSON: true)
  let report = await writer.save(
    note: "n", screen: "s", context: [:], screenshotPNG: nil, log: ("logs/app-1.jsonl", 5), extraFiles: nil)
  let folder = docs.appendingPathComponent(report.folder)
  #expect(report.files == ["\(report.folder)/session.jsonl"])
  #expect(try String(contentsOf: folder.appendingPathComponent("session.jsonl"), encoding: .utf8).contains("session_start"))
  let back = try JSONDecoder().decode(BugReport.self, from: Data(contentsOf: folder.appendingPathComponent("report.json")))
  #expect(back == report)
  #expect(events.names == ["bug_report"])
}

@Test func aMissingSessionLogIsAnErrorAndTheReportStillSaves() async throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let events = Events()
  let writer = BugReportWriter(
    store: BugStore(documents: docs), info: BugAppInfo(app: "T", bundle: "b", build: "1", commit: "c", device: "d"),
    logger: events.logger, copySessionLog: true)
  let report = await writer.save(
    note: "n", screen: "s", context: [:], screenshotPNG: nil, log: ("logs/gone.jsonl", 5), extraFiles: nil)
  #expect(report.files.isEmpty)
  #expect(events.names == ["error", "bug_report"])
  #expect(events.all.first?.1["where"] == "bug_session_log")
  #expect(try BugStore(documents: docs).readAll().reports.count == 1)
}

// CG #249: a pause in speaking adds to the note; it never replaces what was said or typed.
@Test func dictationRevisionsOfOneStretchReplaceEachOther() {
  var join = DictationJoin(typed: "")
  join.update(text: "the timer", firstStart: 0.4, lastEnd: 1.0)
  join.update(text: "the time is skipped the rest", firstStart: 0.4, lastEnd: 2.2)
  #expect(join.note == "the time is skipped the rest")
}

// #113 (CG #822): on-device recognition handed over one transcript that was the phrase twice with no space.
@Test(arguments: [false, true])
func dictationATranscriptThatIsItsPhraseTwiceIsKeptOnce(_ final: Bool) {
  var join = DictationJoin(typed: "")
  join.update(
    text: "I should be able to swipe to archiveI should be able to swipe to archive", firstStart: 0.3, lastEnd: 3.1,
    isFinal: final)
  #expect(join.note == "I should be able to swipe to archive")
}

// Speech that really repeats is kept: twice with a space between, a one-word double, and a phrase said once more.
@Test(arguments: ["swipe to archive swipe to archive", "nono", "go go", "swipe to archive, swipe to archive"])
func dictationSpeechThatRepeatsIsKeptAsSpoken(_ text: String) {
  var join = DictationJoin(typed: "")
  join.update(text: text, firstStart: 0.3, lastEnd: 2.0)
  #expect(join.note == text)
}

@Test func dictationAFreshTranscriptionAfterAPauseIsAdded() {
  var join = DictationJoin(typed: "Cockpit:")
  join.update(text: "when I stop", firstStart: 0.5, lastEnd: 1.5)
  let fresh = join.update(text: "it gets reset", firstStart: 4.0, lastEnd: 5.0)
  #expect(fresh)
  #expect(join.note == "Cockpit: when I stop it gets reset")
  join.update(text: "it gets reset again", firstStart: 4.0, lastEnd: 5.6)
  #expect(join.note == "Cockpit: when I stop it gets reset again")
}

@Test func dictationAFreshTranscriptionWhoseClockStartsOverIsAdded() {
  var join = DictationJoin(typed: "")
  join.update(text: "when I stop talking", firstStart: 0.5, lastEnd: 2.0)
  let fresh = join.update(text: "the input", firstStart: 0.2, lastEnd: 0.8)
  #expect(fresh)
  #expect(join.note == "when I stop talking the input")
}

@Test func dictationConsecutiveClockResetsAreEachAdded() {
  var join = DictationJoin(typed: "")
  join.update(text: "when I stop talking", firstStart: 0.5, lastEnd: 2.0)
  let firstReset = join.update(text: "the input", firstStart: 0.2, lastEnd: 0.8)
  let secondReset = join.update(text: "is gone", firstStart: 0.4, lastEnd: 1.0)
  #expect(firstReset && secondReset)
  #expect(join.note == "when I stop talking the input is gone")
  var later = DictationJoin(typed: "")
  later.update(text: "when I stop talking", firstStart: 0.3, lastEnd: 2.0)
  let laterReset = later.update(text: "the input", firstStart: 0.6, lastEnd: 1.2)
  #expect(laterReset)
  #expect(later.note == "when I stop talking the input")
}

@Test func dictationKeepsWhatWasTyped() {
  var join = DictationJoin(typed: "  typed first ")
  #expect(join.note == "typed first")
  join.update(text: "then said", firstStart: 0.3, lastEnd: 0.9)
  #expect(join.note == "typed first then said")
}

// #43: on-device partial results can have zero timing until the final transcript.
@Test(arguments: [false, true])
func dictationZeroTimedPartialIsRevisedWithoutDuplicatingItsWords(_ final: Bool) {
  let words = "I guess settings can be a button now"
  var join = DictationJoin(typed: "Typed:")
  join.update(text: words, firstStart: 0, lastEnd: 0)
  let fresh = join.update(text: words, firstStart: 0.96, lastEnd: 4.1, isFinal: final)
  #expect(!fresh)
  #expect(join.note == "Typed: " + words)
}

@Test func dictationShorterFinalCorrectionReplacesZeroTimedPartial() {
  var join = DictationJoin(typed: "")
  join.update(text: "I think that settings can be a button now", firstStart: 0, lastEnd: 0)
  let fresh = join.update(text: "Settings can be a button now", firstStart: 0.54, lastEnd: 3.9, isFinal: true)
  #expect(!fresh)
  #expect(join.note == "Settings can be a button now")
}

@Test func dictationRepeatedSpeechWithRealTimingIsPreserved() {
  var join = DictationJoin(typed: "")
  join.update(text: "yes", firstStart: 0.2, lastEnd: 1)
  let fresh = join.update(text: "yes", firstStart: 3, lastEnd: 3.6)
  #expect(fresh)
  join.update(text: "yes", firstStart: 3, lastEnd: 3.6, isFinal: true)
  #expect(join.note == "yes yes")
  var oneStretch = DictationJoin(typed: "")
  oneStretch.update(text: "yes", firstStart: 0, lastEnd: 0)
  oneStretch.update(text: "yes yes", firstStart: 0.2, lastEnd: 1.2, isFinal: true)
  #expect(oneStretch.note == "yes yes")
}

@Test func dictationRepeatedOpeningWordsAfterAPauseArePreserved() {
  var join = DictationJoin(typed: "")
  join.update(text: "go", firstStart: 0, lastEnd: 0.5)
  let fresh = join.update(text: "go home", firstStart: 3, lastEnd: 4)
  #expect(fresh)
  join.update(text: "go home", firstStart: 3, lastEnd: 4, isFinal: true)
  #expect(join.note == "go go home")
}

@Test func dictationTimedNewStretchAfterUntimedStretchIsAdded() {
  var join = DictationJoin(typed: "")
  join.update(text: "hello there", firstStart: 0, lastEnd: 0, observedAudioEnd: 2)
  let fresh = join.update(text: "and then something more", firstStart: 5, lastEnd: 6.2)
  #expect(fresh)
  #expect(join.note == "hello there and then something more")
}

@Test func dictationCumulativeFinalAfterPauseIncludesEarlierSpeechOnce() {
  var join = DictationJoin(typed: "Typed:")
  join.update(text: "first phrase", firstStart: 0.5, lastEnd: 1.5)
  join.update(text: "second phrase", firstStart: 4, lastEnd: 5)
  join.update(text: "first phrase second phrase", firstStart: 0.6, lastEnd: 5, isFinal: true)
  #expect(join.note == "Typed: first phrase second phrase")
}

@Test func dictationCumulativeFinalMayReviseEarlierStretches() {
  var join = DictationJoin(typed: "Typed:")
  join.update(text: "first phase", firstStart: 0.5, lastEnd: 1.5)
  join.update(text: "second phrase", firstStart: 4, lastEnd: 5)
  let fresh = join.update(text: "first phrase second phrase", firstStart: 0.6, lastEnd: 5, isFinal: true)
  #expect(!fresh)
  #expect(join.note == "Typed: first phrase second phrase")
}

@Test func dictationFinalCoveringLaterStretchesKeepsTheEarliestUntouched() {
  var join = DictationJoin(typed: "")
  join.update(text: "open settings", firstStart: 0.5, lastEnd: 1.5)
  join.update(text: "tap the button", firstStart: 4, lastEnd: 5)
  join.update(text: "nothing happens", firstStart: 8, lastEnd: 9)
  join.update(text: "tap the buttons nothing happens", firstStart: 4.1, lastEnd: 9, isFinal: true)
  #expect(join.note == "open settings tap the buttons nothing happens")
}

@Test func dictationFinalAfterAClockResetKeepsCompletedSpeech() {
  var join = DictationJoin(typed: "")
  join.update(text: "when I stop talking", firstStart: 0.5, lastEnd: 2.0)
  join.update(text: "the input", firstStart: 0.6, lastEnd: 1.2)
  join.update(text: "the inputs", firstStart: 0.3, lastEnd: 1.2, isFinal: true)
  #expect(join.note == "when I stop talking the inputs")
}

@Test func dictationEmptyFinalPreservesTheLastPartial() {
  var join = DictationJoin(typed: "Typed:")
  join.update(text: "keep these words", firstStart: 0, lastEnd: 0)
  join.update(text: "", firstStart: 0, lastEnd: 0, isFinal: true)
  #expect(join.note == "Typed: keep these words")
}

@Test func dictatedNoteSavedAfterFinalContainsEachUtteranceOnce() async throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let writer = BugReportWriter(store: BugStore(documents: docs),
    info: BugAppInfo(app: "Fixture", bundle: "fixture.app", build: "1", commit: "c", device: "fixture"),
    logger: { _, _ in })
  var join = DictationJoin(typed: "Typed:")
  join.update(text: "settings can be a button", firstStart: 0, lastEnd: 0)
  join.update(text: "settings can be a button", firstStart: 0.96, lastEnd: 4.1, isFinal: true)
  _ = await writer.save(note: join.note, screen: "fixture", context: [:], screenshotPNG: nil, log: nil, extraFiles: nil)
  #expect(try BugStore(documents: docs).readAll().reports.first?.note == "Typed: settings can be a button")
}


@Test(arguments: [nil, 4.0] as [Double?])
func dictationFirstWordChangingTimedPartialStillRevisesUntimedSpeech(_ observedEnd: Double?) {
  var join = DictationJoin(typed: "Typed:")
  join.update(text: "eye guess settings", firstStart: 0, lastEnd: 0, observedAudioEnd: observedEnd)
  let fresh = join.update(text: "I guess settings can be a button now", firstStart: 0.96, lastEnd: 4.1)
  #expect(!fresh)
  #expect(join.note == "Typed: I guess settings can be a button now")
}

@Test func dictationShorterUntimedCorrectionDoesNotCommitTheWrongWords() {
  var join = DictationJoin(typed: "")
  join.update(text: "the settings can be", firstStart: 0, lastEnd: 0, observedAudioEnd: 3)
  let fresh = join.update(text: "a button", firstStart: 0.8, lastEnd: 2)
  #expect(!fresh)
  #expect(join.note == "a button")
}

@Test func dictationWithoutTimingEvidenceFavorsRevision() {
  var join = DictationJoin(typed: "")
  join.update(text: "hello there", firstStart: 0, lastEnd: 0)
  let fresh = join.update(text: "and then something more", firstStart: 5, lastEnd: 6.2)
  #expect(!fresh)
  #expect(join.note == "and then something more")
}
