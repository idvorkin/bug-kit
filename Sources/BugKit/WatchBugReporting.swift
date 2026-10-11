import Foundation

/// Saves a watch note through the same store and optional delivery as the phone.
/// The app supplies its screen/context at presentation time; no UIKit or separate report format is involved.
public struct WatchBugReportSession: Sendable {
  public enum SaveError: Error, Equatable, Sendable {
    case emptyNote
    case indexNotWritten
  }

  public let writer: BugReportWriter
  public let screen: String
  public let context: [String: JSONValue]
  public let log: SessionLog?

  public init(writer: BugReportWriter, screen: String, context: [String: JSONValue] = [:], log: SessionLog? = nil) {
    self.writer = writer; self.screen = screen; self.context = context; self.log = log
  }

  /// Returns only once the local index contains the report. CloudKit remains opt-in and asynchronous.
  public func save(note: String) async throws -> BugReport {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SaveError.emptyNote }
    log?.flush()
    let report = await writer.save(note: trimmed, screen: screen, context: context, screenshotPNG: nil,
                                   log: log?.position, extraFiles: nil)
    guard try writer.store.readAll().reports.contains(where: { $0.id == report.id }) else {
      throw SaveError.indexNotWritten
    }
    return report
  }
}

#if os(watchOS) && canImport(SwiftUI)
import SwiftUI

/// Present this from the watch app's own sheet/navigation. TextFieldLink uses the watch's system text input.
public struct WatchBugReportView: View {
  private let session: WatchBugReportSession
  @Environment(\.dismiss) private var dismiss
  @State private var note = ""
  @State private var saving = false
  @State private var problem: String?

  public init(session: WatchBugReportSession) { self.session = session }

  public var body: some View {
    Form {
      TextFieldLink(prompt: Text("What went wrong?")) {
        Label(note.isEmpty ? "Add a note" : note, systemImage: "text.bubble")
      } onSubmit: { note = $0 }
      .disabled(saving)
      .accessibilityIdentifier("watch-report-note")
      if let problem { Text(problem).foregroundStyle(.red) }
      Button(saving ? "Saving…" : "Log it") {
        saving = true
        problem = nil
        Task { @MainActor in
          do {
            _ = try await session.save(note: note)
            dismiss()
          } catch {
            problem = "Could not save the report. Your note is kept; try again."
          }
          saving = false
        }
      }
      .disabled(saving || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier("watch-report-log-it")
    }
    .navigationTitle("Report a problem")
  }
}
#endif
