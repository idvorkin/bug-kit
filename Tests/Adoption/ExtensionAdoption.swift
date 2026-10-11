// This consumer is compiled with -application-extension in CI. Host UI stays unavailable.
import BugKit
import Foundation

func extensionEvidence(root: URL, info: BugAppInfo) async throws -> BugReport {
  let store = BugStore(documents: root)
  let log = SessionLog(prefix: "extension", documents: root)
  log.event("extension_started", [:])
  log.flush()
  let writer = BugReportWriter(store: store, info: info, logger: log.logger)
  return await writer.save(note: "Extension evidence", screen: "keyboard", context: [:],
                           screenshotPNG: nil, log: log.position, extraFiles: nil)
}
