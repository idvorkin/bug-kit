import Foundation

/// How automatic reports are limited.
public struct BugAutoReportOptions: Equatable, Sendable {
  /// At most one report per reason in this many seconds; a flapping trigger is logged as
  /// `bug_report_auto_skipped` instead of filling the device and the tracker.
  public var window: TimeInterval = 600
  /// The most bytes of attachments copied into one report's folder, all files together, including `session.jsonl`
  /// when the writer copies the session log; `report.json` and the bugs.jsonl line are outside it. A file that does
  /// not fit keeps its tail (the newest lines of a log), starting at a line, and the cut is logged as
  /// `bug_report_auto_cut`.
  public var maxBytes = 5_000_000

  public init(window: TimeInterval = 600, maxBytes: Int = 5_000_000) {
    self.window = window; self.maxBytes = maxBytes
  }
}

/// Saves a report with no person and no dialog, when the app decides something went wrong (a call that failed, a
/// sync that stalled). It is a normal report: its own folder, a locked line in bugs.jsonl with `source: "auto"` and
/// `reason`, the app's big log copied in. The listener files it like any other, labelled `auto` (CG's diagnostics
/// gist, without a token, a public URL or a cleanup).
public actor BugAutoReporter {
  public let writer: BugReportWriter
  public let options: BugAutoReportOptions
  private let now: @Sendable () -> Date
  /// The last report per reason, kept in `bugs-auto.json` under the storage root so a relaunch loop is limited too.
  private var last: [String: Date]
  private var stateFile: URL { writer.store.documents.appendingPathComponent("bugs-auto.json") }

  public init(
    writer: BugReportWriter, options: BugAutoReportOptions = BugAutoReportOptions(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.writer = writer; self.options = options; self.now = now
    let file = writer.store.documents.appendingPathComponent("bugs-auto.json")
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    last = (try? dec.decode([String: Date].self, from: Data(contentsOf: file))) ?? [:]
  }

  /// Saves one report for `reason`, unless one was saved for it within `options.window`; returns nil then.
  /// `files` are copied into the report's folder, then the session log when the writer copies it, within
  /// `options.maxBytes`.
  @discardableResult
  public func report(
    reason: String, note: String? = nil, screen: String = "", context: [String: JSONValue] = [:], files: [URL] = [],
    log: (path: String, tMs: Int)? = nil
  ) async -> BugReport? {
    let date = now()
    if let previous = last[reason], date.timeIntervalSince(previous) < options.window, date >= previous {
      writer.logger(
        "bug_report_auto_skipped",
        ["reason": .string(reason), "last": .string(BugReport.formatDate(previous)),
         "window_s": .int(Int(options.window))])
      return nil
    }
    last[reason] = date
    saveState()
    var sources = files.map { (url: $0, name: $0.lastPathComponent) }
    if writer.copySessionLog, let path = log?.path {
      let session = writer.store.documents.appendingPathComponent(path)
      if !files.contains(where: { $0.standardizedFileURL == session.standardizedFileURL }) {
        sources.append((url: session, name: "session.jsonl"))
      }
    }
    let maxBytes = options.maxBytes, logger = writer.logger
    let copy: BugExtraFiles = { [sources] folder in Self.copy(sources, into: folder, maxBytes: maxBytes, logger: logger) }
    return await writer.save(
      note: note ?? "Automatic report: \(reason)", screen: screen, context: context, screenshotPNG: nil, log: log,
      extraFiles: sources.isEmpty ? nil : copy, date: date, source: "auto", reason: reason, event: "bug_report_auto",
      copySessionLog: false)
  }

  private func saveState() {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.sortedKeys]
    do {
      try enc.encode(last).write(to: stateFile, options: .atomic)
    } catch {
      writer.logger("error", ["where": "bug_auto_state", "message": .string("\(error)")])
    }
  }

  /// Copies each file whole while it fits; the first that does not keeps its tail, from a line start, and the
  /// rest are left out. Each cut is logged with what was kept and dropped. Reads stop at the size first seen, so a
  /// log that grows meanwhile stays within the budget. A file that fails is logged and the others are still copied;
  /// a name already taken gets a number ("call-2.jsonl").
  static func copy(
    _ files: [(url: URL, name: String)], into folder: URL, maxBytes: Int, logger: BugLogger
  ) -> [String] {
    var left = max(0, maxBytes)
    var names: [String] = []
    for (file, wanted) in files {
      let name = unique(wanted, taken: names)
      let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
      guard let size else {
        logger("error", ["where": "bug_auto_file", "file": .string(name), "message": "unreadable"])
        continue
      }
      let take = min(size, left)
      do {
        var kept = Data()
        if take > 0 {
          let handle = try FileHandle(forReadingFrom: file)
          defer { try? handle.close() }
          try handle.seek(toOffset: UInt64(size - take))
          kept = try handle.read(upToCount: take) ?? Data()
          // Start at a line, so every kept line of a JSON Lines log is whole.
          if take < size, let newline = kept.firstIndex(of: UInt8(ascii: "\n")) {
            kept = kept.subdata(in: kept.index(after: newline)..<kept.endIndex)
          }
        }
        if take < size {
          logger(
            "bug_report_auto_cut",
            ["file": .string(name), "size": .int(size), "kept_bytes": .int(kept.count),
             "dropped_bytes": .int(size - kept.count)])
        }
        if take == size || !kept.isEmpty {
          try kept.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
          names.append(name)
        }
        left -= take
      } catch {
        logger("error", ["where": "bug_auto_file", "file": .string(name), "message": .string("\(error)")])
      }
    }
    return names
  }

  private static func unique(_ name: String, taken: [String]) -> String {
    guard taken.contains(name) else { return name }
    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
    var n = 2
    while true {
      let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
      if !taken.contains(candidate) { return candidate }
      n += 1
    }
  }
}
