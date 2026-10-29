import Foundation

/// Which change the person has dismissed, kept in UserDefaults (CG story 148): the home row shows until its newest
/// change is dismissed with its ✕, and comes back for a build with something newer. Opening the list does not
/// dismiss it; the list stays reachable from the app's settings.
public struct WhatsNewSeen: @unchecked Sendable {
  public static let defaultKey = "bugkit.whats_new_seen"
  let defaults: UserDefaults
  let key: String

  /// Construct once in app initialization, before home reads `showsRow`, to apply the reset launch hook.
  public init(defaults: UserDefaults = .standard, key: String = defaultKey,
              launchHookPrefix: String? = nil,
              environment: [String: String] = ProcessInfo.processInfo.environment,
              logger: BugLogger? = nil) {
    self.defaults = defaults; self.key = key
    if let prefix = launchHookPrefix, BugLaunchHooks.parse(environment, prefix: prefix).whatsNewReset {
      reset(logger: logger)
    }
  }

  /// Clears only this store's dismissal. Other app preferences are retained.
  public func reset(logger: BugLogger? = nil) {
    defaults.removeObject(forKey: key)
    logger?("bug_hook", ["whats_new_reset": true])
  }

  public var newestSeen: String? { defaults.string(forKey: key) }

  public func showsRow(_ feed: WhatsNewFeed?) -> Bool { WhatsNewFeed.showsOnHome(feed, seen: newestSeen) }

  /// The ✕: remembers the feed's newest change. Logs `ui` dismiss_whats_new.
  public func dismiss(_ feed: WhatsNewFeed?, logger: BugLogger? = nil) {
    guard let newest = feed?.newest else { return }
    defaults.set(newest, forKey: key)
    logger?("ui", ["action": "dismiss_whats_new", "newest": .string(newest)])
  }

  /// The reports an earlier build's feed already fixed, so the home row headlines a fix only in the build that
  /// brought it, dismissed or not. Keeps the fixed reports of this build's feed and the build before it, by each
  /// feed's newest change, under `<key>.fixed`.
  public func fixedEarlier(_ feed: WhatsNewFeed?) -> Set<String> {
    guard let feed, let newest = feed.newest else { return [] }
    let store = key + ".fixed"
    var state = defaults.dictionary(forKey: store) ?? [:]
    if state["build"] as? String != newest {
      let fixed = feed.days.flatMap(\.items).flatMap { $0.fixedReports ?? [] }.map { $0.uppercased() }
      state = ["build": newest, "fixed": fixed, "earlier": state["fixed"] as? [String] ?? []]
      defaults.set(state, forKey: store)
    }
    return Set(state["earlier"] as? [String] ?? [])
  }

  /// The feed the build bundled as `whats-new.json` (scripts/whats-new.sh); nil when it is missing or unreadable.
  public static func bundledFeed(_ bundle: Bundle = .main, name: String = "whats-new") -> WhatsNewFeed? {
    WhatsNewFeed.decode(bundle.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) })
  }
}

/// One of this person's own reports that a change in this build fixed: the change's `fixedReports` (from the issue
/// its commit closed) matched against the device's `bugs.jsonl`. Nothing leaves the device; it is the report's own
/// note shown back to whoever wrote it.
public struct WhatsNewFix: Equatable, Sendable {
  /// The note's first line with words, cut to 80 characters.
  public var note: String
  public var reportedAt: Date

  /// "Fixed in this build: “the timer stopped…” (Oct 10)", under the change in the list.
  public func line(timeZone: TimeZone = .current) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = timeZone
    format.dateFormat = "MMM d"
    return "Fixed in this build: “\(note)” (\(format.string(from: reportedAt)))"
  }

  /// The home row's words after "What's new · " when this build fixed one of the person's reports. Reports in
  /// `fixedEarlier` (`WhatsNewSeen.fixedEarlier`) are not announced again on a later build.
  public static func homeLine(_ feed: WhatsNewFeed?, reports: [BugReport], fixedEarlier: Set<String> = []) -> String {
    let fresh = reports.filter { !fixedEarlier.contains($0.id.uuidString.uppercased()) }
    return feed?.fixes(in: fresh).first.map { "Fixed in this build: “\($0.note)”" } ?? WhatsNew.homeLine(feed)
  }
}

extension WhatsNewItem {
  /// This change's fixes among `reports` (the device's own), oldest report first. Reports with no note are skipped.
  public func fixes(in reports: [BugReport]) -> [WhatsNewFix] {
    guard let ids = fixedReports, !ids.isEmpty else { return [] }
    let wanted = Set(ids.map { $0.uppercased() })
    return reports.filter { wanted.contains($0.id.uuidString.uppercased()) }
      .sorted { $0.reportedAt < $1.reportedAt }
      .compactMap { report -> WhatsNewFix? in
        let line = report.note.split(whereSeparator: \.isNewline)
          .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line else { return nil }
        return WhatsNewFix(note: line.count > 80 ? String(line.prefix(79)) + "…" : line, reportedAt: report.reportedAt)
      }
  }
}

extension WhatsNewFeed {
  /// Every fix of the person's reports in the feed, newest change first.
  public func fixes(in reports: [BugReport]) -> [WhatsNewFix] {
    guard !reports.isEmpty else { return [] }
    return days.flatMap(\.items).flatMap { $0.fixes(in: reports) }
  }
}

// Plain SwiftUI, so the same views serve iOS and a Mac app (MM, 2026-10-10: What's new on the Mac too). On the Mac,
// give the list a size (`.frame(minWidth:minHeight:)`) when it is shown in a sheet or window.
#if canImport(SwiftUI)
  import SwiftUI

  /// The list: the last month's changes by day, newest first, each opening its story (CG #232). Logs `ui`
  /// open_whats_new on appear and open_story on a tap. Pass the device's reports (`BugStore().readAll().reports`)
  /// and a change that fixed one of them says so under it: "Fixed in this build: “<the note>” (Oct 10)".
  public struct WhatsNewView: View {
    let feed: WhatsNewFeed?
    let reports: [BugReport]
    let logger: BugLogger
    let from: String
    @Environment(\.openURL) private var openURL

    public init(feed: WhatsNewFeed?, reports: [BugReport] = [], logger: @escaping BugLogger, from: String = "row") {
      self.feed = feed; self.reports = reports; self.logger = logger; self.from = from
    }

    public var body: some View {
      List {
        if let days = feed?.days, !days.isEmpty {
          ForEach(days, id: \.day) { day in
            Section(WhatsNew.label(day: day.day, style: .long)) {
              ForEach(day.items, id: \.sha) { item in
                if let link = item.link.flatMap(URL.init(string:)) {
                  Button {
                    logger("ui", ["action": "open_story", "story": .int(item.story), "url": .string(link.absoluteString)])
                    openURL(link)
                  } label: {
                    HStack {
                      ChangeLine(item: item, fixes: item.fixes(in: reports))
                      Spacer()
                      Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                  }
                  .tint(.primary)
                  .accessibilityIdentifier("whats-new-story-\(item.story)")
                } else {
                  ChangeLine(item: item, fixes: item.fixes(in: reports))
                }
              }
            }
          }
        } else {
          Text("Nothing new in the last thirty days.").foregroundStyle(.secondary)
        }
      }
      .navigationTitle("What's new")
      .accessibilityIdentifier("whats-new")
      .onAppear {
        let days = feed?.days ?? []
        logger(
          "ui",
          [
            "action": "open_whats_new", "from": .string(from), "days": .int(days.count),
            "changes": .int(days.reduce(0) { $0 + $1.items.count }),
            "fixed_reports": .int(feed?.fixes(in: reports).count ?? 0),
          ])
      }
    }
  }

  private struct ChangeLine: View {
    let item: WhatsNewItem
    let fixes: [WhatsNewFix]

    var body: some View {
      VStack(alignment: .leading, spacing: 3) {
        Text(item.text)
        Text(item.caption).font(.caption).foregroundStyle(.secondary)
        ForEach(Array(fixes.enumerated()), id: \.offset) { _, fix in
          Label(fix.line(), systemImage: "checkmark.circle.fill")
            .font(.caption).foregroundStyle(.green)
            .accessibilityIdentifier("whats-new-fixed-report")
        }
      }
      .padding(.vertical, 2)
    }
  }

  /// The home screen's one-line pointer: "What's new · Oct 5 — <newest change>", with a ✕ that hides it until a
  /// newer build. Shows nothing when there is nothing to show or the newest was dismissed.
  public struct WhatsNewRow: View {
    let feed: WhatsNewFeed?
    let reports: [BugReport]
    let seen: WhatsNewSeen
    let logger: BugLogger
    let open: () -> Void
    #if os(macOS)
      // Explicit wrapper storage avoids the @State macro: CLT-only builds fail with "external macro implementation
      // type 'SwiftUIMacros.StateMacro' could not be found", since that SDK ships no SwiftUIMacros plugin.
      private var dismissal = SwiftUI.State<Bool>(initialValue: false)
      private var dismissed: Bool {
        get { dismissal.wrappedValue }
        nonmutating set { dismissal.wrappedValue = newValue }
      }
    #else
      @State private var dismissed = false
    #endif

    /// `reports`: the device's own (`BugStore().readAll().reports`); when this build fixed one, the row says so.
    public init(
      feed: WhatsNewFeed?, reports: [BugReport] = [], seen: WhatsNewSeen = WhatsNewSeen(), logger: @escaping BugLogger,
      open: @escaping () -> Void
    ) {
      self.feed = feed; self.reports = reports; self.seen = seen; self.logger = logger; self.open = open
    }

    public var body: some View {
      if !dismissed, seen.showsRow(feed) {
        HStack(alignment: .firstTextBaseline) {
          Button(action: open) {
            (Text(Image(systemName: "sparkles")) + Text("  What's new").fontWeight(.semibold)
              + Text(" · \(WhatsNewFix.homeLine(feed, reports: reports, fixedEarlier: seen.fixedEarlier(feed)))").foregroundStyle(.secondary))
              .font(.subheadline)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
          .tint(.primary)
          .accessibilityIdentifier("whats-new-row")
          Spacer()
          Button {
            seen.dismiss(feed, logger: logger)
            dismissed = true
          } label: {
            // The screenshot ✕'s fixed colours read on light rows and on MM's black capsule over video (#35).
            Image(systemName: "xmark.circle.fill")
              .font(.title3).symbolRenderingMode(.palette)
              .foregroundStyle(.white, .black.opacity(0.75))
              #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
              #endif
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Hide What's new until the next change")
          .accessibilityIdentifier("whats-new-dismiss")
        }
      }
    }
  }
#endif
