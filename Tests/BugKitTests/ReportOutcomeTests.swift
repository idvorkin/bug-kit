import Foundation
import Testing

@testable import BugKit

// #120: what became of a report, so an app's "Sent ✓" says what happened rather than that the dialog closed.

private struct Delivery: BugReportDelivery {
  let fails: Bool
  struct Refused: Error {}
  func enqueue(_ report: BugReport, documents: URL) async throws { if fails { throw Refused() } }
}

private let info = BugAppInfo(app: "Demo", bundle: "com.example.demo", build: "1.0 (1)", commit: "abc1234", device: "iPhone18,1")

private func folder(_ name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("bugkit-outcome-\(name)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func save(_ writer: BugReportWriter) async -> (report: BugReport, indexWritten: Bool, outcome: BugReportOutcome) {
  await writer.write(note: "It froze", screen: "home", context: [:], screenshotPNG: nil, log: nil, extraFiles: nil)
}

@Suite struct ReportOutcomeTests {
  @Test func aReportWithNoDeliveryIsSavedButNotQueued() async throws {
    let store = BugStore(documents: try folder("local"))
    let saved = await save(BugReportWriter(store: store, info: info, logger: { _, _ in }))
    #expect(saved.outcome == .saved(id: saved.report.id, queued: false))
    #expect(saved.outcome.isSaved)
    #expect(try store.readAll().reports.map(\.id) == [saved.report.id])
  }

  @Test func aReportTheDeliveryTookIsQueued() async throws {
    let store = BugStore(documents: try folder("queued"))
    let saved = await save(BugReportWriter(store: store, info: info, logger: { _, _ in }, delivery: Delivery(fails: false)))
    #expect(saved.outcome == .saved(id: saved.report.id, queued: true))
  }

  @Test func aReportTheDeliveryRefusedIsSavedLocallyOnly() async throws {
    let store = BugStore(documents: try folder("refused"))
    let saved = await save(BugReportWriter(store: store, info: info, logger: { _, _ in }, delivery: Delivery(fails: true)))
    #expect(saved.outcome == .saved(id: saved.report.id, queued: false))
  }

  @Test func aReportBugsJsonlDidNotTakeFailed() async throws {
    let docs = try folder("failed")
    let store = BugStore(documents: docs)
    // The index cannot be written: it links into a folder that is not there.
    try FileManager.default.createSymbolicLink(
      at: store.index, withDestinationURL: docs.appendingPathComponent("missing/bugs.jsonl"))
    let saved = await save(BugReportWriter(store: store, info: info, logger: { _, _ in }, delivery: Delivery(fails: false)))
    #expect(saved.outcome == .failed(id: saved.report.id))
    #expect(!saved.outcome.isSaved)
    #expect(!BugReportOutcome.cancelled.isSaved)
  }
}
