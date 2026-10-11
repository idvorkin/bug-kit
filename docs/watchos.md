# watchOS adoption

Pin BugKit v0.3.2 in the watch app target. watchOS 10+ builds `BugReport`, `BugStore`, `SessionLog`, `BugReportWriter`, `CrashReports` and the opt-in CloudKit sender. UIKit, phone shake detection and the phone report sheet are excluded. `CrashReports` installs local signal/exception handlers; watchOS has no MetricKit diagnostics subscription in BugKit. These handlers are best-effort evidence and cannot capture every system termination.

Create one store/log/delivery at watch launch and retain them for the app's lifetime:

```swift
let store = BugStore()
let log = SessionLog(prefix: "watch", documents: store.documents)
CrashReports.shared.install(folder: store.documents.appendingPathComponent("crashes"), logger: log.logger)
let info = BugAppInfo.fromMainBundle(device: "\(BugAppInfo.hardwareModel()) watchOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
let delivery = CloudKitReportDelivery(
  containerIdentifier: "iCloud.com.example.BugKitReports", store: store, logger: log.logger)
let writer = BugReportWriter(store: store, info: info, logger: log.logger,
                            copySessionLog: true, delivery: delivery)
Task { await delivery.start() }
```

Present the system-text-input form from the watch app's own sheet or navigation:

```swift
WatchBugReportView(session: WatchBugReportSession(
  writer: writer, screen: "card", context: ["card": .int(7)], log: log))
```

`TextFieldLink` lets the person enter the note through the watch's system input. The form refuses blank notes and dismisses only after the report is in `bugs.jsonl`. A failed save keeps the note available to retry. The report has the same UUID, context and session evidence as phone reports, and has no screenshot. Apps with an existing watch input UI can call `try await session.save(note:)` directly.

For delivery to the Mac without the paired phone, authorize the **watch app's own App ID** for the same private CloudKit container as the Mac reader, and add the iCloud/CloudKit capability to that watch target. Follow [the CloudKit adoption steps](integration.md#private-cloudkit-delivery), using your real container from local configuration. Keep the watch and Mac on the same iCloud account. Call `delivery.start()` at launch and whenever the watch becomes active. Already submitted long-lived uploads allow cellular delivery; retry resumes when the app runs again. This does not promise indefinite background execution on watchOS. Local reports remain the fallback when offline or signed out.

The Mac listener polls CloudKit independently of `devicectl` and files the report by its **watch bundle ID**, so add that bundle ID and repository to `apps.json` as well as any phone bundle ID. No WatchConnectivity relay or new report format is needed for the requested same-account path. CloudKit currently uploads post-opt-in bug reports and their referenced evidence; it does not separately upload stand-alone crash files or the pre-opt-in backlog. Keep Think a Card's existing watch pull path for those until separately migrated.

CI compiles the model, crash/session APIs and `WatchBugReportView` consumer against the watchOS SDK; host behavioral tests exercise local persistence and copied log evidence. A real watch input/cellular-to-Mac acceptance check still needs Igor: enter a fresh report, see its upload event, then verify one issue and one inbox line on the Mac within one successful listener poll. Do not retire the old watch reporter/pull scripts until this is verified on the device.
