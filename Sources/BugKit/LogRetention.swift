import Foundation

/// Session logs older than 30 days are deleted at launch, except a log that a report in bugs.jsonl names: the
/// evidence for an open report survives (EA #72, CG story 145).
public enum LogRetention {
  public static let retentionSeconds: Double = 30 * 24 * 3600

  /// Names to delete: older than `retention` seconds, or (with `keepNewest`) past the newest `keepNewest` files, and
  /// not named by a report. The boundary stays (strictly older). `keepNewest` is for an app whose logs are large and
  /// many (MM: a few MB per launch, dozens of launches a day), where 30 days alone would fill the disk.
  public static func prune(
    files: [(name: String, age: Double)], referenced: Set<String>, retention: Double = retentionSeconds,
    keepNewest: Int? = nil
  ) -> [String] {
    let surplus = Set(keepNewest.map { files.sorted { $0.age < $1.age }.dropFirst(max($0, 0)).map(\.name) } ?? [])
    return files.filter { ($0.age > retention || surplus.contains($0.name)) && !referenced.contains($0.name) }
      .map(\.name)
  }

  /// The log file names the reports in a bugs.jsonl name. Accepts BugKit's `logs/<name>` paths and the older apps'
  /// bare names. Malformed lines are skipped.
  public static func referencedLogs(bugsJsonl text: String) -> Set<String> {
    var names = Set<String>()
    for line in text.split(separator: "\n") {
      guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let name = record["log"] as? String, !name.isEmpty
      else { continue }
      names.insert((name as NSString).lastPathComponent)
    }
    return names
  }
}

extension BugStore {
  /// Deletes `*.jsonl` in `logs` (default `<storage root>/logs`) older than `retention`, or past the newest `keepNewest`,
  /// except logs a report names. Logs one `logs_pruned` event even when nothing went (count, bytes,
  /// kept_for_reports). A bugs.jsonl that exists but cannot be read means the reported logs are unknown, so nothing
  /// is pruned (an `error` says so). A file whose age cannot be read is never deleted. Run it at launch, after the
  /// new session's log is open (with `keepNewest`, it is the newest, so it stays).
  @discardableResult
  public func pruneLogs(
    in logs: URL? = nil, retention: Double = LogRetention.retentionSeconds, keepNewest: Int? = nil,
    now: Date = Date(), logger: BugLogger
  ) -> [String] {
    let dir = logs ?? documents.appendingPathComponent("logs", isDirectory: true)
    var referenced = Set<String>()
    if FileManager.default.fileExists(atPath: index.path) {
      guard let text = try? String(contentsOf: index, encoding: .utf8) else {
        logger("error", ["where": "logs_prune", "message": "bugs.jsonl unreadable; nothing pruned"])
        return []
      }
      referenced = LogRetention.referencedLogs(bugsJsonl: text)
    }
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
      .filter { $0.pathExtension == "jsonl" }
      .compactMap { url -> (name: String, age: Double, size: Int)? in
        guard let values = try? url.resourceValues(forKeys: Set(keys)), let modified = values.contentModificationDate
        else { return nil }
        return (url.lastPathComponent, now.timeIntervalSince(modified), values.fileSize ?? 0)
      }
    let ages = files.map { (name: $0.name, age: $0.age) }
    let victims = Set(LogRetention.prune(files: ages, referenced: referenced, retention: retention, keepNewest: keepNewest))
    // Due to go by age or count, spared because a report names them.
    let due = Set(LogRetention.prune(files: ages, referenced: [], retention: retention, keepNewest: keepNewest))
    var deleted: [String] = []
    var freed = 0
    for file in files where victims.contains(file.name) {
      do {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(file.name))
        deleted.append(file.name)
        freed += file.size
      } catch {
        logger("error", ["where": "logs_prune", "file": .string(file.name), "message": .string("\(error)")])
      }
    }
    let kept = due.intersection(referenced).count
    logger("logs_pruned", ["count": .int(deleted.count), "bytes": .int(freed), "kept_for_reports": .int(kept)])
    return deleted.sorted()
  }
}
