import Foundation

extension BugReportWriter {
  /// Takes the reports an extension saved in `source` (a store in the app group the app shares with it) into this
  /// writer's store, then hands each to `delivery`, so they leave the device like the app's own (story 019, #119).
  /// An extension is its own process with no reporter and often no network; this is how its reports reach the Mac.
  ///
  /// Each report keeps its id, its time and the extension's build and device; it takes this app's `app` and `bundle`
  /// (the listener files by bundle) and keeps the extension's bundle as `context["extension"]`. Its files and session
  /// log are copied into a new folder in this store. A report this store already holds is not added again.
  ///
  /// The source's `bugs.jsonl` is first moved aside into a sibling folder with one atomic rename, so an extension
  /// saving meanwhile starts a fresh index; an index left aside by a take that was killed is finished first. Report
  /// folders, `logs/` and `bugs-auto.json` (its rate-limit state) stay in the live store, so a running extension keeps
  /// writing its session log and its window holds across takes. Each report's files and log are copied from the live
  /// store, and its folder there is deleted once this store holds it; the aside index is then deleted. An aside
  /// index is kept for the next take when it cannot be read, this store's own index cannot be read, or a report in it
  /// is not written here; a report already held is skipped then, so none is lost and none is taken twice. Takes in
  /// one process run one at a time, so two overlapping calls never both take a report. Logs `bug_report_adopted`
  /// for each report and returns them.
  @discardableResult
  public func adopt(from source: BugStore) async -> [BugReport] {
    await AdoptionQueue.shared.run { await adoptNow(from: source) }
  }

  private func adoptNow(from source: BugStore) async -> [BugReport] {
    let fm = FileManager.default
    let parent = source.documents.deletingLastPathComponent()
    let prefix = source.documents.lastPathComponent + ".taking-"
    let left = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
    var staged = left.map { parent.appendingPathComponent($0, isDirectory: true) }
    if fm.fileExists(atPath: source.index.path) {
      let aside = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
      do {
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        staged.append(aside)
        try fm.moveItem(at: source.index, to: BugStore(documents: aside).index)
      } catch {
        logger("error", ["where": "bug_adopt_move", "message": .string("\(error)")])
      }
    }
    guard !staged.isEmpty else { return [] }
    if let delivery {
      do { try await delivery.prepare(documents: store.documents) }
      catch {
        logger("error", ["where": "bug_delivery_prepare",
                         "message": "Cloud delivery activation failed; saving the report locally."])
      }
    }
    // Without this store's index nothing tells a report already taken, so every aside waits for the next take.
    var held: Set<UUID>
    do { held = Set(try store.readAll().reports.map(\.id)) } catch {
      logger("error", ["where": "bug_adopt_held", "message": .string("\(error)")])
      return []
    }
    var taken: [BugReport] = []
    for folder in staged {
      let from = BugStore(documents: folder)
      let reports: [BugReport]
      do { reports = try from.readAll().reports } catch {
        logger("error", ["where": "bug_adopt_read", "message": .string("\(error)")])
        continue
      }
      var missed = false
      for original in reports {
        let made = source.documents.appendingPathComponent(original.folder, isDirectory: true)
        func clear() {
          guard !original.folder.isEmpty, fm.fileExists(atPath: made.path) else { return }
          do { try fm.removeItem(at: made) } catch {
            logger("error", ["where": "bug_adopt_remove", "message": .string("\(error)")])
          }
        }
        if held.contains(original.id) { clear(); continue }
        guard let report = take(original, from: source.documents) else { missed = true; continue }
        clear()
        held.insert(report.id)
        taken.append(report)
        logger(
          "bug_report_adopted",
          ["id": .string(report.id.uuidString), "from": .string(original.bundle), "folder": .string(report.folder),
           "files": .array(report.files.map(JSONValue.string))])
        if let delivery {
          do { try await delivery.enqueue(report, documents: store.documents) }
          catch {
            logger("error", ["where": "bug_delivery_enqueue", "id": .string(report.id.uuidString),
                             "message": "Cloud delivery is pending; the report remains local."])
          }
        }
      }
      // A report not written here keeps its line in the aside, for the next take.
      if missed { continue }
      do { try fm.removeItem(at: folder) } catch {
        logger("error", ["where": "bug_adopt_remove", "message": .string("\(error)")])
      }
    }
    return taken
  }

  /// Copies one report's files and log from `root` into a new folder here and appends its line; nil when the line is
  /// not written.
  private func take(_ original: BugReport, from root: URL) -> BugReport? {
    var report = original
    report.app = info.app
    report.bundle = info.bundle
    if original.bundle != info.bundle { report.context["extension"] = .string(original.bundle) }
    report.files = []
    report.screenshot = nil
    report.log = nil
    do {
      let made = try store.makeFolder(for: original.reportedAt)
      report.folder = made.relative
      var names: Set<String> = []
      func copy(_ path: String, as wanted: String) -> String? {
        var name = wanted, n = 2
        let base = (wanted as NSString).deletingPathExtension, ext = (wanted as NSString).pathExtension
        while names.contains(name) { name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"; n += 1 }
        do {
          try FileManager.default.copyItem(
            at: root.appendingPathComponent(path), to: made.url.appendingPathComponent(name))
          names.insert(name)
          return "\(made.relative)/\(name)"
        } catch {
          logger("error", ["where": "bug_adopt_file", "id": .string(original.id.uuidString),
                           "file": .string(path), "message": .string("\(error)")])
          return nil
        }
      }
      if let shot = original.screenshot { report.screenshot = copy(shot, as: (shot as NSString).lastPathComponent) }
      report.files = original.files.compactMap { copy($0, as: ($0 as NSString).lastPathComponent) }
      if let log = original.log { report.log = copy(log, as: "session-log.jsonl") }
    } catch {
      report.folder = ""
      logger("error", ["where": "bug_folder", "id": .string(original.id.uuidString), "message": .string("\(error)")])
    }
    do {
      try store.append(report)
      return report
    } catch {
      logger("error", ["where": "bug_index", "id": .string(original.id.uuidString), "message": .string("\(error)")])
      if !report.folder.isEmpty {
        do { try FileManager.default.removeItem(at: store.documents.appendingPathComponent(report.folder)) } catch {
          logger("error", ["where": "bug_adopt_remove", "message": .string("\(error)")])
        }
      }
      return nil
    }
  }
}

/// Runs one take at a time in this process: each waits for the one before it to finish.
private actor AdoptionQueue {
  static let shared = AdoptionQueue()
  private var last: Task<Void, Never>?

  func run(_ work: @escaping @Sendable () async -> [BugReport]) async -> [BugReport] {
    let before = last
    let task = Task { await before?.value; return await work() }
    last = Task { _ = await task.value }
    return await task.value
  }
}
