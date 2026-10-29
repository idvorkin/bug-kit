#if canImport(CloudKit)
import CloudKit
#endif
import Foundation
import Testing
@testable import BugKit

private actor FakeCloudTransport: CloudReportTransport {
  var account = "owner"
  var failing = false
  var uploads: [UUID: Data] = [:]
  var accountChecks = 0
  func accountID() -> String { accountChecks += 1; return account }
  func upload(_ report: BugReport, payload: URL) throws {
    if failing { throw CloudDeliveryError.accountUnavailable }
    uploads[report.id] = try Data(contentsOf: payload)
  }
  func setFailing(_ value: Bool) { failing = value }
  func setAccount(_ value: String) { account = value }
  func count() -> Int { uploads.count }
  func data(_ id: UUID) -> Data? { uploads[id] }
  func checks() -> Int { accountChecks }
}

private struct CloudFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var documents: URL { root.appendingPathComponent("source") }
  var store: BugStore { BugStore(documents: documents) }
  var outboxRoot: URL { documents.appendingPathComponent("delivery") }
  func outbox(_ transport: FakeCloudTransport) -> CloudReportOutbox {
    CloudReportOutbox(store: store, root: outboxRoot, transport: transport, logger: { _, _ in })
  }
  func report() throws -> BugReport {
    let folder = documents.appendingPathComponent("bugs/sample")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("synthetic screen".utf8).write(to: folder.appendingPathComponent("screen.png"))
    try Data("synthetic interactions".utf8).write(to: folder.appendingPathComponent("interactions.jsonl"))
    return BugReport(app: "fixture", bundle: "local.fixture", build: "1", commit: "fixture", device: "synthetic",
                     screen: "home", note: "fixture note", screenshot: "bugs/sample/screen.png",
                     folder: "bugs/sample", files: ["bugs/sample/interactions.jsonl"])
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func cloudDeliveryRestartsAndRetriesWithoutChangingEvidence() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport(); await transport.setFailing(true)
  let report = try f.report(); try f.store.append(report)
  let queue = f.outbox(transport)
  try await queue.enqueue(report, documents: f.documents)
  do { _ = try await queue.flush(); Issue.record("Upload should fail") } catch {}
  #expect(await transport.count() == 0)
  try Data("later screen".utf8).write(to: f.documents.appendingPathComponent(report.screenshot!))
  await transport.setFailing(false)
  let restarted = f.outbox(transport)
  _ = try await restarted.flush()
  #expect(await transport.count() == 1)
  let data = try #require(await transport.data(report.id))
  let payload = try JSONDecoder().decode(CloudReportPayload.self, from: data)
  #expect(payload.files[report.screenshot!] == Data("synthetic screen".utf8))
  #expect(try await restarted.flush() == 0)
  #expect(try f.store.readAll().reports == [report])
}

@Test func cloudDeliveryStopsWhenAccountChanges() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let queue = try await f.optedIn(transport)
  let report = try f.report(); try f.store.append(report)
  _ = try await queue.flush()
  await transport.setAccount("different-owner")
  var next = try f.report(); next.id = UUID(); try f.store.append(next)  // the check guards a report waiting to go
  await #expect(throws: CloudDeliveryError.accountChanged) { try await f.outbox(transport).flush() }
  #expect(await transport.count() == 1)
}

@Test func flushWithNothingWaitingNeverAsksCloudKit() async throws {
  // An unsigned build traps in CKContainer(identifier:); a launch with nothing to send must not touch it (#87).
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let queue = try await f.optedIn(transport)
  #expect(try await queue.flush() == 0)
  #expect(await transport.checks() == 0)
  let report = try f.report(); try f.store.append(report)
  #expect(try await queue.flush() == 1)
  let afterUpload = await transport.checks()
  #expect(try await queue.flush() == 0)
  #expect(await transport.checks() == afterUpload)
}

#if canImport(CloudKit)
@Test func aBuildNotSignedForTheContainerNeverCreatesOne() async throws {
  // The test runner has no iCloud entitlement: creating the CKContainer here would trap the whole run (#87).
  let transport = NativeCloudReportTransport(containerIdentifier: "iCloud.com.example.BugKitReports")
  await #expect(throws: CloudDeliveryError.notEntitled) { try await transport.accountID() }
  #expect(transport.retryDelay(for: CloudDeliveryError.notEntitled, attempt: 0) == nil)
}

@Test func signedContainersAreReadFromTheEntitlementsPlistInTheExecutable() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let key = "<key>com.apple.developer.icloud-container-identifiers</key>"
  let containers = "\(key)\n\t<array>\n\t\t<string>iCloud.com.example.A</string>\n\t\t<string>iCloud.com.example.B</string>\n\t</array>"
  let services = { (names: String) in "<key>com.apple.developer.icloud-services</key>\n\t<array>\(names)</array>\n" }
  let plist = services("<string>CloudDocuments</string><string>CloudKit</string>") + containers
  let signed = dir.appendingPathComponent("signed")
  // The key also sits in a binary's string table, followed by other strings rather than an array.
  try (Data([0xCF, 0xFA, 0xED, 0xFE, 0x00]) + Data("\(key)\0iCloud.com.example.C\0</array>".utf8) + Data([0x00, 0xFF])
    + Data(plist.utf8) + Data([0x00])).write(to: signed)
  #expect(NativeCloudReportTransport.containers(inExecutable: signed) == ["iCloud.com.example.A", "iCloud.com.example.B"])
  // iCloud Documents alone also lists the container, but CKContainer(identifier:) still traps without CloudKit.
  let documentsOnly = dir.appendingPathComponent("documents-only")
  try Data((services("<string>CloudDocuments</string>") + containers).utf8).write(to: documentsOnly)
  #expect(NativeCloudReportTransport.containers(inExecutable: documentsOnly).isEmpty)
  let unsigned = dir.appendingPathComponent("unsigned")
  try Data("\(key)\0iCloud.com.example.C\0".utf8).write(to: unsigned)
  #expect(NativeCloudReportTransport.containers(inExecutable: unsigned).isEmpty)
  #expect(NativeCloudReportTransport.containers(inExecutable: dir.appendingPathComponent("missing")).isEmpty)
  #expect(NativeCloudReportTransport.containers(inExecutable: nil).isEmpty)
}
#endif

@Test func cloudPayloadInstallsCompleteEvidenceAndRepairsMissingFiles() throws {
  let f = CloudFixture(); defer { f.clean() }
  let report = try f.report()
  let payload = try CloudReportPayload.capture(report, documents: f.documents)
  let inbox = f.root.appendingPathComponent("inbox")
  let installed = try payload.install(in: inbox)
  #expect(CloudReportPayload.isComplete(installed))
  let evidence = installed.appendingPathComponent("Documents").appendingPathComponent(report.screenshot!)
  try FileManager.default.removeItem(at: evidence)
  #expect(!CloudReportPayload.isComplete(installed))
  _ = try payload.install(in: inbox)
  #expect(CloudReportPayload.isComplete(installed))
  #expect(try Data(contentsOf: evidence) == payload.files[report.screenshot!])
}

@Test func cloudPayloadRejectsEscapesAndMissingEvidence() throws {
  let f = CloudFixture(); defer { f.clean() }
  var report = try f.report()
  report.files.append("../outside")
  #expect(throws: CloudDeliveryError.invalidPath) { try CloudReportPayload.capture(report, documents: f.documents) }
  report.files = ["bugs/sample/missing.txt"]
  #expect(throws: (any Error).self) { try CloudReportPayload.capture(report, documents: f.documents) }
  let outside = f.root.appendingPathComponent("outside")
  try Data("outside".utf8).write(to: outside)
  let link = f.documents.appendingPathComponent("escape")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
  report.files = ["escape"]
  #expect(throws: CloudDeliveryError.invalidPath) { try CloudReportPayload.capture(report, documents: f.documents) }
}

@Test func cloudDeliveryRecoversSavedReportWhenOneAttachmentIsMissing() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let queue = try await f.optedIn(transport)
  var bad = try f.report(); bad.files = ["bugs/sample/not-yet.txt"]
  try f.store.append(bad)
  let good = try f.report(); try f.store.append(good)
  #expect(try await queue.flush() == 1)
  #expect(await transport.data(bad.id) == nil)
  try Data("arrived".utf8).write(to: f.documents.appendingPathComponent("bugs/sample/not-yet.txt"))
  #expect(try await queue.flush() == 1)
  #expect(await transport.count() == 2)
}

private actor RejectingDelivery: BugReportDelivery {
  var called = false
  func enqueue(_ report: BugReport, documents: URL) throws { called = true; throw CloudDeliveryError.accountUnavailable }
  func wasCalled() -> Bool { called }
}

/// Simulates termination after local append: no enqueue reaches the outbox or starts a retry.
private struct InterruptedCloudDelivery: BugReportDelivery {
  let queue: CloudReportOutbox
  func prepare(documents: URL) async throws { try await queue.prepare(documents: documents) }
  func enqueue(_ report: BugReport, documents: URL) async throws {
    throw CloudDeliveryError.accountUnavailable
  }
}

@Test func firstOptInSaveRecoversAfterTerminationBeforeEnqueueWithoutLaunchTask() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let history = try f.report(); try f.store.append(history)
  let writer = BugReportWriter(store: f.store,
    info: BugAppInfo(app: "fixture", bundle: "local.fixture", build: "1", commit: "fixture", device: "synthetic"),
    logger: { _, _ in }, delivery: InterruptedCloudDelivery(queue: f.outbox(transport)))
  // No start/flush launch Task has run. The writer must establish the boundary before append.
  let report = await writer.save(note: "first opted-in report", screen: "home", context: [:],
                                 screenshotPNG: nil, log: nil, extraFiles: nil)
  #expect(await transport.count() == 0)
  let restarted = f.outbox(transport)
  #expect(try await restarted.flush() == 1)
  #expect(await transport.data(report.id) != nil)
  #expect(await transport.data(history.id) == nil)
  #expect(try f.store.readAll().reports.map(\.id) == [history.id, report.id])
}

@Test func optInPreparationDoesNotWaitForAnAvailableCloudAccount() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let history = try f.report(); try f.store.append(history)
  let queue = f.outbox(transport)
  try await queue.prepare(documents: f.documents)
  #expect(await transport.checks() == 0)
  let report = try f.report(); try f.store.append(report)
  #expect(try await f.outbox(transport).flush() == 1)
  #expect(await transport.data(history.id) == nil)
  #expect(await transport.data(report.id) != nil)
}

private struct PreparationFailure: BugReportDelivery {
  func prepare(documents: URL) async throws { throw CloudDeliveryError.wrongStore }
  func enqueue(_ report: BugReport, documents: URL) async throws { throw CloudDeliveryError.wrongStore }
}

@Test func failedDeliveryPreparationStillSavesLocalReport() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let events = CloudEvents()
  let writer = BugReportWriter(store: f.store,
    info: BugAppInfo(app: "fixture", bundle: "local.fixture", build: "1", commit: "fixture", device: "synthetic"),
    logger: events.logger, delivery: PreparationFailure())
  let report = await writer.save(note: "local fallback", screen: "home", context: [:],
                                 screenshotPNG: nil, log: nil, extraFiles: nil)
  #expect(try f.store.readAll().reports == [report])
  #expect(events.all.contains { $0.0 == "error" && $0.1["where"] == .string("bug_delivery_prepare") })
}

@Test func cloudDeliveryFailureDoesNotLoseLocalWriterReport() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let delivery = RejectingDelivery()
  let writer = BugReportWriter(store: f.store,
    info: BugAppInfo(app: "fixture", bundle: "local.fixture", build: "1", commit: "fixture", device: "synthetic"),
    logger: { _, _ in }, delivery: delivery)
  let report = await writer.save(note: "kept locally", screen: "home", context: [:], screenshotPNG: nil,
                                 log: nil, extraFiles: nil)
  #expect(await delivery.wasCalled())
  #expect(try f.store.readAll().reports == [report])
}

private actor LoopbackCloud: CloudReportTransport, CloudReportSource {
  let root: URL
  var available = false
  var saved: [UUID: String] = [:]
  var listed: [CloudReportRecord] = []
  var uploadAttempts = 0
  init(root: URL) { self.root = root }
  func accountID() -> String { "synthetic-owner" }
  nonisolated func retryDelay(for error: any Error, attempt: Int) -> TimeInterval? { 0.01 }
  func upload(_ report: BugReport, payload: URL) throws {
    uploadAttempts += 1
    guard available else { throw CloudDeliveryError.accountUnavailable }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(contentsOf: payload).write(to: root.appendingPathComponent(report.id.uuidString), options: .atomic)
    saved[report.id] = report.bundle
  }
  func reports() -> [CloudReportRecord] {
    listed + saved.map { CloudReportRecord(name: $0.key.uuidString, bundle: $0.value) }
  }
  func asset(for id: UUID) throws -> CloudReportAsset {
    guard let bundle = saved[id] else { throw CloudDeliveryError.invalidPayload }
    return CloudReportAsset(bundle: bundle, file: root.appendingPathComponent(id.uuidString))
  }
  func list(_ records: [CloudReportRecord]) { listed = records }
  func connect() { available = true }
  func attempts() -> Int { uploadAttempts }
  func count() -> Int { saved.count }
}

@Test func cloudReportEventuallyReachesMacAfterOfflineSaveWithoutAnotherEnqueue() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let cloud = LoopbackCloud(root: f.root.appendingPathComponent("server"))
  let queue = CloudReportOutbox(store: f.store, root: f.outboxRoot, transport: cloud, logger: { _, _ in })
  let writer = BugReportWriter(store: f.store,
    info: BugAppInfo(app: "fixture", bundle: "local.fixture", build: "1", commit: "fixture", device: "synthetic"),
    logger: { _, _ in }, delivery: queue)
  let report = await writer.save(note: "cellular fixture", screen: "home", context: [:],
                                 screenshotPNG: Data("evidence".utf8), log: nil, extraFiles: nil)
  for _ in 0..<100 where await cloud.attempts() == 0 { try await Task.sleep(for: .milliseconds(10)) }
  #expect(await cloud.attempts() > 0)
  #expect(await cloud.count() == 0)
  await cloud.connect()
  for _ in 0..<100 where await cloud.count() == 0 { try await Task.sleep(for: .milliseconds(10)) }
  #expect(await cloud.count() == 1)
  let mac = f.root.appendingPathComponent("mac")
  let receiver = CloudReportInbox(source: cloud, logger: { _, _ in })
  #expect(try await receiver.download(to: mac) == 1)
  let destination = mac.appendingPathComponent(report.id.uuidString)
  #expect(CloudReportPayload.isComplete(destination))
  #expect(try Data(contentsOf: destination.appendingPathComponent("Documents/" + report.screenshot!)) == Data("evidence".utf8))
  #expect(try await receiver.download(to: mac) == 0)
  #expect(try f.store.readAll().reports == [report])
  await queue.stop()
}

@Test func cloudReceiverFailureIsNotMistakenForMacDeliveryAndRetries() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let cloud = LoopbackCloud(root: f.root.appendingPathComponent("server"))
  await cloud.connect()
  let queue = try await f.optedIn(cloud)
  let report = try f.report(); try f.store.append(report)
  _ = try await queue.flush()
  let serverFile = f.root.appendingPathComponent("server/" + report.id.uuidString)
  let bytes = try Data(contentsOf: serverFile)
  try Data("truncated".utf8).write(to: serverFile)
  let mac = f.root.appendingPathComponent("mac")
  let receiver = CloudReportInbox(source: cloud, logger: { _, _ in })
  await #expect(throws: (any Error).self) { try await receiver.download(to: mac) }
  #expect(!CloudReportPayload.isComplete(mac.appendingPathComponent(report.id.uuidString)))
  try bytes.write(to: serverFile)
  #expect(try await receiver.download(to: mac) == 1)
  #expect(CloudReportPayload.isComplete(mac.appendingPathComponent(report.id.uuidString)))
}

@Test func unstageableEvidenceStopsRetryingUntilStartOrNewReport() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let queue = CloudReportOutbox(store: f.store, root: f.outboxRoot, transport: transport, logger: { _, _ in },
                                sleep: { _ in await Task.yield() })
  var bad = try f.report(); bad.files = ["bugs/sample/not-yet.txt"]
  try f.store.append(bad)
  await #expect(throws: (any Error).self) { try await queue.enqueue(bad, documents: f.documents) }
  await queue.start()
  try await Task.sleep(for: .milliseconds(200))
  #expect(await transport.checks() == 1)
  #expect(await transport.count() == 0)
  try Data("arrived".utf8).write(to: f.documents.appendingPathComponent("bugs/sample/not-yet.txt"))
  await queue.start()
  for _ in 0..<100 where await transport.count() == 0 { try await Task.sleep(for: .milliseconds(10)) }
  #expect(await transport.data(bad.id) != nil)
  let next = try f.report(); try f.store.append(next)
  try await queue.enqueue(next, documents: f.documents)
  for _ in 0..<100 where await transport.count() < 2 { try await Task.sleep(for: .milliseconds(10)) }
  #expect(await transport.data(next.id) != nil)
  await queue.stop()
}

private final class CloudEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [(String, [String: JSONValue])] = []
  var logger: BugLogger { { [self] e, f in lock.lock(); items.append((e, f)); lock.unlock() } }
  var all: [(String, [String: JSONValue])] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func badListedRecordsAreReportedWhileValidReportsStillDownload() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let cloud = LoopbackCloud(root: f.root.appendingPathComponent("server"))
  await cloud.connect()
  let queue = try await f.optedIn(cloud)
  let report = try f.report(); try f.store.append(report)
  _ = try await queue.flush()
  let failed = UUID(), noBundle = UUID()
  await cloud.list([CloudReportRecord(name: failed.uuidString, bundle: nil, error: CloudDeliveryError.accountUnavailable),
                    CloudReportRecord(name: "console-test-record", bundle: "local.fixture"),
                    CloudReportRecord(name: noBundle.uuidString, bundle: nil)])
  let events = CloudEvents()
  let mac = f.root.appendingPathComponent("mac")
  let receiver = CloudReportInbox(source: cloud, logger: events.logger)
  await #expect(throws: (any Error).self) { try await receiver.download(to: mac) }
  #expect(CloudReportPayload.isComplete(mac.appendingPathComponent(report.id.uuidString)))
  let pending = events.all.filter { $0.0 == "cloudkit_report_pending" }.map { $0.1["id"] }
  #expect(pending.count == 3)
  #expect(Set(pending.compactMap { $0 }) == [.string(failed.uuidString), .string(noBundle.uuidString)])
  #expect(events.all.contains { $0.0 == "cloudkit_downloaded" && $0.1["id"] == .string(report.id.uuidString) })
}

private extension CloudFixture {
  /// Opt in before any report exists, as an app does at launch; later saves are eligible.
  func optedIn(_ transport: any CloudReportTransport) async throws -> CloudReportOutbox {
    let queue = CloudReportOutbox(store: store, root: outboxRoot, transport: transport, logger: { _, _ in })
    #expect(try await queue.flush() == 0)
    return queue
  }
}

@Test func aReportThatCanNeverBeStagedIsSkippedOnceAndStopsAskingCloudKit() async throws {
  // Over the limits forever: without a give-up marker every launch and foreground paid an account round trip.
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let events = CloudEvents()
  let queue = CloudReportOutbox(store: f.store, root: f.outboxRoot, transport: transport, logger: events.logger)
  #expect(try await queue.flush() == 0)  // opted in before the report
  var huge = try f.report(); huge.files = (0...100).map { "bugs/sample/part-\($0).bin" }  // 101 > 100 attachments
  try f.store.append(huge)
  #expect(try await queue.flush() == 0)
  let marker = f.outboxRoot.appendingPathComponent("skipped/\(huge.id.uuidString).json")
  #expect(FileManager.default.fileExists(atPath: marker.path))
  let skips = { events.all.filter { $0.0 == "bug_delivery_skipped" } }
  #expect(skips().count == 1 && skips().first?.1["reason"] == .string("too_large"))
  let checks = await transport.checks()
  #expect(try await f.outbox(transport).flush() == 0)  // a later launch
  #expect(await transport.checks() == checks)
  #expect(skips().count == 1)
  #expect(try f.store.readAll().reports.map(\.id) == [huge.id])  // the report itself stays local
  let next = try f.report(); try f.store.append(next)
  #expect(try await queue.flush() == 1)
  #expect(await transport.data(next.id) != nil)
  #expect(await transport.data(huge.id) == nil)
}

@Test func evidenceOutsideTheStoreIsSkippedOnceAsInvalidPath() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let events = CloudEvents()
  let queue = CloudReportOutbox(store: f.store, root: f.outboxRoot, transport: transport, logger: events.logger)
  #expect(try await queue.flush() == 0)
  var escaped = try f.report(); escaped.files = ["../outside.txt"]
  try f.store.append(escaped)
  #expect(try await queue.flush() == 0)
  let marker = f.outboxRoot.appendingPathComponent("skipped/\(escaped.id.uuidString).json")
  #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: marker))["reason"] == "invalid_path")
  let checks = await transport.checks()
  #expect(try await f.outbox(transport).flush() == 0)  // a later launch
  #expect(await transport.checks() == checks)
  #expect(events.all.filter { $0.0 == "bug_delivery_skipped" }.count == 1)
  #expect(!events.all.contains { $0.0 == "bug_delivery_pending" })
}

@Test func evidenceOverTheByteBudgetIsSkippedAsTooLarge() async throws {
  // docs/integration.md: at most 20 MB of evidence per report. A sparse file keeps the test cheap.
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let queue = f.outbox(transport)
  #expect(try await queue.flush() == 0)
  var big = try f.report(); big.files = ["bugs/sample/big.bin"]
  let url = f.documents.appendingPathComponent("bugs/sample/big.bin")
  FileManager.default.createFile(atPath: url.path, contents: nil)
  let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: 21_000_000); try handle.close()
  try f.store.append(big)
  #expect(try await queue.flush() == 0)
  let marker = f.outboxRoot.appendingPathComponent("skipped/\(big.id.uuidString).json")
  #expect(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: marker))["reason"] == "too_large")
  #expect(await transport.data(big.id) == nil)
}

@Test func writerNamesAGivenUpReportDifferentlyFromAPendingOne() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let events = CloudEvents()
  let queue = CloudReportOutbox(store: f.store, root: f.outboxRoot, transport: transport, logger: events.logger)
  try await queue.prepare(documents: f.documents)
  #expect(try await queue.flush() == 0)
  let writer = BugReportWriter(store: f.store,
    info: BugAppInfo(app: "fixture", bundle: "local.fixture", build: "1", commit: "fixture", device: "synthetic"),
    logger: events.logger, delivery: queue)
  let huge = await writer.save(note: "huge", screen: "home", context: [:], screenshotPNG: nil, log: nil,
    extraFiles: { folder in
      try (0...100).map { i in
        let name = "part-\(i).bin"; try Data("x".utf8).write(to: folder.appendingPathComponent(name)); return name }
    })
  let missing = await writer.save(note: "missing", screen: "home", context: [:], screenshotPNG: nil, log: nil,
    extraFiles: { _ in ["not-there.txt"] })
  await queue.stop()
  func message(_ id: UUID) -> JSONValue? {
    events.all.first { $0.0 == "error" && $0.1["where"] == .string("bug_delivery_enqueue")
      && $0.1["id"] == .string(id.uuidString) }?.1["message"]
  }
  #expect(message(huge.id) == .string("Cloud delivery gave up on this report (bug_delivery_skipped); it remains local."))
  #expect(message(missing.id) == .string("Cloud delivery is pending; the report remains local."))
  #expect(try f.store.readAll().reports.map(\.id) == [huge.id, missing.id])
}

@Test func reportsSavedBeforeOptInStayLocalWhileLaterReportsRecoverAfterRestart() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let history = try f.report(); try f.store.append(history)
  #expect(try await f.outbox(transport).flush() == 0)
  // Saved after opt-in, but the app died before enqueue; another has evidence that is not there yet.
  let unannounced = try f.report(); try f.store.append(unannounced)
  var late = try f.report(); late.files = ["bugs/sample/not-yet.txt"]
  try f.store.append(late)
  await #expect(throws: (any Error).self) { try await f.outbox(transport).enqueue(late, documents: f.documents) }
  let restarted = f.outbox(transport)
  #expect(try await restarted.flush() == 1)
  #expect(await transport.data(unannounced.id) != nil)
  try Data("arrived".utf8).write(to: f.documents.appendingPathComponent("bugs/sample/not-yet.txt"))
  #expect(try await f.outbox(transport).flush() == 1)
  #expect(try await f.outbox(transport).flush() == 0)
  #expect(await transport.count() == 2)
  #expect(await transport.data(history.id) == nil)
  #expect(try f.store.readAll().reports.map(\.id) == [history.id, unannounced.id, late.id])
}

@Test func enqueuedReportIsDeliveredEvenIfTheOptInBoundaryAlreadyListedIt() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = FakeCloudTransport()
  let queue = f.outbox(transport)
  // The writer appended this report just before the boundary was recorded, then enqueued it.
  let report = try f.report(); try f.store.append(report)
  #expect(try await queue.flush() == 0)
  try await queue.enqueue(report, documents: f.documents)
  for _ in 0..<100 where await transport.count() == 0 { try await Task.sleep(for: .milliseconds(10)) }
  #expect(await transport.data(report.id) != nil)
  #expect(try await f.outbox(transport).flush() == 0)
  #expect(await transport.count() == 1)
  await queue.stop()
}

#if canImport(CloudKit)
private actor SchemaCloudSource: CloudReportSource {
  let report: BugReport
  let payload: URL
  var queryError: CKError? = CKError(.unknownItem)
  var assetMissing = false
  var assetRequests = 0

  init(report: BugReport, payload: URL) { self.report = report; self.payload = payload }
  func accountID() -> String { "fixture-owner" }
  func setQueryError(_ error: CKError?) { queryError = error }
  func setAssetMissing() { assetMissing = true }
  func requests() -> Int { assetRequests }

  func reports() async throws -> [CloudReportRecord] {
    let error = queryError
    let records = [CloudReportRecord(name: report.id.uuidString, bundle: report.bundle)]
    // Exercise the same first-query boundary as the native CloudKit source, without contacting a service.
    return try await initialCloudReportPage {
      if let error { throw error }
      return records
    } ?? []
  }

  func asset(for id: UUID) throws -> CloudReportAsset {
    assetRequests += 1
    if assetMissing { throw CKError(.unknownItem) }
    return CloudReportAsset(bundle: report.bundle, file: payload)
  }
}

@Test func cloudReceiverWithoutRecordTypeIsEmptyThenFindsTheFirstUpload() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let report = try f.report()
  let payload = f.root.appendingPathComponent("asset.json")
  try CloudReportPayload.capture(report, documents: f.documents).encoded().write(to: payload)
  let source = SchemaCloudSource(report: report, payload: payload)
  let events = CloudEvents()
  let receiver = CloudReportInbox(source: source, logger: events.logger)
  let mac = f.root.appendingPathComponent("mac")

  #expect(try await receiver.download(to: mac) == 0)
  #expect(await source.requests() == 0)
  #expect(!FileManager.default.fileExists(atPath: mac.appendingPathComponent(report.id.uuidString).path))
  #expect(events.all.isEmpty)

  await source.setQueryError(nil)  // The first sender upload has created the schema/record.
  #expect(try await receiver.download(to: mac) == 1)
  #expect(CloudReportPayload.isComplete(mac.appendingPathComponent(report.id.uuidString)))
  #expect(try await receiver.download(to: mac) == 0)
  #expect(await source.requests() == 1)
  #expect(events.all.contains { $0.0 == "cloudkit_downloaded" && $0.1["id"] == .string(report.id.uuidString) })
}

@Test(arguments: [CKError.Code.notAuthenticated, .networkUnavailable, .invalidArguments, .zoneNotFound])
func cloudReceiverOtherQueryFailuresRemainFailures(_ code: CKError.Code) async throws {
  let f = CloudFixture(); defer { f.clean() }
  let report = try f.report()
  let source = SchemaCloudSource(report: report, payload: f.root.appendingPathComponent("unused.json"))
  await source.setQueryError(CKError(code))
  let receiver = CloudReportInbox(source: source, logger: { _, _ in })
  await #expect(throws: CKError.self) { try await receiver.download(to: f.root.appendingPathComponent("mac")) }
  #expect(await source.requests() == 0)
}

@Test func cloudReceiverMissingAssetIsNotAnEmptySchemaSuccess() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let report = try f.report()
  let source = SchemaCloudSource(report: report, payload: f.root.appendingPathComponent("unused.json"))
  await source.setQueryError(nil)
  await source.setAssetMissing()
  let events = CloudEvents()
  let receiver = CloudReportInbox(source: source, logger: events.logger)
  let mac = f.root.appendingPathComponent("mac")
  await #expect(throws: CKError.self) { try await receiver.download(to: mac) }
  #expect(await source.requests() == 1)
  #expect(!CloudReportPayload.isComplete(mac.appendingPathComponent(report.id.uuidString)))
  #expect(events.all.contains { $0.0 == "cloudkit_report_pending" && $0.1["id"] == .string(report.id.uuidString) })
}

@Test func nativeUploadHasNoShortResourceDeadlineAndAccountRetriesBackOff() throws {
  let report = BugReport(app: "fixture", bundle: "local.fixture", build: "1", commit: "fixture", device: "synthetic",
                         screen: "home", note: "fixture", folder: "bugs/sample")
  let operation = NativeCloudReportTransport.uploadOperation(report, payload: URL(fileURLWithPath: "/dev/null"))
  #expect(operation.configuration.timeoutIntervalForResource == CKOperation.Configuration().timeoutIntervalForResource)
  #expect(operation.configuration.allowsCellularAccess && operation.configuration.isLongLived)
  #expect(operation.recordsToSave?.first?.recordID.recordName == report.id.uuidString)
  let transport = NativeCloudReportTransport(containerIdentifier: "iCloud.com.example.BugKitReports")
  let delays = (0..<8).map { transport.retryDelay(for: CloudDeliveryError.accountUnavailable, attempt: $0) }
  #expect(delays == [5, 10, 20, 40, 80, 160, 300, 300])
}

private func acknowledgedRecord(_ report: BugReport) -> CKRecord {
  let record = CKRecord(recordType: "BugKitReport", recordID: CKRecord.ID(recordName: report.id.uuidString))
  record["bundle"] = report.bundle as CKRecordValue
  return record
}

@Test func nativeAcknowledgmentRequiresTheSpecificSavedRecord() throws {
  let f = CloudFixture(); defer { f.clean() }
  let report = try f.report()
  let ack = CloudRecordSaveAcknowledgement(report: report)
  let record = acknowledgedRecord(report)
  ack.observe(record.recordID, result: .success(record))
  try ack.finish(.success(()))
}

@Test func nativeOperationSuccessWithoutRecordAcknowledgmentIsNotUploadSuccess() throws {
  let f = CloudFixture(); defer { f.clean() }
  let ack = CloudRecordSaveAcknowledgement(report: try f.report())
  #expect(throws: CloudDeliveryError.invalidAcknowledgement) { try ack.finish(.success(())) }
}

@Test func nativePerRecordFailureSurvivesOverallSuccess() throws {
  let f = CloudFixture(); defer { f.clean() }
  let report = try f.report()
  let ack = CloudRecordSaveAcknowledgement(report: report)
  ack.observe(CKRecord.ID(recordName: report.id.uuidString), result: .failure(CKError(.serverResponseLost)))
  #expect { try ack.finish(.success(())) } throws: { ($0 as? CKError)?.code == .serverResponseLost }
}

@Test func nativeOverallFailureSurvivesMatchingRecordSuccess() throws {
  let f = CloudFixture(); defer { f.clean() }
  let report = try f.report()
  let ack = CloudRecordSaveAcknowledgement(report: report)
  let record = acknowledgedRecord(report)
  ack.observe(record.recordID, result: .success(record))
  #expect(throws: CKError.self) { try ack.finish(.failure(CKError(.networkFailure))) }
}

@Test(arguments: ["callbackID", "savedID", "zone", "bundle", "missingBundle", "type", "duplicate"])
func nativeAcknowledgmentRejectsUnrelatedOrAmbiguousSave(_ mismatch: String) throws {
  let f = CloudFixture(); defer { f.clean() }
  let report = try f.report()
  let ack = CloudRecordSaveAcknowledgement(report: report)
  let expected = CKRecord.ID(recordName: report.id.uuidString)
  let other = CKRecord.ID(recordName: UUID().uuidString)
  let savedID = mismatch == "savedID" ? other : mismatch == "zone"
    ? CKRecord.ID(recordName: report.id.uuidString, zoneID: CKRecordZone.ID(zoneName: "other")) : expected
  let record = CKRecord(recordType: mismatch == "type" ? "Other" : "BugKitReport", recordID: savedID)
  if mismatch != "missingBundle" {
    record["bundle"] = (mismatch == "bundle" ? "local.other" : report.bundle) as CKRecordValue
  }
  ack.observe(mismatch == "callbackID" ? other : expected, result: .success(record))
  if mismatch == "duplicate" { ack.observe(expected, result: .success(record)) }
  #expect(throws: CloudDeliveryError.invalidAcknowledgement) { try ack.finish(.success(())) }
}

@Test func nativeInvalidAcknowledgementWaitsForLaterStartWithoutChangingRetryPolicy() {
  let transport = NativeCloudReportTransport(containerIdentifier: "iCloud.com.example.BugKitReports")
  #expect(transport.retryDelay(for: CloudDeliveryError.invalidAcknowledgement, attempt: 0) == nil)
  #expect(transport.retryDelay(for: CKError(.networkFailure), attempt: 0) != nil)
  #expect(transport.retryDelay(for: CKError(.permissionFailure), attempt: 0) == nil)
}

private actor AcknowledgingCloudTransport: CloudReportTransport {
  enum Mode { case wrongBundle, nativeFailure, matching }
  var mode = Mode.wrongBundle
  func accountID() -> String { "fixture-owner" }
  func set(_ next: Mode) { mode = next }
  func upload(_ report: BugReport, payload: URL) throws {
    let ack = CloudRecordSaveAcknowledgement(report: report)
    let record = acknowledgedRecord(report)
    switch mode {
    case .wrongBundle:
      record["bundle"] = "local.other" as CKRecordValue
      ack.observe(record.recordID, result: .success(record))
    case .nativeFailure: ack.observe(record.recordID, result: .failure(CKError(.networkFailure)))
    case .matching: ack.observe(record.recordID, result: .success(record))
    }
    try ack.finish(.success(()))
  }
}

@Test func cloudOutboxKeepsUnacknowledgedSavePendingUntilMatchingSave() async throws {
  let f = CloudFixture(); defer { f.clean() }
  let transport = AcknowledgingCloudTransport()
  let events = CloudEvents()
  let queue = CloudReportOutbox(store: f.store, root: f.outboxRoot, transport: transport, logger: events.logger)
  try await queue.prepare(documents: f.documents)
  let report = try f.report()
  try f.store.append(report)
  await #expect(throws: CloudDeliveryError.invalidAcknowledgement) { try await queue.flush() }
  let pending = f.outboxRoot.appendingPathComponent("pending/" + report.id.uuidString + ".json")
  let sent = f.outboxRoot.appendingPathComponent("sent/" + report.id.uuidString + ".json")
  #expect(FileManager.default.fileExists(atPath: pending.path))
  #expect(!FileManager.default.fileExists(atPath: sent.path))
  #expect(!events.all.contains { $0.0 == "bug_delivery_uploaded" })
  #expect(events.all.contains { $0.0 == "bug_delivery_pending"
    && $0.1["reason"] == .string("server acknowledgment missing or invalid") })
  await transport.set(.nativeFailure)
  await #expect { try await queue.flush() } throws: { ($0 as? CKError)?.code == .networkFailure }
  #expect(events.all.last { $0.0 == "bug_delivery_pending" }?.1["reason"] == nil)
  #expect(FileManager.default.fileExists(atPath: pending.path))
  #expect(!FileManager.default.fileExists(atPath: sent.path))
  await transport.set(.matching)
  #expect(try await queue.flush() == 1)
  #expect(!FileManager.default.fileExists(atPath: pending.path))
  #expect(FileManager.default.fileExists(atPath: sent.path))
  #expect(events.all.filter { $0.0 == "bug_delivery_uploaded" }.count == 1)
  #expect(try f.store.readAll().reports == [report])
}

#endif
