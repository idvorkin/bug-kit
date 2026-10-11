import Foundation
import Testing
@testable import BugKit

@Test func watchNoteUsesSharedIndexAndCopiesSessionEvidence() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = BugStore(documents: root)
  let log = SessionLog(prefix: "watch", documents: root)
  log.event("card_shown", ["card": .int(7)])
  let info = BugAppInfo(app: "Cards", bundle: "com.example.Cards.watch", build: "1", commit: "test", device: "Watch")
  let writer = BugReportWriter(store: store, info: info, logger: log.logger, copySessionLog: true)
  let session = WatchBugReportSession(writer: writer, screen: "card", context: ["card": .int(7)], log: log)
  let report = try await session.save(note: "  Wrong card  ")
  #expect(report.note == "Wrong card")
  #expect(report.screen == "card")
  #expect(report.context == ["card": .int(7)])
  #expect(report.screenshot == nil)
  #expect(report.log == log.relativePath)
  #expect(try store.readAll().reports == [report])
  let copy = root.appendingPathComponent(report.folder).appendingPathComponent("session.jsonl")
  let events = try String(contentsOf: copy, encoding: .utf8).split(separator: "\n")
    .map { try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) }
  #expect(events.contains { $0["type"] == .string("card_shown") && $0["card"] == .int(7) })
}

@Test func watchBlankNoteAndUnwritableStoreDoNotReportSuccess() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let info = BugAppInfo(app: "Cards", bundle: "com.example.Cards.watch", build: "1", commit: "test", device: "Watch")
  let store = BugStore(documents: root)
  let session = WatchBugReportSession(writer: BugReportWriter(store: store, info: info, logger: { _, _ in }), screen: "card")
  await #expect(throws: WatchBugReportSession.SaveError.emptyNote) { try await session.save(note: " \n ") }
  #expect(!FileManager.default.fileExists(atPath: store.index.path))
  try Data("This is a file, not a directory".utf8).write(to: root)
  await #expect(throws: (any Error).self) { try await session.save(note: "Keep this note") }
}
