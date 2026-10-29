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

// MARK: - Log retention (EA #72, CG story 145)

@Test func oldLogsGoExceptOnesAReportNames() throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let logs = docs.appendingPathComponent("logs")
  try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
  let now = Date()
  let old = now.addingTimeInterval(-40 * 24 * 3600)
  for (name, date) in [("a-old.jsonl", old), ("b-old-reported.jsonl", old), ("c-new.jsonl", now), ("d-old-bare.jsonl", old)] {
    let url = logs.appendingPathComponent(name)
    try Data("x\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }
  let store = BugStore(documents: docs)
  // One BugKit report (logs/ path) and one older-format line (bare name).
  try store.append(BugReport(app: "T", bundle: "b", build: "1", commit: "c", device: "d", screen: "s", note: "n",
    log: "logs/b-old-reported.jsonl", folder: "bugs/x"))
  let handle = try FileHandle(forWritingTo: store.index)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("{\"note\":\"old\",\"log\":\"d-old-bare.jsonl\"}\n".utf8))
  try handle.close()
  let events = Events()
  let deleted = store.pruneLogs(now: now, logger: events.logger)
  #expect(deleted == ["a-old.jsonl"])
  let left = try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
  #expect(left == ["b-old-reported.jsonl", "c-new.jsonl", "d-old-bare.jsonl"])
  #expect(events.names == ["logs_pruned"])
  #expect(events.all[0].1["count"] == 1 && events.all[0].1["kept_for_reports"] == 2)
}

// MM: logs of a few MB per launch, dozens of launches a day; a count cap as well as the age, reported ones kept.
@Test func keepNewestCapsTheCountAndStillKeepsReportedLogs() throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let logs = docs.appendingPathComponent("logs")
  try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
  let now = Date()
  for i in 0..<5 {  // log-0 newest … log-4 oldest, all within the 30 days
    let url = logs.appendingPathComponent("log-\(i).jsonl")
    try Data("x\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(i) * 60)], ofItemAtPath: url.path)
  }
  let store = BugStore(documents: docs)
  try store.append(BugReport(app: "T", bundle: "b", build: "1", commit: "c", device: "d", screen: "s", note: "n",
    log: "logs/log-3.jsonl", folder: "bugs/x"))
  let events = Events()
  #expect(store.pruneLogs(keepNewest: 2, now: now, logger: events.logger) == ["log-2.jsonl", "log-4.jsonl"])
  #expect(events.all[0].1["count"] == 2 && events.all[0].1["kept_for_reports"] == 1)
  #expect(LogRetention.prune(files: [("a", 1), ("b", 2)], referenced: [], keepNewest: 0) == ["a", "b"])
  #expect(LogRetention.prune(files: [("a", 1), ("b", 2)], referenced: []).isEmpty)  // no cap, none old: none go
}

@Test func pruningLogsALineEvenWhenNothingGoes() throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let events = Events()
  #expect(BugStore(documents: docs).pruneLogs(logger: events.logger).isEmpty)
  #expect(events.names == ["logs_pruned"] && events.all[0].1["count"] == 0)
}

@Test func anUnreadableIndexPrunesNothing() throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let store = BugStore(documents: docs)
  try Data([0xFF, 0xFE, 0x00]).write(to: store.index)  // not UTF-8
  let events = Events()
  #expect(store.pruneLogs(logger: events.logger).isEmpty)
  #expect(events.names == ["error"])
}

@Test func retentionKeepsTheBoundary() {
  let r = LogRetention.retentionSeconds
  #expect(LogRetention.prune(files: [("edge", r), ("past", r + 1)], referenced: []) == ["past"])
}

// MARK: - Crash files announced once (EA #87)

@Test func crashFilesAreAnnouncedOnceThenRenamed() throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try "signal 6\nframe 0\nframe 1".write(to: dir.appendingPathComponent("signal-100.txt"), atomically: true, encoding: .utf8)
  try "exception NSRangeException\nindex 3 beyond bounds".write(
    to: dir.appendingPathComponent("exception-101.txt"), atomically: true, encoding: .utf8)
  try "old".write(to: dir.appendingPathComponent("signal-50.reported.txt"), atomically: true, encoding: .utf8)
  try "{}".write(to: dir.appendingPathComponent("20261010-143000.json"), atomically: true, encoding: .utf8)
  let events = Events()
  let first = CrashReports.announcePending(in: dir, logger: events.logger)
  #expect(first == ["exception-101.txt", "signal-100.txt"])
  #expect(events.all.map { $0.1["kind"] } == ["exception", "signal"])
  #expect(events.all[1].1["top"] == "signal 6 | frame 0 | frame 1")
  #expect(CrashReports.announcePending(in: dir, logger: events.logger).isEmpty)  // the next launch: nothing again
  let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
  #expect(names.contains("signal-100.reported.txt") && names.contains("exception-101.reported.txt"))
  #expect(!names.contains { $0.contains(".reported.reported.") })
}

// MARK: - The session log (CG story 141)

@Test func sessionLogWritesOneLinePerEventWithTypeAndT() throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let log = SessionLog(prefix: "app", documents: docs, fields: ["build": "1 (1)"])
  log.event("set_saved", ["reps": 13, "type": "spoofed", "ratio": .double(.nan)])
  log.flush()
  #expect(log.relativePath.hasPrefix("logs/app-") && log.relativePath.hasSuffix(".jsonl"))
  let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
  #expect(lines.count == 2)
  let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
  let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
  #expect(first["type"] as? String == "session_start" && first["build"] as? String == "1 (1)")
  #expect(second["type"] as? String == "set_saved")  // a field cannot replace the line's own type
  #expect(second["reps"] as? Int == 13 && second["t"] is Int)
  #expect(second["ratio"] is NSNull)  // a NaN does not lose the line
}

@Test func aFailedWriteDropsTheLineInsteadOfCrashingAndIsCountedOnTheNext() throws {
  // The legacy FileHandle.write(_:) raises an uncatchable Objective-C exception on a full disk or a dead descriptor.
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let log = SessionLog(prefix: "app", documents: docs)
  log.flush()
  let fd = try #require(log.handle?.fileDescriptor)
  // Swap a read-only descriptor in underneath the handle, so every write fails with EBADF.
  let readOnly = open(log.url.path, O_RDONLY)
  #expect(readOnly >= 0)
  #expect(dup2(readOnly, fd) == fd)
  close(readOnly)
  log.event("lost_one")
  log.event("lost_two")
  log.flush()  // reaching here at all is the test: the old write raised and aborted the process
  // Put a writable descriptor back: the next line lands, preceded by one line counting what was lost.
  let writable = open(log.url.path, O_WRONLY | O_APPEND)
  #expect(writable >= 0)
  #expect(dup2(writable, fd) == fd)
  close(writable)
  log.event("after")
  log.flush()
  let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
  }
  #expect(lines.map { $0["type"] as? String } == ["session_start", "error", "after"])
  #expect(lines[1]["where"] as? String == "session_log" && lines[1]["dropped"] as? Int == 2)
}

@Test func aLongOutageIsCountedExactlyAndTheCountResetsForTheNextOutage() throws {
  // While the descriptor stays dead, every event after the first also fails on its count note; none may be miscounted.
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let log = SessionLog(prefix: "app", documents: docs)
  log.flush()
  let fd = try #require(log.handle?.fileDescriptor)
  func swap(_ flags: Int32) {
    let other = open(log.url.path, flags)
    #expect(other >= 0)
    #expect(dup2(other, fd) == fd)
    close(other)
  }
  swap(O_RDONLY)
  for i in 0..<5 { log.event("lost_\(i)") }
  log.flush()
  swap(O_WRONLY | O_APPEND)
  log.event("back1")
  log.event("back2")
  log.flush()
  swap(O_RDONLY)
  log.event("lost_again")
  log.flush()
  swap(O_WRONLY | O_APPEND)
  log.event("back3")
  log.flush()
  let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
  }
  #expect(lines.map { $0["type"] as? String } == ["session_start", "error", "back1", "back2", "error", "back3"])
  #expect(lines[1]["dropped"] as? Int == 5)
  #expect(lines[4]["dropped"] as? Int == 1)
}

@Test func twoLogsInOneSecondGetTheirOwnFiles() throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let now = Date()
  let a = SessionLog(prefix: "app", documents: docs, now: now)
  let b = SessionLog(prefix: "app", documents: docs, now: now)
  #expect(a.url != b.url)
}

@Test func theStatusLineRepeats() async throws {
  let docs = try tempDir()
  defer { try? FileManager.default.removeItem(at: docs) }
  let log = SessionLog(prefix: "app", documents: docs)
  log.status(every: 0.05) { ["frames": 1] }
  let statuses = {
    log.flush()
    return ((try? String(contentsOf: log.url, encoding: .utf8)) ?? "").components(separatedBy: "\"type\":\"status\"").count - 1
  }
  // Wait for the lines, not a fixed time: a busy CI runner can hold a utility-QoS timer for longer (bug-ej9).
  let deadline = ContinuousClock.now + .seconds(10)
  while statuses() < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
  #expect(statuses() >= 2)
}
