//  What's new, by day (CG story 148, #165, #232, #246): an app's story commits over the last month, made at build
//  time from `git log` and the stories' own summaries, each change linking to its story. Foundation only and
//  self-contained: scripts/whats-new.sh compiles this file with plain swiftc for the app's build phase, and the app
//  decodes what it wrote (`WhatsNewFeed.decode`). WhatsNewView (iOS) shows it.

import Foundation

public struct WhatsNewItem: Codable, Equatable, Sendable {
  public var story: Int
  public var text: String
  public var issue: Int?
  public var sha: String
  /// The story on GitHub, at its own heading (#232). Nil when the build found no such story, or in a feed from an
  /// older build.
  public var link: String?
  /// The bug reports this change fixed: the `<!-- bug-id:… -->` markers of the issues its commits close
  /// ("Fixes #N"), uppercase UUIDs. The device shows its own reports among them as "Fixed in this build". Nil when
  /// it fixed none, or the build did not look (`whats-new.sh` without `--fixed-reports`, or no `gh`).
  public var fixedReports: [String]?

  public init(story: Int, text: String, issue: Int? = nil, sha: String, link: String? = nil, fixedReports: [String]? = nil) {
    self.story = story
    self.text = text
    self.issue = issue
    self.sha = sha
    self.link = link
    self.fixedReports = fixedReports
  }

  /// "Story 133 · #142", the small line under a change.
  public var caption: String {
    let story = String(format: "Story %03d", self.story)
    return issue.map { "\(story) · #\($0)" } ?? story
  }
}

public struct WhatsNewDay: Codable, Equatable, Sendable {
  /// The local day, yyyy-MM-dd.
  public var day: String
  public var items: [WhatsNewItem]

  public init(day: String, items: [WhatsNewItem]) {
    self.day = day
    self.items = items
  }
}

public struct WhatsNewFeed: Codable, Equatable, Sendable {
  public var generated: String
  public var days: [WhatsNewDay]

  public init(generated: String, days: [WhatsNewDay]) {
    self.generated = generated
    self.days = days
  }

  /// The newest change: what opening What's new marks as seen.
  public var newest: String? { days.first?.items.first?.sha }

  /// The home screen's row shows until its newest change has been seen; with nothing to show there is no row.
  public static func showsOnHome(_ feed: WhatsNewFeed?, seen: String?) -> Bool {
    guard let newest = feed?.newest else { return false }
    return newest != seen
  }

  /// Nil for a missing or unreadable resource: the row then says nothing new.
  public static func decode(_ data: Data?) -> WhatsNewFeed? {
    data.flatMap { try? JSONDecoder().decode(WhatsNewFeed.self, from: $0) }
  }
}

public enum WhatsNew {
  public struct Commit: Equatable, Sendable {
    public var sha: String
    public var date: Date
    public var subject: String
    /// The message under the subject, where a commit may name its story instead (#246).
    public var body: String

    public init(sha: String, date: Date, subject: String, body: String = "") {
      self.sha = sha
      self.date = date
      self.subject = subject
      self.body = body
    }
  }

  /// A story's own words, from its markdown.
  public struct Story: Equatable, Sendable {
    public var summary: String
    public var issue: Int?
    /// Where the story lives on GitHub, when the markdown was read with its file name.
    public var link: String?

    public init(summary: String, issue: Int? = nil, link: String? = nil) {
      self.summary = summary
      self.issue = issue
      self.link = link
    }
  }

  /// A heading "### User Story 096:" is the anchor `user-story-096` on GitHub; links are `<baseURL><file>#user-story-NNN`,
  /// with `baseURL` such as `https://github.com/<owner>/<repo>/blob/main/docs/stories/`.

  /// The `git log --format='%h%x1f%cI%x1f%s%x1f%b%x1e'` text → commits. Unit separators between the fields and a
  /// record separator after each commit, since a subject or a message can hold any other character (#246).
  public static func commits(fromLog log: String) -> [Commit] {
    let iso = ISO8601DateFormatter()
    return log.split(separator: "\u{1e}").compactMap { record -> Commit? in
      let f = record.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
      guard f.count >= 3, let date = iso.date(from: f[1]) else { return nil }
      return Commit(sha: f[0], date: date, subject: f[2], body: f.count > 3 ? f[3] : "")
    }
  }

  /// What a subject says: which story, the words to show unless the story has its own, the issue it names.
  public struct Parsed: Equatable, Sendable {
    public var story: Int
    public var text: String
    public var issue: Int?
    /// True for "Story NNN…" subjects, whose story summary is preferred over `text`.
    public var leading: Bool
  }

  // MARK: Subjects

  private static let bookkeeping = try! NSRegularExpression(
    pattern: #"^(Merge\b|WIP\b|wip\b|fixup!|squash!|amend!|Revert\b|no-mistakes\(|Story\s+\d+\s*:?\s*Status\b)"#)
  private static let leadingStory = try! NSRegularExpression(
    pattern: #"^Story\s+(\d+)\s*(?:\(#(\d+)\))?\s*[:—–-]?\s*(.*)$"#, options: [.caseInsensitive])
  private static let bracketStories = try! NSRegularExpression(
    pattern: #"\s*\((?:#\d+\s*[,;]\s*)*(?:story|stories)\s+(\d+)([^)]*)\)"#, options: [.caseInsensitive])
  private static let bracketIssue = try! NSRegularExpression(pattern: #"\s*\(#(\d+)\)"#)
  private static let hashNumber = try! NSRegularExpression(pattern: #"#(\d+)"#)
  private static let storyInBody = try! NSRegularExpression(
    pattern: #"\bstor(?:y|ies)\s+(\d{3})\b"#, options: [.caseInsensitive])

  /// #246: a subject naming no story still reaches one through the message ("Story 200.") or through the issue
  /// it names, which a story's Issues line lists. Shown under its own words, since it is the change itself.
  public static func parse(subject raw: String, body: String, issueStories: [Int: Int]) -> Parsed? {
    if let parsed = parse(subject: raw) { return parsed }
    let subject = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if subject.isEmpty || matches(bookkeeping, subject) != nil { return nil }
    var text = subject
    var issue: Int?
    if let i = matches(bracketIssue, text) {
      issue = group(i, 1, text).flatMap(Int.init)
      text = remove(i, from: text)
    }
    let named = matches(storyInBody, body).flatMap { group($0, 1, body) }.flatMap(Int.init)
    guard let story = named ?? issue.flatMap({ issueStories[$0] }) else { return nil }
    return Parsed(story: story, text: sentence(text), issue: issue, leading: false)
  }

  /// Each issue a story's Issues line lists → that story; an issue two stories list goes to the first.
  public static func issueStories(fromMarkdown markdown: String) -> [Int: Int] {
    var out: [Int: Int] = [:]
    var current: Int?
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("### User Story ") {
        current = Int(text.dropFirst("### User Story ".count).prefix { $0.isNumber })
      } else if let id = current, let issues = field("Issues", in: text) {
        for m in hashNumber.matches(in: issues, range: NSRange(issues.startIndex..., in: issues)) {
          if let n = group(m, 1, issues).flatMap(Int.init), out[n] == nil { out[n] = id }
        }
      }
    }
    return out
  }

  /// Nil for a subject that is no story's change: bookkeeping, or no story named.
  public static func parse(subject raw: String) -> Parsed? {
    let subject = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if subject.isEmpty || matches(bookkeeping, subject) != nil { return nil }
    if let m = matches(leadingStory, subject), let story = Int(group(m, 1, subject) ?? "") {
      var text = group(m, 3, subject) ?? ""
      var issue = group(m, 2, subject).flatMap(Int.init)
      if let i = matches(bracketIssue, text) {
        issue = issue ?? group(i, 1, text).flatMap(Int.init)
        text = remove(i, from: text)
      }
      return Parsed(story: story, text: sentence(text), issue: issue, leading: true)
    }
    if let m = matches(bracketStories, subject), let story = Int(group(m, 1, subject) ?? "") {
      var text = remove(m, from: subject)
      var issue = group(m, 0, subject).flatMap { bracket in matches(hashNumber, bracket).flatMap { group($0, 1, bracket) } }
        .flatMap(Int.init)
      if let i = matches(bracketIssue, text) {
        issue = issue ?? group(i, 1, text).flatMap(Int.init)
        text = remove(i, from: text)
      }
      return Parsed(story: story, text: sentence(text), issue: issue, leading: false)
    }
    return nil
  }

  // MARK: Stories

  /// Every "### User Story NNN:" in the markdown with its "**Summary:**" and the first issue its "**Issues:**" names.
  /// `file` and `baseURL`: the markdown's name under the stories folder and where that folder is on the web, so each
  /// story gets its link; no link without both.
  public static func stories(fromMarkdown markdown: String, file: String? = nil, baseURL: String? = nil) -> [Int: Story] {
    var out: [Int: Story] = [:]
    var current: Int?
    var link: String?
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("### User Story ") {
        let digits = text.dropFirst("### User Story ".count).prefix { $0.isNumber }
        current = Int(digits)
        link = file.flatMap { f in baseURL.map { "\($0)\(f)#user-story-\(digits)" } }
        continue
      }
      guard let id = current else { continue }
      if let summary = field("Summary", in: text) {
        var words = summary
        if words.hasSuffix("(technical)") { words = String(words.dropLast("(technical)".count)) }
        out[id] = Story(summary: sentence(words), issue: out[id]?.issue, link: link)
      } else if let issues = field("Issues", in: text) {
        let issue = matches(hashNumber, issues).flatMap { group($0, 1, issues) }.flatMap(Int.init)
        out[id] = Story(summary: out[id]?.summary ?? "", issue: issue, link: link)
      }
    }
    return out.filter { !$0.value.summary.isEmpty }
  }

  // MARK: Fixed reports

  private static let closingIssue = try! NSRegularExpression(
    pattern: #"\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\s*:?\s+#(\d+)"#, options: [.caseInsensitive])
  private static let bugIDMarker = try! NSRegularExpression(
    pattern: #"<!-- bug-id:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}) -->"#)

  /// The issues a commit closes in GitHub's own words: "Fixes #12", "closes #3", "Resolved: #7".
  public static func closedIssues(subject: String, body: String) -> [Int] {
    let text = subject + "\n" + body
    var out: [Int] = []
    for m in closingIssue.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      if let n = group(m, 1, text).flatMap(Int.init), !out.contains(n) { out.append(n) }
    }
    return out
  }

  /// `gh issue list --json number,body` → each issue's bug-report ids, from the markers bug-listener writes.
  /// Empty for anything unreadable: the feed then just has no fixed reports.
  public static func reportsByIssue(fromIssueList data: Data) -> [Int: [String]] {
    struct Issue: Decodable { let number: Int; let body: String? }
    guard let issues = try? JSONDecoder().decode([Issue].self, from: data) else { return [:] }
    var out: [Int: [String]] = [:]
    for issue in issues {
      let body = issue.body ?? ""
      let ids = bugIDMarker.matches(in: body, range: NSRange(body.startIndex..., in: body))
        .compactMap { group($0, 1, body)?.uppercased() }
      if !ids.isEmpty { out[issue.number] = ids }
    }
    return out
  }

  // MARK: The feed

  /// Commits newest first (as `git log` gives them) → days newest first, one line per story per day, within
  /// `days` days of `now`.
  public static func build(
    commits: [Commit], stories: [Int: Story], issueStories: [Int: Int] = [:], reportsByIssue: [Int: [String]] = [:],
    now: Date, days: Int = 30, timeZone: TimeZone = .current
  ) -> [WhatsNewDay] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let since = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
    let dayFormat = DateFormatter()
    dayFormat.calendar = calendar
    dayFormat.timeZone = timeZone
    dayFormat.locale = Locale(identifier: "en_US_POSIX")
    dayFormat.dateFormat = "yyyy-MM-dd"

    var order: [String] = []
    var byDay: [String: [WhatsNewItem]] = [:]
    var seen = Set<String>()
    for commit in commits.sorted(by: { $0.date > $1.date }) where commit.date >= since && commit.date <= now {
      guard let parsed = parse(subject: commit.subject, body: commit.body, issueStories: issueStories) else { continue }
      let day = dayFormat.string(from: commit.date)
      // Each commit's fixed reports, even one folded into its story's line for the day.
      let fixed = closedIssues(subject: commit.subject, body: commit.body).flatMap { reportsByIssue[$0] ?? [] }
      guard seen.insert("\(day)/\(parsed.story)").inserted else {
        if !fixed.isEmpty, let i = byDay[day]?.firstIndex(where: { $0.story == parsed.story }) {
          byDay[day]![i].fixedReports = unique((byDay[day]![i].fixedReports ?? []) + fixed)
        }
        continue
      }
      let story = stories[parsed.story]
      let text = parsed.leading ? (story?.summary ?? parsed.text) : parsed.text
      guard !text.isEmpty else { continue }
      if byDay[day] == nil { order.append(day) }
      byDay[day, default: []].append(
        WhatsNewItem(
          story: parsed.story, text: text, issue: parsed.issue ?? story?.issue, sha: commit.sha, link: story?.link,
          fixedReports: fixed.isEmpty ? nil : unique(fixed)))
    }
    return order.map { WhatsNewDay(day: $0, items: byDay[$0] ?? []) }
  }

  // MARK: What the screens say

  /// The home row's words after "What's new · ".
  public static func homeLine(_ feed: WhatsNewFeed?) -> String {
    guard let day = feed?.days.first, let item = day.items.first else { return "nothing new" }
    return "\(label(day: day.day, style: .short)) — \(item.text)"
  }

  public enum LabelStyle { case short, long }

  /// "Oct 5" or "Monday, Oct 5" for a yyyy-MM-dd day.
  public static func label(day: String, style: LabelStyle) -> String {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else { return day }
    let format = DateFormatter()
    format.calendar = calendar
    format.timeZone = calendar.timeZone
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = style == .short ? "MMM d" : "EEEE, MMM d"
    return format.string(from: date)
  }

  // MARK: Helpers

  private static func unique(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
  }

  private static func field(_ name: String, in line: String) -> String? {
    let prefix = "- **\(name):**"
    guard line.hasPrefix(prefix) else { return nil }
    return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
  }

  /// Trimmed, first letter capitalised, no trailing full stop.
  private static func sentence(_ text: String) -> String {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix(".") { s.removeLast() }
    guard let first = s.first else { return s }
    return first.uppercased() + s.dropFirst()
  }

  private static func matches(_ regex: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
    regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
  }

  private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
    guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return nil }
    return String(s[r])
  }

  private static func remove(_ m: NSTextCheckingResult, from s: String) -> String {
    guard let r = Range(m.range, in: s) else { return s }
    var out = s
    out.removeSubrange(r)
    return out.trimmingCharacters(in: .whitespaces)
  }
}
