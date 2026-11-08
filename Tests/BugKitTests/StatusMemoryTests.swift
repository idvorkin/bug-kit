import Foundation
import Testing

@testable import BugKit

// MM special sauce: resident memory on the status line, so a leak shows in the log.

// Mach task_info: residentMegabytes() is nil off Darwin.
#if canImport(Darwin)
@Test func residentMemoryIsReadable() throws {
  let mb = try #require(SessionLog.residentMegabytes())
  #expect(mb > 0 && mb < 100_000)
}

@Test func theStatusLineCarriesRSSWhenAsked() async throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bugkit-rss-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: dir) }
  let log = SessionLog(prefix: "app", documents: dir)
  log.status("with_memory", every: 0.05, memory: true) { ["n": 1] }
  log.status("without_memory", every: 0.05) { ["n": 1] }
  let lines = {
    log.flush()
    return ((try? String(contentsOf: log.url, encoding: .utf8)) ?? "").split(separator: "\n")
      .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
  }
  let of = { (type: String) in lines().filter { $0["type"] as? String == type } }
  // Wait for both lines, not a fixed time: a busy CI runner can hold a utility-QoS timer for longer (bug-ej9).
  let deadline = ContinuousClock.now + .seconds(10)
  while of("with_memory").isEmpty || of("without_memory").isEmpty, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(50))
  }
  let with = of("with_memory")
  let without = of("without_memory")
  #expect(!with.isEmpty && with.allSatisfy { ($0["rss_mb"] as? Int ?? 0) > 0 })
  #expect(!without.isEmpty && without.allSatisfy { $0["rss_mb"] == nil })
}
#endif
