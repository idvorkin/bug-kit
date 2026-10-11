import Foundation

/// Where reports live in the app container, the same layout in every app so one listener reads them all:
///
///     Documents/bugs.jsonl          one line per report, newest last
///     Documents/bugs/<stamp>/       the report's screenshot and any extra files
///
/// `<stamp>` is `yyyyMMdd-HHmmss` in UTC, with `-2`, `-3`… when that second already has a folder ("Log it and
/// another" saves two in one second; MM story 061).
public final class BugStore: @unchecked Sendable {
  public let documents: URL
  public var index: URL { documents.appendingPathComponent("bugs.jsonl") }
  public var bugsFolder: URL { documents.appendingPathComponent("bugs", isDirectory: true) }

  public init(documents: URL) { self.documents = documents }

  /// The app's Documents folder.
  public convenience init() {
    self.init(documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
  }

  /// One lock for every store in the process: two stores on one index must not interleave either (mmn-cfr: two
  /// reports saved together each sought to the same end and wrote, so the later overwrote the earlier).
  private static let indexLock = NSLock()

  /// Appends the report's line to bugs.jsonl, creating it if needed. Serialized by a lock, and written with
  /// O_APPEND so even another process appends after the end rather than at an end it read earlier.
  public func append(_ report: BugReport) throws {
    var line = try report.jsonLine()
    line.append(0x0A)
    Self.indexLock.lock()
    defer { Self.indexLock.unlock() }
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let fd = open(index.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    try line.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        offset += n
      }
    }
  }

  /// Every report in bugs.jsonl that decodes as a BugKit report. Lines that do not (older formats, a torn line) are
  /// counted in `skipped`, not dropped silently.
  public func readAll() throws -> (reports: [BugReport], skipped: Int) {
    guard FileManager.default.fileExists(atPath: index.path) else { return ([], 0) }
    let text = try String(contentsOf: index, encoding: .utf8)
    var reports: [BugReport] = []
    var skipped = 0
    let dec = JSONDecoder()
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      if let r = try? dec.decode(BugReport.self, from: Data(line.utf8)) { reports.append(r) } else { skipped += 1 }
    }
    return (reports, skipped)
  }

  /// Creates the report's folder and returns its path relative to the storage root (`bugs/20261010-153000`) and its URL.
  /// The create itself is the test for "taken" (no `withIntermediateDirectories` on the last step), so two
  /// reports in one second, from two threads or two processes, never share a folder.
  public func makeFolder(for date: Date) throws -> (relative: String, url: URL) {
    try FileManager.default.createDirectory(at: bugsFolder, withIntermediateDirectories: true)
    let base = Self.stamp(for: date)
    var n = 1
    while true {
      let name = n == 1 ? base : "\(base)-\(n)"
      let url = bugsFolder.appendingPathComponent(name, isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return ("bugs/\(name)", url)
      } catch CocoaError.fileWriteFileExists {
        n += 1
      } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
        n += 1
      }
    }
  }

  /// `yyyyMMdd-HHmmss` in UTC: sortable, and the same stamp EA and CG used.
  public static func stamp(for date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: date)
  }
}
