import Foundation
import Testing

@testable import BugKit

// Story 019 (#119): an error shown to the person files a report by itself, once per context per window, unless the
// app opts the context out; an extension's report is handed to its app through an app-group store.

private final class Log: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [(String, [String: JSONValue])] = []
  var logger: BugLogger { { [self] e, f in lock.lock(); items.append((e, f)); lock.unlock() } }
  func fields(_ name: String) -> [[String: JSONValue]] {
    lock.lock(); defer { lock.unlock() }
    return items.filter { $0.0 == name }.map(\.1)
  }
}

private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_791_000_000)
  var now: Date { lock.lock(); defer { lock.unlock() }; return value }
  func advance(_ s: TimeInterval) { lock.lock(); value += s; lock.unlock() }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  func bump() { lock.lock(); n += 1; lock.unlock() }
  var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private actor RecordingDelivery: BugReportDelivery {
  private(set) var prepared: [URL] = []
  private(set) var enqueued: [UUID] = []
  func prepare(documents: URL) async throws { prepared.append(documents) }
  func enqueue(_ report: BugReport, documents: URL) async throws { enqueued.append(report.id) }
}

/// Waits in `prepare`, as a cloud activation does, and counts the most takes in it at once.
private actor SlowDelivery: BugReportDelivery {
  private(set) var enqueued: [UUID] = []
  private(set) var most = 0
  private(set) var inside = 0
  func prepare(documents: URL) async throws {
    inside += 1
    most = max(most, inside)
    try await Task.sleep(for: .milliseconds(100))
    inside -= 1
  }
  func enqueue(_ report: BugReport, documents: URL) async throws { enqueued.append(report.id) }
}

/// Waits in the first `enqueue`, as an upload hand-off can, so a second take can start mid-folder.
private actor WaitingDelivery: BugReportDelivery {
  private(set) var enqueued: [UUID] = []
  private(set) var waiting = false
  func prepare(documents: URL) async throws {}
  func enqueue(_ report: BugReport, documents: URL) async throws {
    let first = enqueued.isEmpty
    enqueued.append(report.id)
    guard first else { return }
    waiting = true
    try await Task.sleep(for: .milliseconds(200))
    waiting = false
  }
}

private let appInfo = BugAppInfo(
  app: "Demo", bundle: "com.example.demo", build: "1.0 (1)", commit: "abc1234", device: "iPhone18,1")
private let extensionInfo = BugAppInfo(
  app: "Demo Share", bundle: "com.example.demo.share", build: "1.0 (1)", commit: "abc1234", device: "iPhone18,1")

private func temporaryFolder(_ name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("bugkit-\(name)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private let problem = BugProblem(
  message: "Voice input could not start", context: "ShareCard.dictation", build: "1.0 (1) abc1234",
  extra: ["mic_permission": "granted", "code": 1101])

@Suite struct ProblemAutoFileTests {
  fileprivate let log = Log()
  fileprivate let clock = Clock()

  fileprivate func reporter(_ docs: URL, info: BugAppInfo = appInfo) -> BugAutoReporter {
    let clock = clock
    return BugAutoReporter(
      writer: BugReportWriter(store: BugStore(documents: docs), info: info, logger: log.logger), now: { clock.now })
  }

  @Test func anErrorOnScreenFilesAReportForItsContext() async throws {
    let docs = try temporaryFolder("problem")
    let report = try #require(
      await reporter(docs).report(problem: problem, screen: "share", log: ("logs/a.jsonl", 900)))
    #expect(report.source == "auto")
    #expect(report.reason == "ShareCard.dictation")
    #expect(report.note == problem.copyText)
    #expect(report.screen == "share")
    #expect(report.screenshot == nil)
    #expect(report.sessionTMs == 900)
    #expect(report.context["message"] == "Voice input could not start")
    #expect(report.context["where"] == "ShareCard.dictation")
    #expect(report.context["build"] == "1.0 (1) abc1234")
    #expect(report.context["mic_permission"] == "granted")
    #expect(report.context["code"] == 1101)
    #expect(try BugStore(documents: docs).readAll().reports.map(\.id) == [report.id])
    #expect(log.fields("bug_report_auto").first?["reason"] == "ShareCard.dictation")
  }

  @Test func aContextFilesOncePerWindowWhateverItsMessage() async throws {
    let docs = try temporaryFolder("problem-window")
    let auto = reporter(docs)
    #expect(await auto.report(problem: problem) != nil)
    clock.advance(120)
    var again = problem
    again.message = "Voice input stopped"
    #expect(await auto.report(problem: again) == nil)
    #expect(log.fields("bug_report_auto_skipped").first?["reason"] == "ShareCard.dictation")
    #expect(await auto.report(problem: BugProblem(message: "Saving failed", context: "Home.save")) != nil)
    clock.advance(600)
    #expect(await auto.report(problem: again) != nil)
  }

  @Test func anOptedOutContextFilesNothingAndKeepsItsWindow() async throws {
    let docs = try temporaryFolder("problem-off")
    let auto = reporter(docs)
    let offline = BugProblem(message: "The Mac is not reachable", context: "Chat.offline", autoFile: false)
    #expect(await auto.report(problem: offline) == nil)
    #expect(log.fields("bug_report_auto_skipped") == [["reason": "Chat.offline", "auto_file": false]])
    #expect(try BugStore(documents: docs).readAll().reports.isEmpty)
    var filed = offline
    filed.autoFile = true
    #expect(await auto.report(problem: filed) != nil)
  }

  @Test func theTreeIsCapturedOnlyForAReportThatIsSaved() async throws {
    let docs = try temporaryFolder("problem-tree")
    let auto = reporter(docs)
    let captures = Counter()
    let tree: @MainActor @Sendable () -> BugDiagnosticsSnapshot = {
      captures.bump()
      return BugDiagnosticsSnapshot(accessibility: Data("{\"tree\":1}".utf8))
    }
    let report = try #require(await auto.report(problem: problem, diagnostics: tree))
    #expect(report.files == ["\(report.folder)/accessibility.json"])
    #expect(await auto.report(problem: problem, diagnostics: tree) == nil)
    #expect(captures.value == 1)
  }

  @Test @MainActor func theFilerAnAppSetsFilesThroughItsReporter() async throws {
    let docs = try temporaryFolder("problem-filer")
    let filer = BugProblemFiler.auto(reporter(docs), screen: { "share" })
    await filer.file(problem)
    let reports = try BugStore(documents: docs).readAll().reports
    #expect(reports.map(\.reason) == ["ShareCard.dictation"])
    #expect(reports.map(\.screen) == ["share"])
  }

  @Test func theAppTakesAnExtensionsReportOnceUnderItsOwnName() async throws {
    let group = try temporaryFolder("group")
    let shared = BugStore(documents: group.appendingPathComponent("bugkit-share"))
    try FileManager.default.createDirectory(
      at: shared.documents.appendingPathComponent("logs"), withIntermediateDirectories: true)
    try "{\"type\":\"dictation_error\"}\n".write(
      to: shared.documents.appendingPathComponent("logs/share.jsonl"), atomically: true, encoding: .utf8)
    let extensionAuto = BugAutoReporter(
      writer: BugReportWriter(store: shared, info: extensionInfo, logger: log.logger))
    let tree: @MainActor @Sendable () -> BugDiagnosticsSnapshot = {
      BugDiagnosticsSnapshot(accessibility: Data("{}".utf8))
    }
    let saved = try #require(
      await extensionAuto.report(problem: problem, log: ("logs/share.jsonl", 40), diagnostics: tree))

    let appDocs = try temporaryFolder("app")
    let delivery = RecordingDelivery()
    let writer = BugReportWriter(
      store: BugStore(documents: appDocs), info: appInfo, logger: log.logger, delivery: delivery)
    let taken = await writer.adopt(from: shared)
    #expect(taken.map(\.id) == [saved.id])
    let report = try #require(try writer.store.readAll().reports.first)
    #expect(report.id == saved.id)
    #expect(report.app == "Demo")
    #expect(report.bundle == "com.example.demo")
    #expect(report.context["extension"] == "com.example.demo.share")
    #expect(report.reason == "ShareCard.dictation")
    #expect(report.sessionTMs == 40)
    for path in report.files + [report.log].compactMap({ $0 }) {
      #expect(FileManager.default.fileExists(atPath: appDocs.appendingPathComponent(path).path), "\(path)")
      #expect(path.hasPrefix(report.folder + "/"), "\(path)")
    }
    #expect(
      try String(contentsOf: appDocs.appendingPathComponent(try #require(report.log)), encoding: .utf8)
        .contains("dictation_error"))
    #expect(await delivery.enqueued == [saved.id])
    #expect(log.fields("bug_report_adopted").first?["id"] == .string(saved.id.uuidString))
    #expect(try shared.readAll().reports.isEmpty)
    #expect(FileManager.default.fileExists(
      atPath: shared.documents.appendingPathComponent("logs/share.jsonl").path))
    #expect(await writer.adopt(from: shared).isEmpty)
    #expect(try writer.store.readAll().reports.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: group.path) == ["bugkit-share"])
    #expect(!FileManager.default.fileExists(atPath: shared.documents.appendingPathComponent(saved.folder).path))
    // The extension's window survives the take: the same context, a minute later, files nothing.
    let relaunched = BugAutoReporter(writer: BugReportWriter(store: shared, info: extensionInfo, logger: log.logger))
    #expect(await relaunched.report(problem: problem) == nil)
  }

  @Test func aReportAlreadyTakenIsNeverAddedTwice() async throws {
    let group = try temporaryFolder("group-again")
    let shared = BugStore(documents: group.appendingPathComponent("bugkit-share"))
    let saved = try #require(
      await BugAutoReporter(writer: BugReportWriter(store: shared, info: extensionInfo, logger: log.logger))
        .report(problem: problem))
    // A take that stopped after appending (the app was killed) leaves the report in both stores.
    let appDocs = try temporaryFolder("app-again")
    let appStore = BugStore(documents: appDocs)
    try appStore.append(saved)
    let writer = BugReportWriter(store: appStore, info: appInfo, logger: log.logger)
    #expect(await writer.adopt(from: shared).isEmpty)
    #expect(try appStore.readAll().reports.map(\.id) == [saved.id])
    #expect(try shared.readAll().reports.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: shared.documents.appendingPathComponent(saved.folder).path))
  }

  @Test func anIndexLeftAsideByAKilledTakeIsAdoptedWithItsFiles() async throws {
    let group = try temporaryFolder("group-killed")
    let shared = BugStore(documents: group.appendingPathComponent("bugkit-share"))
    let tree: @MainActor @Sendable () -> BugDiagnosticsSnapshot = {
      BugDiagnosticsSnapshot(accessibility: Data("{\"role\":\"window\"}".utf8))
    }
    let saved = try #require(
      await BugAutoReporter(writer: BugReportWriter(store: shared, info: extensionInfo, logger: log.logger))
        .report(problem: problem, diagnostics: tree))
    #expect(!saved.files.isEmpty)
    // The take was killed right after its rename: the index is aside, the report's folder is still in the store.
    let aside = group.appendingPathComponent("bugkit-share.taking-killed")
    try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: shared.index, to: BugStore(documents: aside).index)

    let appDocs = try temporaryFolder("app-killed")
    let writer = BugReportWriter(store: BugStore(documents: appDocs), info: appInfo, logger: log.logger)
    let taken = await writer.adopt(from: shared)
    let report = try #require(taken.first)
    #expect(taken.map(\.id) == [saved.id])
    #expect(report.files.count == saved.files.count)
    for path in report.files {
      #expect(
        try String(contentsOf: appDocs.appendingPathComponent(path), encoding: .utf8).contains("window"), "\(path)")
    }
    #expect(log.fields("error").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: shared.documents.appendingPathComponent(saved.folder).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: group.path) == ["bugkit-share"])
  }

  /// The indexes an adopt set aside in `group` and kept for the next take.
  private func asides(in group: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(atPath: group.path).filter { $0.hasPrefix("bugkit-share.taking-") }
      .map { group.appendingPathComponent($0) }
  }

  @Test func aReportNotWrittenHereIsKeptForTheNextTake() async throws {
    let group = try temporaryFolder("group-unwritten")
    let shared = BugStore(documents: group.appendingPathComponent("bugkit-share"))
    let saved = try #require(
      await BugAutoReporter(writer: BugReportWriter(store: shared, info: extensionInfo, logger: log.logger))
        .report(problem: problem))
    // The app's index cannot be written: it links into a folder that is not there.
    let appDocs = try temporaryFolder("app-unwritten")
    let appStore = BugStore(documents: appDocs)
    try FileManager.default.createSymbolicLink(
      at: appStore.index, withDestinationURL: appDocs.appendingPathComponent("missing/bugs.jsonl"))
    let writer = BugReportWriter(store: appStore, info: appInfo, logger: log.logger)
    #expect(await writer.adopt(from: shared).isEmpty)
    #expect(try asides(in: group).count == 1)
    try FileManager.default.removeItem(at: appStore.index)
    #expect(await writer.adopt(from: shared).map(\.id) == [saved.id])
    let report = try #require(try appStore.readAll().reports.first)
    #expect(try appStore.readAll().reports.map(\.id) == [saved.id])
    #expect(try FileManager.default.contentsOfDirectory(atPath: appDocs.appendingPathComponent("bugs").path)
      .map { "bugs/\($0)" } == [report.folder])
    #expect(try asides(in: group).isEmpty)
  }

  @Test func anIndexNotReadIsKeptForTheNextTake() async throws {
    let group = try temporaryFolder("group-unread")
    let shared = BugStore(documents: group.appendingPathComponent("bugkit-share"))
    let saved = try #require(
      await BugAutoReporter(writer: BugReportWriter(store: shared, info: extensionInfo, logger: log.logger))
        .report(problem: problem))
    let line = try Data(contentsOf: shared.index)
    try Data([0xFF, 0xFE, 0x0A]).write(to: shared.index)  // not UTF-8: the extension's index cannot be read
    let appStore = BugStore(documents: try temporaryFolder("app-unread"))
    let writer = BugReportWriter(store: appStore, info: appInfo, logger: log.logger)
    #expect(await writer.adopt(from: shared).isEmpty)
    let aside = try #require(try asides(in: group).first)
    // Nor is the app's own index: without it nothing tells a report already taken.
    try line.write(to: aside.appendingPathComponent("bugs.jsonl"))
    try FileManager.default.createDirectory(at: appStore.index, withIntermediateDirectories: true)
    #expect(await writer.adopt(from: shared).isEmpty)
    #expect(try asides(in: group).contains(aside))
    try FileManager.default.removeItem(at: appStore.index)
    #expect(await writer.adopt(from: shared).map(\.id) == [saved.id])
    #expect(try asides(in: group).isEmpty)
  }

  @Test func overlappingTakesTakeAReportOnce() async throws {
    let group = try temporaryFolder("group-overlap")
    let shared = BugStore(documents: group.appendingPathComponent("bugkit-share"))
    let saved = try #require(
      await BugAutoReporter(writer: BugReportWriter(store: shared, info: extensionInfo, logger: log.logger))
        .report(problem: problem))
    let appStore = BugStore(documents: try temporaryFolder("app-overlap"))
    let delivery = SlowDelivery()
    let writer = BugReportWriter(store: appStore, info: appInfo, logger: log.logger, delivery: delivery)
    // The second starts while the first waits mid-take, having set the index aside but appended nothing yet.
    let first = Task { await writer.adopt(from: shared) }
    while await delivery.inside == 0 { await Task.yield() }
    let second = Task { await writer.adopt(from: shared) }
    #expect(await (first.value + second.value).map(\.id) == [saved.id])
    #expect(try appStore.readAll().reports.map(\.id) == [saved.id])
    #expect(await delivery.enqueued == [saved.id])
    #expect(await delivery.most == 1)
  }

  @Test func aTakeStartedMidFolderTakesNoReportTwice() async throws {
    let group = try temporaryFolder("group-midfolder")
    let shared = BugStore(documents: group.appendingPathComponent("bugkit-share"))
    let extensionWriter = BugReportWriter(store: shared, info: extensionInfo, logger: log.logger)
    let a = try #require(await BugAutoReporter(writer: extensionWriter).report(problem: problem))
    let other = BugProblem(message: "Card could not save", context: "ShareCard.save", build: "1.0 (1) abc1234")
    let b = try #require(await BugAutoReporter(writer: extensionWriter).report(problem: other))
    let appStore = BugStore(documents: try temporaryFolder("app-midfolder"))
    let delivery = WaitingDelivery()
    let writer = BugReportWriter(store: appStore, info: appInfo, logger: log.logger, delivery: delivery)
    // The first waits in A's hand-off; the second then finds the same aside, with A held and B not yet taken.
    let first = Task { await writer.adopt(from: shared) }
    while await !delivery.waiting { await Task.yield() }
    let second = Task { await writer.adopt(from: shared) }
    let taken = await first.value + second.value
    #expect(Set(taken.map(\.id)) == [a.id, b.id])
    #expect(taken.count == 2)
    let held: [String] = try appStore.readAll().reports.map(\.id.uuidString).sorted()
    let expected: [String] = [a.id.uuidString, b.id.uuidString].sorted()
    #expect(held == expected)
    #expect(await delivery.enqueued.count == 2)
  }

  @Test func aStoreFolderNotMadeYetStillKeepsTheWindow() async throws {
    // An extension's folder in the group does not exist before its first report.
    let shared = BugStore(documents: try temporaryFolder("fresh").appendingPathComponent("bugkit-share"))
    let writer = BugReportWriter(store: shared, info: extensionInfo, logger: log.logger)
    #expect(await BugAutoReporter(writer: writer).report(problem: problem) != nil)
    #expect(await BugAutoReporter(writer: writer).report(problem: problem) == nil)
    #expect(log.fields("error").isEmpty)
  }

  @Test func noExtensionStoreIsNothingToTake() async throws {
    let group = try temporaryFolder("group-none")
    let writer = BugReportWriter(
      store: BugStore(documents: try temporaryFolder("app-none")), info: appInfo, logger: log.logger)
    #expect(await writer.adopt(from: BugStore(documents: group.appendingPathComponent("bugkit-share"))).isEmpty)
    #expect(log.fields("error").isEmpty)
  }
}
