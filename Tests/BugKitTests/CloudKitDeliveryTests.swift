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
  await #expect(throws: CloudDeliveryError.accountChanged) { try await f.outbox(transport).flush() }
  #expect(await transport.count() == 1)
}

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
#endif
