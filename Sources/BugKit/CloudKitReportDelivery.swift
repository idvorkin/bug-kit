#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

/// Opt-in delivery to the owner's private CloudKit database. The app must carry the container entitlement.
/// Delivers only reports saved after opt-in; reports/evidence are never deleted from BugStore.
public actor CloudKitReportDelivery: BugReportDelivery {
  private let outbox: CloudReportOutbox

  public init(containerIdentifier: String, store: BugStore = BugStore(), logger: @escaping BugLogger) {
    let name = SHA256.hash(data: Data(containerIdentifier.utf8)).map { String(format: "%02x", $0) }.joined()
    outbox = CloudReportOutbox(
      store: store, root: store.documents.appendingPathComponent("bug-delivery/cloudkit-" + name),
      transport: NativeCloudReportTransport(containerIdentifier: containerIdentifier), logger: logger)
  }

  /// Persist activation before exposing a writer/reporter; no iCloud request or permission is needed.
  public func prepare(documents: URL) async throws {
    try await outbox.prepare(documents: documents)
  }

  public func enqueue(_ report: BugReport, documents: URL) async throws {
    try await outbox.enqueue(report, documents: documents)
  }

  /// Record the opt-in boundary, start automatic backoff retries and recover reports saved since opt-in.
  /// Call at launch and foreground.
  public func start() async { await outbox.start() }
  /// Stop app-level retry timers; an already submitted long-lived CloudKit operation can still finish.
  public func stop() async { await outbox.stop() }

  /// One upload pass; start() also handles retries after transient failures. Returns uploads this pass.
  @discardableResult public func flush() async throws -> Int { try await outbox.flush() }
}

struct NativeCloudReportTransport: CloudReportTransport {
  let containerIdentifier: String
  var container: CKContainer { CKContainer(identifier: containerIdentifier) }

  func accountID() async throws -> String {
    guard try await container.accountStatus() == .available else { throw CloudDeliveryError.accountUnavailable }
    return try await container.userRecordID().recordName
  }

  func upload(_ report: BugReport, payload: URL) async throws {
    // Persist the daemon operation ID beside immutable evidence; reattach callbacks after app restart.
    let operationFile = payload.deletingPathExtension().appendingPathExtension("operation")
    var restored: CKModifyRecordsOperation?
    if FileManager.default.fileExists(atPath: operationFile.path) {
      let id = try String(contentsOf: operationFile, encoding: .utf8)
      restored = try await container.longLivedOperation(for: id) as? CKModifyRecordsOperation
    }
    let operation = restored ?? Self.uploadOperation(report, payload: payload)
    if restored == nil { try Data(operation.operationID.utf8).write(to: operationFile, options: .atomic) }
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        operation.modifyRecordsResultBlock = { result in continuation.resume(with: result) }
        container.privateCloudDatabase.add(operation)
      }
      try? FileManager.default.removeItem(at: operationFile)
    } catch {
      try? FileManager.default.removeItem(at: operationFile)
      throw error
    }
  }

  /// Large evidence over a slow cellular uplink can take many minutes; only an idle request times out.
  static func uploadOperation(_ report: BugReport, payload: URL) -> CKModifyRecordsOperation {
    let record = CKRecord(recordType: "BugKitReport", recordID: CKRecord.ID(recordName: report.id.uuidString))
    record["bundle"] = report.bundle as CKRecordValue
    record["reportedAt"] = report.reportedAt as CKRecordValue
    record["payload"] = CKAsset(fileURL: payload)
    let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
    operation.savePolicy = .allKeys
    operation.isAtomic = false
    operation.configuration.allowsCellularAccess = true
    operation.configuration.isLongLived = true
    operation.configuration.qualityOfService = .userInitiated
    operation.configuration.timeoutIntervalForRequest = 60
    return operation
  }

  func retryDelay(for error: any Error, attempt: Int) -> TimeInterval? {
    if error as? CloudDeliveryError == .accountUnavailable { return cloudRetryBackoff(attempt: attempt) }
    guard let error = error as? CKError else { return nil }
    if let delay = error.retryAfterSeconds { return max(1, delay) }
    if error.code == .partialFailure, let errors = error.partialErrorsByItemID {
      let delays = errors.values.compactMap { retryDelay(for: $0, attempt: attempt) }
      return delays.count == errors.count ? delays.max() : nil
    }
    switch error.code {
    case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
         .zoneBusy, .serverResponseLost, .accountTemporarilyUnavailable, .notAuthenticated:
      return cloudRetryBackoff(attempt: attempt)
    default: return nil
    }
  }
}

/// Downloads private reports to an atomic local inbox for the Mac listener. Requires the same iCloud account
/// and shared container entitlement as the sending apps. Does not file issues or delete cloud records.
public actor CloudKitReportReceiver {
  private let inbox: CloudReportInbox
  public init(containerIdentifier: String, logger: @escaping BugLogger = { _, _ in }) {
    inbox = CloudReportInbox(source: NativeCloudReportSource(containerIdentifier: containerIdentifier), logger: logger)
  }
  @discardableResult public func download(to directory: URL) async throws -> Int {
    try await inbox.download(to: directory)
  }
}

/// Before the first upload creates BugKitReport, its initial query returns unknownItem. Normalize that one
/// listing boundary to an empty page; cursor and asset errors must still fail the sync.
func initialCloudReportPage<Page: Sendable>(
  _ query: @Sendable () async throws -> Page
) async throws -> Page? {
  do { return try await query() }
  catch let error as CKError where error.code == .unknownItem { return nil }
}

private struct NativeCloudReportSource: CloudReportSource {
  let containerIdentifier: String
  var container: CKContainer { CKContainer(identifier: containerIdentifier) }

  func accountID() async throws -> String {
    guard try await container.accountStatus() == .available else { throw CloudDeliveryError.accountUnavailable }
    return try await container.userRecordID().recordName
  }

  func reports() async throws -> [CloudReportRecord] {
    let database = container.privateCloudDatabase
    let query = CKQuery(recordType: "BugKitReport", predicate: NSPredicate(value: true))
    guard var page = try await initialCloudReportPage({
      try await database.records(matching: query, desiredKeys: ["bundle"], resultsLimit: 100)
    }) else { return [] }
    var reports: [CloudReportRecord] = []
    while true {
      for (id, result) in page.matchResults {
        switch result {
        case .success(let record):
          reports.append(CloudReportRecord(name: id.recordName, bundle: record["bundle"] as? String))
        case .failure(let error):
          reports.append(CloudReportRecord(name: id.recordName, bundle: nil, error: error))
        }
      }
      guard let cursor = page.queryCursor else { break }
      page = try await database.records(continuingMatchFrom: cursor, desiredKeys: ["bundle"], resultsLimit: 100)
    }
    return reports
  }

  func asset(for id: UUID) async throws -> CloudReportAsset {
    let record = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: id.uuidString))
    guard let asset = record["payload"] as? CKAsset, let file = asset.fileURL,
          let bundle = record["bundle"] as? String else { throw CloudDeliveryError.invalidPayload }
    return CloudReportAsset(bundle: bundle, file: file)
  }
}
#endif
