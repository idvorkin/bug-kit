#if os(watchOS)
import BugKit
import SwiftUI

@MainActor func watchReportSheet(store: BugStore, info: BugAppInfo, log: SessionLog) -> some View {
  let delivery = CloudKitReportDelivery(containerIdentifier: "iCloud.com.example.BugKitReports", store: store, logger: log.logger)
  let writer = BugReportWriter(store: store, info: info, logger: log.logger, copySessionLog: true, delivery: delivery)
  Task { await delivery.start() }
  return WatchBugReportView(session: WatchBugReportSession(writer: writer, screen: "card", log: log))
}
#endif
