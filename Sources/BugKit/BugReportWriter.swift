import Foundation

/// The app's logger: BugKit sends it `bug_report` (and `error`) events so they land in the app's own session log,
/// next to everything else the app did at that moment.
public typealias BugLogger = @Sendable (_ event: String, _ fields: [String: JSONValue]) -> Void

/// Extra files for a report (EA's clip at the playhead, MM's recent video segments): write them into `folder` and
/// return their names. Thrown errors are logged and the report is saved without them.
public typealias BugExtraFiles = @Sendable (_ folder: URL) async throws -> [String]

/// Who made the report: the fixed fields that do not change within a launch.
public struct BugAppInfo: Equatable, Sendable {
  public var app: String
  public var bundle: String
  public var build: String
  public var commit: String
  public var device: String

  public init(app: String, bundle: String, build: String, commit: String, device: String) {
    self.app = app; self.bundle = bundle; self.build = build; self.commit = commit; self.device = device
  }

  /// From the main bundle: the display name, the bundle id, "version (build)", and the commit from the Info.plist
  /// key `BugKitCommit` (set it from `git rev-parse --short HEAD` at build time), else "unknown".
  public static func fromMainBundle(device: String) -> BugAppInfo {
    let b = Bundle.main
    let info = b.infoDictionary ?? [:]
    let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String ?? "app"
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let number = info["CFBundleVersion"] as? String ?? "?"
    let commit = (info["BugKitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
    return BugAppInfo(
      app: name, bundle: b.bundleIdentifier ?? "unknown", build: "\(version) (\(number))", commit: commit,
      device: device)
  }

  /// The hardware model, never the device's own name: "iPhone18,1" on a phone, "Mac16,12" on a Mac (where `uname`
  /// says only "arm64", bug-kit#6), and the simulated model ("iPhone17,1") on a simulator.
  public static func hardwareModel() -> String {
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return model(
      machine: machine, hwModel: sysctlString("hw.model"),
      simulatorModel: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"])
  }

  /// Picks the model: the simulator's own identifier first, then `uname`'s machine unless it only names the CPU
  /// architecture, then `hw.model` (a Mac's "Mac16,12").
  static func model(machine: String, hwModel: String?, simulatorModel: String?) -> String {
    if let sim = simulatorModel, !sim.isEmpty { return sim }
    let cpuOnly: Set<String> = ["arm64", "arm64e", "x86_64", "i386"]
    if cpuOnly.contains(machine), let hw = hwModel, !hw.isEmpty { return hw }
    return machine
  }

  static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
    let value = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return value.isEmpty ? nil : value
  }
}

/// Saves one report: its folder, the screenshot, the app's extra files, the line in bugs.jsonl, and a `bug_report`
/// event in the app's log. Every step that fails is logged as an `error` and the rest still runs, so a report is
/// never lost to one failing part.
public struct BugReportWriter: Sendable {
  public let store: BugStore
  public let info: BugAppInfo
  public let logger: BugLogger

  /// Copy the session log into the report's folder as `session.jsonl` (MM story 040): the report then holds the log
  /// as it was, whatever pruning or a later launch does. Flush the log first (`SessionLog.flush()`).
  public var copySessionLog = false
  /// Also write the report as pretty `report.json` in its folder (MM story 040), for a folder read on its own.
  public var writeReportJSON = false
  /// Optional durable cloud delivery. Local saving completes before enqueue, which must not await a network.
  public var delivery: (any BugReportDelivery)?

  public init(
    store: BugStore, info: BugAppInfo, logger: @escaping BugLogger, copySessionLog: Bool = false,
    writeReportJSON: Bool = false, delivery: (any BugReportDelivery)? = nil
  ) {
    self.store = store; self.info = info; self.logger = logger
    self.copySessionLog = copySessionLog; self.writeReportJSON = writeReportJSON
    self.delivery = delivery
  }

  /// `log`: the session log's path under the storage root and the milliseconds since it began, from the app.
  /// `copySessionLog`: overrides the writer's own setting for this report; nil keeps it.
  public func save(
    note: String, screen: String, context: [String: JSONValue], screenshotPNG: Data?,
    log: (path: String, tMs: Int)?, extraFiles: BugExtraFiles?, date: Date = Date(),
    diagnostics: BugDiagnosticsSnapshot = BugDiagnosticsSnapshot(), source: String? = nil,
    reason: String? = nil, event: String = "bug_report", copySessionLog: Bool? = nil, screenshotDropped: Bool = false
  ) async -> BugReport {
    // This must precede all report work, especially append: a launch Task may not have run yet,
    // and termination after append must not classify this report as pre-opt-in on restart.
    if let delivery {
      do { try await delivery.prepare(documents: store.documents) }
      catch {
        logger("error", ["where": "bug_delivery_prepare",
                         "message": "Cloud delivery activation failed; saving the report locally."])
      }
    }
    var report = BugReport(
      reportedAt: date, app: info.app, bundle: info.bundle, build: info.build, commit: info.commit,
      device: info.device, screen: screen, note: note, log: log?.path, sessionTMs: log?.tMs, folder: "",
      context: context, source: source, reason: reason)
    var folderURL: URL?
    do {
      let made = try store.makeFolder(for: date)
      report.folder = made.relative
      folderURL = made.url
    } catch {
      logger("error", ["where": "bug_folder", "id": .string(report.id.uuidString), "message": .string("\(error)")])
    }
    if !screenshotDropped, let folderURL, let png = screenshotPNG {
      do {
        try png.write(to: folderURL.appendingPathComponent("screen.png"))
        report.screenshot = "\(report.folder)/screen.png"
      } catch {
        logger("error", ["where": "bug_screenshot", "id": .string(report.id.uuidString), "message": .string("\(error)")])
      }
    }
    if let folderURL, let extraFiles {
      do {
        report.files = try await extraFiles(folderURL).map { "\(report.folder)/\($0)" }
      } catch {
        logger("error", ["where": "bug_extra_files", "id": .string(report.id.uuidString), "message": .string("\(error)")])
      }
    }
    if let folderURL {
      for (name, data) in diagnostics.files {
        do {
          try data.write(to: folderURL.appendingPathComponent(name), options: .atomic)
          report.files.append("\(report.folder)/\(name)")
        } catch {
          logger("error", ["where": "bug_diagnostics", "file": .string(name), "message": .string("\(error)")])
        }
      }
    }
    if let folderURL, copySessionLog ?? self.copySessionLog, let path = log?.path {
      do {
        try FileManager.default.copyItem(
          at: store.documents.appendingPathComponent(path), to: folderURL.appendingPathComponent("session.jsonl"))
        report.files.append("\(report.folder)/session.jsonl")
      } catch {
        logger("error", ["where": "bug_session_log", "id": .string(report.id.uuidString), "message": .string("\(error)")])
      }
    }
    if let folderURL, writeReportJSON {
      do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(report).write(to: folderURL.appendingPathComponent("report.json"))
      } catch {
        logger("error", ["where": "bug_report_json", "id": .string(report.id.uuidString), "message": .string("\(error)")])
      }
    }
    var indexWritten = true
    do {
      try store.append(report)
    } catch {
      // The report is still in the session log below; bugs.jsonl is what the listener reads, so say it is missing.
      indexWritten = false
      logger("error", ["where": "bug_index", "id": .string(report.id.uuidString), "message": .string("\(error)")])
    }
    var fields: [String: JSONValue] = [
      "id": .string(report.id.uuidString), "note": .string(note), "screen": .string(screen),
      "folder": .string(report.folder), "screenshot": report.screenshot.map(JSONValue.string) ?? .null,
      "files": .array(report.files.map(JSONValue.string)), "index_written": .bool(indexWritten),
    ]
    if screenshotDropped { fields["screenshot_dropped"] = true }
    fields["context"] = .object(context)
    if let source { fields["source"] = .string(source) }
    if let reason { fields["reason"] = .string(reason) }
    logger(event, fields)
    if let delivery {
      do { try await delivery.enqueue(report, documents: store.documents) }
      catch {
        logger("error", ["where": "bug_delivery_enqueue", "id": .string(report.id.uuidString),
                         "message": "Cloud delivery is pending; the report remains local."])
      }
    }
    return report
  }
}
