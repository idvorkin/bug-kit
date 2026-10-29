import Foundation

/// One JSON Lines file per launch: `logs/<prefix>-<yyyyMMdd-HHmmss>.jsonl`, one event per line,
/// `{"type": "<event>", "t": <ms since launch>, …fields}`. Written as each event comes (no buffer to lose in a
/// crash), under the storage root: app-container Documents on iOS/watchOS or app-specific Application Support on macOS.
/// On iOS the Files app shows it and `devicectl` copies it. Optional: an app with its own log
/// passes its logger to `BugReporterHooks` instead.
///
///     let log = SessionLog(prefix: "swing", fields: ["build": "1.0 (42)"])
///     log.event("set_saved", ["reps": 13])
public final class SessionLog: @unchecked Sendable {
  /// Clocks each line carries beyond `t` (MM's special sauce, story 012). `t` alone answers "how long after launch";
  /// a person says "it just happened at 15:10", and a camera or audio frame is stamped on the host clock.
  public struct Clocks: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// `wall`: local wall-clock time, ISO 8601 with ms and the zone offset, so `scripts/log-tool.sh around 15:10:45`
    /// finds the moment someone names.
    public static let wall = Clocks(rawValue: 1)
    /// `mono`: seconds on the host clock (`ProcessInfo.systemUptime`, the clock of `CACurrentMediaTime` and
    /// `CMClockGetHostTimeClock`), the same clock as camera and audio sample times, so a frame or a segment's time
    /// converts to wall time with `wall(ofMono:)`.
    public static let mono = Clocks(rawValue: 2)
  }

  public let url: URL
  public let clocks: Clocks
  public let startedAt: Date
  private let documents: URL
  private let queue = DispatchQueue(label: "bugkit.session-log")
  /// Internal so a host test can break the descriptor underneath it.
  private(set) var handle: FileHandle?
  /// Lines that failed to write since the last one that landed (disk full, a dead descriptor). Touched only on `queue`.
  private var droppedLines = 0
  private var timers: [DispatchSourceTimer] = []

  /// Opens a new log and writes `session_start` with `fields` (put the device, system and build there).
  public init(
    prefix: String, documents: URL = BugStorage.defaultDirectory,
    fields: [String: JSONValue] = [:], clocks: Clocks = [], now: Date = Date()
  ) {
    self.documents = documents
    self.clocks = clocks
    startedAt = now
    let dir = documents.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    var candidate = dir.appendingPathComponent("\(prefix)-\(f.string(from: now)).jsonl")
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {  // two launches in one second
      candidate = dir.appendingPathComponent("\(prefix)-\(f.string(from: now))-\(n).jsonl")
      n += 1
    }
    url = candidate
    FileManager.default.createFile(atPath: url.path, contents: nil)
    do {
      handle = try FileHandle(forWritingTo: url)
    } catch {
      // No file, no evidence: say so once where a tethered run can see it.
      print("SessionLog: cannot open \(url.path): \(error)")
    }
    var start = fields
    start["started"] = .string(BugReport.formatDate(now))
    event("session_start", start)
  }

  /// The log's path under the storage root (`logs/swing-20261010-150000.jsonl`), as a report names it.
  public var relativePath: String { "logs/\(url.lastPathComponent)" }

  public var msSinceStart: Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

  /// For `BugReporterHooks.sessionLog`.
  public var position: (path: String, tMs: Int) { (relativePath, msSinceStart) }

  /// For `BugReporterHooks.logger`.
  public var logger: BugLogger { { [self] type, fields in event(type, fields) } }

  public func event(_ type: String, _ fields: [String: JSONValue] = [:]) {
    let t = msSinceStart
    let stamps = Self.stamps(clocks, wall: Date(), mono: ProcessInfo.processInfo.systemUptime)
    queue.async { [self] in
      var data = Self.line(type: type, t: t, fields: fields, stamps: stamps)
      data.append(0x0A)
      append(data, t: t, stamps: stamps)
    }
  }

  /// Writes one line on `queue`. Uses the throwing `write(contentsOf:)`: the legacy `write(_:)` raises an
  /// Objective-C exception on a full disk or a dead descriptor, which Swift cannot catch, so the logger would crash
  /// the app it is diagnosing. A failed line is dropped and counted; the next line that lands is preceded by one
  /// `error` (`where: "session_log"`, `dropped: n`).
  private func append(_ data: Data, t: Int, stamps: [String: JSONValue]) {
    guard let handle else { return }
    if droppedLines > 0 {
      // A failed write can leave a partial line behind, so the note starts on a fresh line; readers skip blanks.
      var note = Data([0x0A])
      note.append(
        Self.line(
          type: "error", t: t,
          fields: ["where": "session_log", "dropped": .int(droppedLines), "message": "lines lost to a failed write"],
          stamps: stamps))
      note.append(0x0A)
      guard (try? handle.write(contentsOf: note)) != nil else {
        droppedLines += 1
        return
      }
      droppedLines = 0
    }
    do {
      try handle.write(contentsOf: data)
    } catch {
      if droppedLines == 0 { print("SessionLog: cannot write \(url.path): \(error)") }  // once per run of failures
      droppedLines += 1
    }
  }

  /// Waits for every queued event to reach the file (before copying the log into a report).
  public func flush() { queue.sync {} }

  /// A periodic status line (`type`, every `seconds`): for anything that can go quiet or get stuck, so the minutes
  /// before every report are in the log. Runs until the log is released. `memory: true` adds `rss_mb`, the process's
  /// resident memory, so a leak or a climb toward the memory limit (a kill with no crash file) shows in the log
  /// (MM's selftest status line).
  public func status(
    _ type: String = "status", every seconds: Double, memory: Bool = false,
    _ fields: @escaping @Sendable () -> [String: JSONValue]
  ) {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + seconds, repeating: seconds)
    timer.setEventHandler { [weak self] in
      var line = fields()
      if memory, let mb = Self.residentMegabytes() { line["rss_mb"] = .int(mb) }
      self?.event(type, line)
    }
    timer.resume()
    queue.sync { timers.append(timer) }
  }

  deinit { timers.forEach { $0.cancel() } }

  /// The process's resident memory in MB (Mach `task_info`), nil if the kernel refuses.
  public static func residentMegabytes() -> Int? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Int(info.resident_size / 1_048_576)
  }

  /// The wall-clock time of a host-clock (`mono`) time: a camera frame's or a recorded segment's time as the moment
  /// a person would name. `now` and `nowMono` are for tests.
  public static func wall(ofMono mono: Double, now: Date = Date(), nowMono: Double = ProcessInfo.processInfo.systemUptime) -> Date {
    now.addingTimeInterval(mono - nowMono)
  }

  /// `wall` as written in a line: local time with ms and the zone offset.
  public static func formatWall(_ date: Date, timeZone: TimeZone = .current) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = timeZone
    return f.string(from: date)
  }

  static func stamps(_ clocks: Clocks, wall: Date, mono: Double, timeZone: TimeZone = .current) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    if clocks.contains(.wall) { out["wall"] = .string(formatWall(wall, timeZone: timeZone)) }
    if clocks.contains(.mono) { out["mono"] = .double((mono * 1000).rounded() / 1000) }
    return out
  }

  /// One line, no newline. `type`, `t` and the clock stamps come after the fields, so a field cannot replace them;
  /// a non-finite number becomes null rather than losing the whole line.
  public static func line(type: String, t: Int, fields: [String: JSONValue], stamps: [String: JSONValue] = [:]) -> Data {
    var record = fields.mapValues(sanitize)
    record.merge(stamps) { _, stamp in stamp }
    record["type"] = .string(type)
    record["t"] = .int(t)
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(record) { return data }
    let fallback: [String: JSONValue] = [
      "type": "error", "t": .int(t), "where": "log", "event": .string(type), "message": "a field JSON cannot carry",
    ]
    return (try? enc.encode(fallback)) ?? Data()
  }

  static func sanitize(_ value: JSONValue) -> JSONValue {
    switch value {
    case .double(let d): return d.isFinite ? value : .null
    case .array(let a): return .array(a.map(sanitize))
    case .object(let o): return .object(o.mapValues(sanitize))
    default: return value
    }
  }
}
