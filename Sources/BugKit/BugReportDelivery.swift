import Foundation

/// An optional delivery queue. Called after the local report has been saved; enqueue must not await a network.
public protocol BugReportDelivery: Sendable {
  /// Establish durable activation before a writer can append a report. Never waits for a network.
  func prepare(documents: URL) async throws
  func enqueue(_ report: BugReport, documents: URL) async throws
}

extension BugReportDelivery {
  /// Existing delivery adapters without an opt-in boundary need no preparation.
  public func prepare(documents: URL) async throws {}
}

/// The immutable wire payload carried by a CloudKit asset. Paths remain relative to the storage root.
struct CloudReportPayload: Codable, Sendable {
  var version = 1
  let report: BugReport
  let files: [String: Data]
  static let maxFileBytes = 20_000_000
  static let maxEncodedBytes = 30_000_000

  static func fileURL(_ path: String, under root: URL) throws -> URL {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
          !path.contains("\\"), !path.contains("\0") else { throw CloudDeliveryError.invalidPath }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let url = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
    guard url.path.hasPrefix(base.path + "/") else { throw CloudDeliveryError.invalidPath }
    return url
  }

  static func capture(_ report: BugReport, documents: URL) throws -> Self {
    var files: [String: Data] = [:]
    var remaining = maxFileBytes
    let paths = Set(report.files + [report.screenshot, report.log].compactMap { $0 })
    guard paths.count <= 100 else { throw CloudDeliveryError.tooLarge }
    for path in paths.sorted() {
      let url = try fileURL(path, under: documents)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { throw CloudDeliveryError.invalidPath }
      guard let size = values.fileSize, size <= remaining else { throw CloudDeliveryError.tooLarge }
      // Bound the read even if an app log grows while it is being copied.
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: remaining + 1) ?? Data()
      guard data.count <= remaining else { throw CloudDeliveryError.tooLarge }
      remaining -= data.count
      files[path] = data
    }
    return Self(report: report, files: files)
  }

  func encoded() throws -> Data {
    let data = try JSONEncoder().encode(self)
    guard data.count <= Self.maxEncodedBytes else { throw CloudDeliveryError.tooLarge }
    return data
  }

  static func read(_ url: URL) throws -> Self {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maxEncodedBytes else { throw CloudDeliveryError.tooLarge }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxEncodedBytes + 1) ?? Data()
    guard data.count <= maxEncodedBytes else { throw CloudDeliveryError.tooLarge }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.version == 1, value.files.count <= 100,
          value.files.values.reduce(0, { $0 + $1.count }) <= maxFileBytes else {
      throw CloudDeliveryError.invalidPayload
    }
    let expected = Set(value.report.files + [value.report.screenshot, value.report.log].compactMap { $0 })
    guard expected == Set(value.files.keys) else { throw CloudDeliveryError.invalidPayload }
    return value
  }

  /// Publish the complete folder with one rename, so the listener never sees partially downloaded evidence.
  func install(in root: URL) throws -> URL {
    let destination = root.appendingPathComponent(report.id.uuidString)
    if Self.isComplete(destination) { return destination }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stage = root.appendingPathComponent(".\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: stage) }
    let documents = stage.appendingPathComponent("Documents")
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    for (path, data) in files {
      let url = try Self.fileURL(path, under: documents)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    }
    try report.jsonLine().write(to: stage.appendingPathComponent("report.json"), options: .atomic)
    let lengths = files.mapValues { $0.count }
    try JSONEncoder().encode(lengths).write(to: stage.appendingPathComponent("files.json"), options: .atomic)
    let backup = root.appendingPathComponent(".old-\(UUID().uuidString)")
    let existed = FileManager.default.fileExists(atPath: destination.path)
    if existed { try FileManager.default.moveItem(at: destination, to: backup) }
    do { try FileManager.default.moveItem(at: stage, to: destination) }
    catch {
      if existed { try? FileManager.default.moveItem(at: backup, to: destination) }
      throw error
    }
    if existed { try? FileManager.default.removeItem(at: backup) }
    return destination
  }

  static func isComplete(_ destination: URL) -> Bool {
    do {
      guard try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
            try destination.appendingPathComponent("Documents").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return false }
      let report = try JSONDecoder().decode(BugReport.self, from: Data(contentsOf: destination.appendingPathComponent("report.json")))
      guard destination.lastPathComponent == report.id.uuidString else { return false }
      let sizes = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: destination.appendingPathComponent("files.json")))
      let expected = Set(report.files + [report.screenshot, report.log].compactMap { $0 })
      guard expected == Set(sizes.keys) else { return false }
      for (path, size) in sizes {
        let url = try fileURL(path, under: destination.appendingPathComponent("Documents"))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == size else { return false }
      }
      return true
    } catch { return false }
  }
}

public enum CloudDeliveryError: Error, Equatable, Sendable {
  case invalidPath, invalidPayload, tooLarge, wrongStore, accountUnavailable, accountChanged
}

protocol CloudReportTransport: Sendable {
  func accountID() async throws -> String
  func upload(_ report: BugReport, payload: URL) async throws
  func retryDelay(for error: any Error, attempt: Int) -> TimeInterval?
}

func cloudRetryBackoff(attempt: Int) -> TimeInterval { min(300, 5 * pow(2, Double(min(attempt, 6)))) }

extension CloudReportTransport {
  func retryDelay(for error: any Error, attempt: Int) -> TimeInterval? {
    guard error as? CloudDeliveryError == .accountUnavailable else { return nil }
    return cloudRetryBackoff(attempt: attempt)
  }
}

/// Durable outbox shared by the native adapter and fake-backed host tests.
actor CloudReportOutbox: BugReportDelivery {
  let store: BugStore
  let root: URL
  let transport: any CloudReportTransport
  let logger: BugLogger
  private var flushing: Task<Int, Error>?
  private var retrying: Task<Void, Never>?
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  init(store: BugStore, root: URL, transport: any CloudReportTransport, logger: @escaping BugLogger,
       sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
         try await Task.sleep(for: .seconds(seconds))
       }) {
    self.store = store; self.root = root; self.transport = transport; self.logger = logger
    self.sleep = sleep
  }

  func prepare(documents: URL) throws {
    guard documents.standardizedFileURL == store.documents.standardizedFileURL else {
      throw CloudDeliveryError.wrongStore
    }
    _ = try preexistingReports()
  }

  func enqueue(_ report: BugReport, documents: URL) async throws {
    guard documents.standardizedFileURL == store.documents.standardizedFileURL else {
      throw CloudDeliveryError.wrongStore
    }
    _ = try preexistingReports(eligible: report.id)
    try stage(report)
    logger("bug_delivery_queued", ["id": .string(report.id.uuidString), "transport": "cloudkit"])
    start()
  }

  /// Retain one outbox per store. Start at launch/foreground to recover after suspension or termination.
  func start() {
    do { _ = try preexistingReports() }
    catch { logger("bug_delivery_pending", ["transport": "cloudkit", "reason": "opt-in boundary could not be recorded"]) }
    guard retrying == nil else { return }
    retrying = Task { await self.retryUntilIdle() }
  }

  func stop() { retrying?.cancel() }

  private func retryUntilIdle() async {
    defer { retrying = nil }
    var attempt = 0
    while !Task.isCancelled {
      do {
        _ = try await flush()
        // Unstageable evidence stays local and logged; enqueue or the next start() stages it again.
        let queued = (try? FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil))?
          .contains { $0.pathExtension == "json" } ?? false
        if !queued { return }
        attempt = 0
      } catch {
        if Task.isCancelled { return }
        guard let delay = transport.retryDelay(for: error, attempt: attempt) else {
          logger("bug_delivery_stopped", ["transport": "cloudkit", "reason": "configuration, account or evidence requires attention"])
          return
        }
        logger("bug_delivery_retry", ["transport": "cloudkit", "after_seconds": .double(delay), "attempt": .int(attempt + 1)])
        attempt += 1
        do { try await sleep(delay) } catch { return }
      }
    }
  }

  /// Reports saved before opt-in stay local. Recorded by ID once, so later saves stay eligible after a crash
  /// before enqueue, and an enqueued report is never excluded by a boundary recorded concurrently.
  private func preexistingReports(eligible id: UUID? = nil) throws -> Set<String> {
    let file = root.appendingPathComponent("preexisting.json")
    var ids: Set<String>
    if FileManager.default.fileExists(atPath: file.path) {
      ids = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))
      guard let id, ids.contains(id.uuidString) else { return ids }
    } else {
      ids = Set(try store.readAll().reports.map(\.id.uuidString))
    }
    if let id { ids.remove(id.uuidString) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(ids).write(to: file, options: .atomic)
    return ids
  }

  private var pending: URL { root.appendingPathComponent("pending") }
  private var sent: URL { root.appendingPathComponent("sent") }
  private func stage(_ report: BugReport) throws {
    let name = report.id.uuidString + ".json"
    guard !FileManager.default.fileExists(atPath: sent.appendingPathComponent(name).path),
          !FileManager.default.fileExists(atPath: pending.appendingPathComponent(name).path) else { return }
    let data = try CloudReportPayload.capture(report, documents: store.documents).encoded()
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    try data.write(to: pending.appendingPathComponent(name), options: .atomic)
  }

  /// Resume persisted work and stage reports saved after opt-in that could not be staged earlier.
  /// Call at app launch/foreground or when connectivity returns. One upload pass is shared by concurrent calls.
  func flush() async throws -> Int {
    if let flushing { return try await flushing.value }
    let task = Task { try await self.drain() }
    flushing = task
    defer { flushing = nil }
    return try await task.value
  }

  private func drain() async throws -> Int {
    // Account switches must not silently deliver an old account's reports to the new account.
    let account = try await transport.accountID()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binding = root.appendingPathComponent("account.txt")
    if FileManager.default.fileExists(atPath: binding.path) {
      guard try String(contentsOf: binding, encoding: .utf8) == account else {
        throw CloudDeliveryError.accountChanged
      }
    } else { try Data(account.utf8).write(to: binding, options: .atomic) }
    let preexisting = try preexistingReports()
    for report in try store.readAll().reports where !preexisting.contains(report.id.uuidString) {
      do { try stage(report) }
      catch {
        logger("bug_delivery_pending", ["id": .string(report.id.uuidString), "transport": "cloudkit",
                                        "reason": "evidence could not be staged"])
      }
    }
    var count = 0
    var evidenceError: (any Error)?
    let urls = (try? FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)) ?? []
    for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }).prefix(100) {
      if FileManager.default.fileExists(atPath: sent.appendingPathComponent(url.lastPathComponent).path) {
        try FileManager.default.removeItem(at: url)
        continue
      }
      let payload: CloudReportPayload
      do { payload = try CloudReportPayload.read(url) }
      catch {
        evidenceError = error
        logger("bug_delivery_pending", ["id": .string(url.deletingPathExtension().lastPathComponent),
                                        "transport": "cloudkit", "reason": "invalid queued evidence"])
        continue
      }
      guard url.lastPathComponent == payload.report.id.uuidString + ".json" else {
        evidenceError = CloudDeliveryError.invalidPayload
        continue
      }
      guard try await transport.accountID() == account else { throw CloudDeliveryError.accountChanged }
      logger("bug_delivery_uploading", ["id": .string(payload.report.id.uuidString), "transport": "cloudkit"])
      do { try await transport.upload(payload.report, payload: url) }
      catch {
        logger("bug_delivery_pending", ["id": .string(payload.report.id.uuidString), "transport": "cloudkit"])
        throw error
      }
      try FileManager.default.createDirectory(at: sent, withIntermediateDirectories: true)
      try Data().write(to: sent.appendingPathComponent(url.lastPathComponent), options: .atomic)
      try FileManager.default.removeItem(at: url)
      logger("bug_delivery_uploaded", ["id": .string(payload.report.id.uuidString), "transport": "cloudkit"])
      count += 1
    }
    if let evidenceError { throw evidenceError }
    return count
  }
}

/// One listed CloudKit record before validation; a per-record query error or bad metadata stays per-record.
struct CloudReportRecord: Sendable {
  let name: String
  let bundle: String?
  var error: (any Error)? = nil
}

struct CloudReportAsset: Sendable {
  let bundle: String
  let file: URL
}

protocol CloudReportSource: Sendable {
  func accountID() async throws -> String
  func reports() async throws -> [CloudReportRecord]
  func asset(for id: UUID) async throws -> CloudReportAsset
}

/// Shared receiver engine; a successful query alone is not delivery. Complete evidence must reach disk.
actor CloudReportInbox {
  let source: any CloudReportSource
  let logger: BugLogger
  init(source: any CloudReportSource, logger: @escaping BugLogger) { self.source = source; self.logger = logger }

  func download(to inbox: URL) async throws -> Int {
    let account = try await source.accountID()
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let binding = inbox.appendingPathComponent("account.txt")
    if FileManager.default.fileExists(atPath: binding.path) {
      guard try String(contentsOf: binding, encoding: .utf8) == account else { throw CloudDeliveryError.accountChanged }
    } else { try Data(account.utf8).write(to: binding, options: .atomic) }
    var count = 0
    var failure: (any Error)?
    for record in try await source.reports() {
      guard record.error == nil, let id = UUID(uuidString: record.name), let bundle = record.bundle else {
        failure = record.error ?? CloudDeliveryError.invalidPayload
        var fields: [String: JSONValue] = ["reason": "listing failed or record metadata is invalid"]
        if let id = UUID(uuidString: record.name) { fields["id"] = .string(id.uuidString) }
        logger("cloudkit_report_pending", fields)
        continue
      }
      if CloudReportPayload.isComplete(inbox.appendingPathComponent(id.uuidString)) { continue }
      guard try await source.accountID() == account else { throw CloudDeliveryError.accountChanged }
      do {
        let asset = try await source.asset(for: id)
        let payload = try CloudReportPayload.read(asset.file)
        guard payload.report.id == id, payload.report.bundle == bundle,
              asset.bundle == bundle else { throw CloudDeliveryError.invalidPayload }
        // Recheck after the asset request too; account may change during a network wait.
        guard try await source.accountID() == account else { throw CloudDeliveryError.accountChanged }
        _ = try payload.install(in: inbox)
        logger("cloudkit_downloaded", ["id": .string(id.uuidString), "bundle": .string(bundle)])
        count += 1
      } catch {
        if error as? CloudDeliveryError == .accountChanged { throw error }
        failure = error
        logger("cloudkit_report_pending", ["id": .string(id.uuidString), "reason": "download or evidence validation failed"])
      }
    }
    // Valid reports still arrive in the same poll even when another report is malformed/unavailable.
    if let failure { throw failure }
    return count
  }
}
