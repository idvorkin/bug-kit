#if canImport(Darwin)
  import Darwin
#endif
import Foundation

#if canImport(MetricKit) && os(iOS)
  import MetricKit
#endif

/// Crashes and hangs without a crash service (EA story 036, CG story 144):
///
/// - MetricKit hands the app its own crash and hang diagnostics on a later launch. Each payload is written to
///   `crashes/<stamp>.json` under the storage root and announced as `crash_report` (kind crash or hang).
/// - MetricKit can take days on a development build, so a signal handler writes `signal-<epoch>.txt` (the crashing
///   thread's raw backtrace) and an uncaught Objective-C exception writes `exception-<epoch>.txt` (name, reason,
///   symbolized stack). One file per crash: the abort after an exception writes no second file.
/// - At the next launch each of those files is announced once as `crash_report` (kind signal or exception, the
///   first lines as `top`) and renamed `.reported.txt`, so it is never announced again (EA #87).
///
/// The listener and `pull-reports` copy the folder. Install once, early, with the session log's logger:
///
///     CrashReports.shared.install(logger: log.logger)
public final class CrashReports: NSObject, @unchecked Sendable {
  public static let shared = CrashReports()
  public private(set) var folder: URL =
    BugStorage.defaultDirectory.appendingPathComponent("crashes")
  private var logger: BugLogger = { _, _ in }

  /// Installs the handlers and the MetricKit subscriber, then announces the files earlier runs left.
  public func install(folder: URL? = nil, logger: @escaping BugLogger) {
    if let folder { self.folder = folder }
    self.logger = logger
    do {
      try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    } catch {
      logger("error", ["where": "crash_folder", "message": .string("\(error)")])
    }
    #if canImport(Darwin)  // the handlers are Darwin calls; the announcing below is plain files
      installSignalHandlers(folder: self.folder)
    #endif
    #if canImport(MetricKit) && os(iOS)
      MXMetricManager.shared.add(self)
    #endif
    announcePending()
  }

  /// Announces each `signal-*.txt` / `exception-*.txt` not yet announced, then renames it `.reported.txt`. A renamed
  /// file keeps its `.txt` suffix, so the `.reported.` marker is what excludes it: matching on the suffix alone
  /// re-announced the same file at every launch (EA #87). Returns the names announced.
  @discardableResult
  public func announcePending() -> [String] {
    Self.announcePending(in: folder, logger: logger)
  }

  @discardableResult
  public static func announcePending(in folder: URL, logger: BugLogger) -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    var announced: [String] = []
    for name in files.sorted()
    where (name.hasPrefix("signal-") || name.hasPrefix("exception-")) && name.hasSuffix(".txt")
      && !name.contains(".reported.")
    {
      let url = folder.appendingPathComponent(name)
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let top = text.split(separator: "\n").prefix(12).joined(separator: " | ")
      logger(
        "crash_report",
        [
          "kind": .string(name.hasPrefix("signal-") ? "signal" : "exception"),
          "file": .string("crashes/\(name)"), "top": .string(top),
        ])
      announced.append(name)
      do {
        try FileManager.default.moveItem(
          at: url, to: folder.appendingPathComponent(name.replacingOccurrences(of: ".txt", with: ".reported.txt")))
      } catch {
        // Not renamed means announced again next launch; say so rather than repeat silently.
        logger("error", ["where": "crash_rename", "file": .string(name), "message": .string("\(error)")])
      }
    }
    return announced
  }
}

#if canImport(MetricKit) && os(iOS)
  extension CrashReports: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
      for payload in payloads {
        let crashes = payload.crashDiagnostics ?? []
        let hangs = payload.hangDiagnostics ?? []
        guard !crashes.isEmpty || !hangs.isEmpty else { continue }
        let name = "\(BugStore.stamp(for: payload.timeStampEnd)).json"
        do {
          try payload.jsonRepresentation().write(to: folder.appendingPathComponent(name))
        } catch {
          logger("error", ["where": "crash_payload", "file": .string(name), "message": .string("\(error)")])
        }
        for crash in crashes {
          logger(
            "crash_report",
            [
              "file": .string("crashes/\(name)"), "kind": "crash",
              "exception": .int(crash.exceptionType?.intValue ?? 0), "code": .int(crash.exceptionCode?.intValue ?? 0),
              "signal": .int(crash.signal?.intValue ?? 0), "reason": .string(crash.terminationReason ?? ""),
              "app": .string(crash.applicationVersion), "ended": .string(BugReport.formatDate(payload.timeStampEnd)),
            ])
        }
        // A hang is the main thread stuck; the watchdog kills at about 10 s (0x8BADF00D). Read its main-thread stack.
        for hang in hangs {
          logger(
            "crash_report",
            ["file": .string("crashes/\(name)"), "kind": "hang", "seconds": .double(hang.hangDuration.value)])
        }
      }
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {}
  }
#endif

#if canImport(Darwin)
// MARK: - The last-resort handlers. Only async-signal-safe calls inside the signal handler: no allocation, no locks.

/// The folder's path, copied once at install into a fixed buffer the handler can read.
private nonisolated(unsafe) var crashFolderPath = [CChar](repeating: 0, count: 1024)
/// Set once the exception file is on disk: the abort that follows is the same crash and writes no second file.
private nonisolated(unsafe) var exceptionFileWritten: sig_atomic_t = 0
/// The same path as a String, for the exception handler (which, unlike the signal handler, may allocate).
private nonisolated(unsafe) var crashFolderString = ""

private func installSignalHandlers(folder: URL) {
  crashFolderString = folder.path
  folder.path.utf8CString.withUnsafeBufferPointer { src in
    for i in 0..<min(src.count, crashFolderPath.count - 64) { crashFolderPath[i] = src[i] }
  }
  for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE] { signal(sig, crashSignalHandler) }
  // An Objective-C exception aborts through SIGABRT and the signal backtrace never says which one; this runs first,
  // on the throwing thread.
  NSSetUncaughtExceptionHandler { exception in
    let text = "exception \(exception.name.rawValue)\n\(exception.reason ?? "")\n"
      + exception.callStackSymbols.joined(separator: "\n") + "\n"
    let file = URL(fileURLWithPath: crashFolderString).appendingPathComponent("exception-\(Int(Date().timeIntervalSince1970)).txt")
    if (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil { exceptionFileWritten = 1 }
  }
}

private func crashSignalHandler(_ sig: Int32) {
  if exceptionFileWritten == 0 { writeSignalFile(sig) }
  // Back to the default action, so the crash still reaches the system's own report (CG 509da33).
  signal(sig, SIG_DFL)
  raise(sig)
}

/// Writes `<folder>/signal-<epoch>.txt` with stack buffers (`withUnsafeTemporaryAllocation`) and raw syscalls.
private func writeSignalFile(_ sig: Int32) {
  withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1100) { path in
    var n = 0
    crashFolderPath.withUnsafeBufferPointer { folder in
      while n < folder.count, folder[n] != 0 { path[n] = folder[n]; n += 1 }
    }
    n = appendASCII("/signal-", to: path, at: n)
    n = appendDecimal(Int(time(nil)), to: path, at: n)
    n = appendASCII(".txt", to: path, at: n)
    path[n] = 0
    let fd = open(path.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 32) { head in
      var h = appendASCII("signal ", to: head, at: 0)
      h = appendDecimal(Int(sig), to: head, at: h)
      head[h] = 0x0A
      _ = write(fd, head.baseAddress!, h + 1)
    }
    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 128) { frames in
      let count = backtrace(frames.baseAddress!, 128)
      backtrace_symbols_fd(frames.baseAddress!, count, fd)
    }
    close(fd)
  }
}

/// ASCII from a static string, without allocating.
private func appendASCII(_ text: StaticString, to buffer: UnsafeMutableBufferPointer<CChar>, at start: Int) -> Int {
  var i = start
  text.withUTF8Buffer { bytes in
    for b in bytes { buffer[i] = CChar(bitPattern: b); i += 1 }
  }
  return i
}

private func appendDecimal(_ value: Int, to buffer: UnsafeMutableBufferPointer<CChar>, at start: Int) -> Int {
  var divisor = 1
  while value / divisor >= 10 { divisor *= 10 }
  var i = start
  repeat { buffer[i] = CChar(48 + (value / divisor) % 10); i += 1; divisor /= 10 } while divisor > 0
  return i
}
#endif
