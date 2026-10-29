import Foundation
import XCTest

@testable import BugKit

/// CG story 148 (#165, #232, #246): what's new, made from the commit subjects and the stories' summaries.
final class WhatsNewTests: XCTestCase {
  let la = TimeZone(identifier: "America/Los_Angeles")!

  private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

  /// MM's Mac app shows What's new with the same views: they build and construct on the host (macOS).
  func testTheViewsBuildOnTheHost() {
    let feed = WhatsNewFeed(generated: "2026-10-10", days: [])
    _ = WhatsNewView(feed: feed, logger: { _, _ in })
    _ = WhatsNewRow(feed: feed, logger: { _, _ in }, open: {})
    _ = WhatsNewView(feed: feed, reports: [], logger: { _, _ in })
    _ = WhatsNewRow(feed: feed, reports: [], logger: { _, _ in }, open: {})
  }

  // MARK: Fixed in this build (review V1): the person's own report, shown back under the change that fixed it.

  private let fixedID = UUID(uuidString: "6F1C2A3B-0000-4000-8000-00000000000A")!
  private let otherID = UUID(uuidString: "6F1C2A3B-0000-4000-8000-00000000000B")!

  private func report(_ id: UUID, note: String, at iso: String) -> BugReport {
    BugReport(id: id, reportedAt: at(iso), app: "fixture", bundle: "local.fixture", build: "1", commit: "c",
              device: "synthetic", screen: "home", note: note, folder: "bugs/x")
  }

  func testClosingKeywordsNameTheIssuesACommitFixes() {
    XCTAssertEqual(
      WhatsNew.closedIssues(subject: "Fix the timer (#12)", body: "Fixes #12\nCloses: #3 and resolved #7; see #9"),
      [12, 3, 7])
    XCTAssertEqual(WhatsNew.closedIssues(subject: "Story 147: a cog", body: "Refs #4"), [])
  }

  func testTheIssueListGivesEachIssuesReportIDs() {
    let json = #"""
      [{"number": 12, "body": "> note\n<!-- bug:2026-10-10T15:00:00Z -->\n<!-- bug-id:6f1c2a3b-0000-4000-8000-00000000000a -->"},
       {"number": 13, "body": null}, {"number": 14, "body": "<!-- bug:2026-10-10T15:00:00Z -->"}]
      """#
    XCTAssertEqual(WhatsNew.reportsByIssue(fromIssueList: Data(json.utf8)), [12: [fixedID.uuidString]])
    XCTAssertEqual(WhatsNew.reportsByIssue(fromIssueList: Data("not json".utf8)), [:])
  }

  func testAChangeCarriesTheReportsEveryCommitOfItsDayFixed() {
    let commits = [
      WhatsNew.Commit(sha: "d", date: at("2026-10-06T17:00:00Z"), subject: "Story 147: the timer keeps counting",
                      body: "Fixes #12"),
      WhatsNew.Commit(sha: "c", date: at("2026-10-06T16:00:00Z"), subject: "Story 147: and on resume", body: "Closes #13"),
      WhatsNew.Commit(sha: "b", date: at("2026-10-06T15:00:00Z"), subject: "Card opens the trainer (story 133)"),
    ]
    let a = fixedID.uuidString, b = otherID.uuidString
    let items = WhatsNew.build(
      commits: commits, stories: [:], reportsByIssue: [12: [a], 13: [b, a]], now: at("2026-10-06T20:00:00Z"),
      timeZone: la
    ).first?.items ?? []
    XCTAssertEqual(items.map(\.sha), ["d", "b"])
    XCTAssertEqual(items[0].fixedReports, [a, b])
    XCTAssertNil(items[1].fixedReports)
    let without = WhatsNew.build(commits: commits, stories: [:], now: at("2026-10-06T20:00:00Z"), timeZone: la)
    XCTAssertNil(without.first?.items.first?.fixedReports, "a build that did not look carries nothing")
  }

  func testAFixFromAnEarlierBuildIsNotHeadlinedAgain() throws {
    let seen = WhatsNewSeen(defaults: try XCTUnwrap(UserDefaults(suiteName: "bugkit-test-\(UUID().uuidString)")))
    let mine = report(fixedID, note: "the timer stopped", at: "2026-10-10T18:00:00Z")
    let other = report(otherID, note: "digits too small", at: "2026-10-11T18:00:00Z")
    let a = fixedID.uuidString
    // Build 1: "a" (story 147) fixes my report, then "b" (story 148) the same day.
    let build1 = WhatsNewFeed(generated: "", days: [.init(day: "2026-10-12", items: [
      .init(story: 148, text: "Bigger digits", sha: "b"),
      .init(story: 147, text: "The timer keeps counting", sha: "a", fixedReports: [a]),
    ])])
    XCTAssertEqual(WhatsNewFix.homeLine(build1, reports: [mine], fixedEarlier: seen.fixedEarlier(build1)),
                   "Fixed in this build: “the timer stopped”")
    XCTAssertEqual(WhatsNewFix.homeLine(build1, reports: [mine], fixedEarlier: seen.fixedEarlier(build1)),
                   "Fixed in this build: “the timer stopped”", "the whole build headlines it, not just its first look")
    // Build 2, never dismissed: "c" on story 147 the same day folds "a"'s fix into a line now ahead of "b".
    let build2 = WhatsNewFeed(generated: "", days: [.init(day: "2026-10-12", items: [
      .init(story: 147, text: "The timer keeps counting", sha: "c", fixedReports: [a]),
      .init(story: 148, text: "Bigger digits", sha: "b"),
    ])])
    XCTAssertEqual(WhatsNewFix.homeLine(build2, reports: [mine], fixedEarlier: seen.fixedEarlier(build2)),
                   "Oct 12 — The timer keeps counting")
    XCTAssertEqual(build2.fixes(in: [mine]).count, 1, "the list still shows the fix under its change")
    // Build 3 fixes another of my reports: that one is headlined, the old one still is not.
    let build3 = WhatsNewFeed(generated: "", days: [
      .init(day: "2026-10-13", items: [.init(story: 149, text: "Larger type", sha: "d", fixedReports: [otherID.uuidString])]),
      build2.days[0],
    ])
    XCTAssertEqual(WhatsNewFix.homeLine(build3, reports: [mine, other], fixedEarlier: seen.fixedEarlier(build3)),
                   "Fixed in this build: “digits too small”")
  }

  func testTheDeviceShowsOnlyItsOwnFixedReports() {
    let item = WhatsNewItem(
      story: 147, text: "The timer keeps counting", sha: "d", fixedReports: [fixedID.uuidString, UUID().uuidString])
    let feed = WhatsNewFeed(generated: "", days: [.init(day: "2026-10-12", items: [item])])
    let mine = report(fixedID, note: "  \nthe timer stopped when I opened settings\nand more", at: "2026-10-10T18:00:00Z")
    let unrelated = report(otherID, note: "something else", at: "2026-10-11T18:00:00Z")
    let fixes = feed.fixes(in: [unrelated, mine])
    XCTAssertEqual(fixes.map(\.note), ["the timer stopped when I opened settings"])
    XCTAssertEqual(fixes.first?.line(timeZone: la), "Fixed in this build: “the timer stopped when I opened settings” (Oct 10)")
    XCTAssertEqual(WhatsNewFix.homeLine(feed, reports: [mine]), "Fixed in this build: “the timer stopped when I opened settings”")
    XCTAssertEqual(WhatsNewFix.homeLine(feed, reports: [unrelated]), "Oct 12 — The timer keeps counting")
    XCTAssertEqual(item.fixes(in: [report(fixedID, note: " ", at: "2026-10-10T18:00:00Z")]), [], "no note, no line")
    let long = report(fixedID, note: String(repeating: "x", count: 120), at: "2026-10-10T18:00:00Z")
    XCTAssertEqual(item.fixes(in: [long]).first?.note.count, 80)
  }

  func testFixedReportsRoundTripAndAnOlderFeedStillDecodes() throws {
    let feed = WhatsNewFeed(
      generated: "", days: [.init(day: "2026-10-05", items: [.init(story: 1, text: "A", sha: "a", fixedReports: ["X"])])])
    XCTAssertEqual(WhatsNewFeed.decode(try JSONEncoder().encode(feed)), feed)
    let older = #"{"generated": "", "days": [{"day": "2026-10-05", "items": [{"story": 1, "text": "A", "sha": "a"}]}]}"#
    XCTAssertNil(WhatsNewFeed.decode(Data(older.utf8))?.days.first?.items.first?.fixedReports)
  }

  func testSubjectsThatStartWithTheirStory() {
    XCTAssertEqual(
      WhatsNew.parse(subject: "Story 203: the Cockpit's usage left, as a strip on the native home screen"),
      .init(story: 203, text: "The Cockpit's usage left, as a strip on the native home screen", issue: nil, leading: true))
    XCTAssertEqual(
      WhatsNew.parse(subject: "Story 146 (#164): a gentle shake opens the report, read from the motion itself"),
      .init(story: 146, text: "A gentle shake opens the report, read from the motion itself", issue: 164, leading: true))
    XCTAssertEqual(
      WhatsNew.parse(subject: "Story 147: the home screen holds only the launchers (#166)"),
      .init(story: 147, text: "The home screen holds only the launchers", issue: 166, leading: true))
    XCTAssertEqual(WhatsNew.parse(subject: "Story 037 (#139): every finished workout rides to Larry")?.story, 37)
  }

  func testSubjectsThatNameTheirStoriesInBrackets() {
    XCTAssertEqual(
      WhatsNew.parse(subject: "Think of a card opens the trainer instead of a native card port (story 133)"),
      .init(
        story: 133, text: "Think of a card opens the trainer instead of a native card port", issue: nil,
        leading: false))
    XCTAssertEqual(
      WhatsNew.parse(subject: "Gym Timer: RESET on the turned face when paused or finished (story 181, #132)"),
      .init(story: 181, text: "Gym Timer: RESET on the turned face when paused or finished", issue: 132, leading: false))
    XCTAssertEqual(WhatsNew.parse(subject: "Native app: Box breathing (stories 160-165)")?.story, 160)
    XCTAssertEqual(WhatsNew.parse(subject: "Native app: Box breathing (stories 160-165)")?.text, "Native app: Box breathing")
    XCTAssertEqual(WhatsNew.parse(subject: "Home: an Exercise Analyzer row (#142, story 134)")?.story, 134)
  }

  func testIssueFirstBracketSubjectsReachTheFeed() {
    XCTAssertEqual(WhatsNew.parse(subject: "Add the panel (#12; story 007)"),
                   .init(story: 7, text: "Add the panel", issue: 12, leading: false))
    XCTAssertEqual(WhatsNew.parse(subject: "Fix two things (#12, #13; stories 007, 004)"),
                   .init(story: 7, text: "Fix two things", issue: 12, leading: false))
    let markdown = """
      ### User Story 007:
      - **Summary:** The panel
      ### User Story 004:
      - **Summary:** Another thing
      """
    let stories = WhatsNew.stories(fromMarkdown: markdown, file: "stories.md",
                                  baseURL: "https://github.com/example/app/blob/main/docs/")
    let days = WhatsNew.build(commits: [
      .init(sha: "new", date: at("2026-10-06T17:00:00Z"), subject: "Fix two things (#12, #13; stories 007, 004)"),
      .init(sha: "older", date: at("2026-10-05T17:00:00Z"), subject: "Add the panel (#12; story 007)")
    ], stories: stories, now: at("2026-10-06T20:00:00Z"), timeZone: la)
    XCTAssertEqual(days.flatMap(\.items).map(\.story), [7, 7])
    XCTAssertEqual(days.flatMap(\.items).map(\.issue), [12, 12])
    XCTAssertEqual(days[0].items[0].text, "Fix two things")
    XCTAssertEqual(days[0].items[0].link, "https://github.com/example/app/blob/main/docs/stories.md#user-story-007")
  }

  func testBookkeepingAndStorylessSubjectsAreDropped() {
    for subject in [
      "Story 147 Status names 80b7186", "Story 133: Status names 0152b68", "Story 203 Status names its commit 3da9e54",
      "Story 080 Status: d9c1fd1 verified on the phone (#146)", "Merge native/mirror into native/ports",
      "Merge pull request #134 from owner/native/05-live-activity (story 106)", "WIP story 12",
      "no-mistakes(review): Story 120 Status names its commit 7ba6357", "Native Call: send the Cockpit's origin (#136)", "",
    ] {
      XCTAssertNil(WhatsNew.parse(subject: subject), subject)
    }
  }

  func testStorySummariesAndIssuesFromTheMarkdown() {
    let markdown = """
      ### User Story 141:

      - **Summary:** Every launch keeps a log (technical)
      - **Status:** implemented

      ### User Story 147:

      - **Summary:** The home screen holds only what I open, and a cog holds the rest
      - **Issues:** [#166](https://github.com/example/app/issues/166), [#170](x)

      ### User Story 199:
      - **Status:** a story with no summary is not used
      """
    let stories = WhatsNew.stories(fromMarkdown: markdown)
    XCTAssertEqual(stories[141], .init(summary: "Every launch keeps a log"))
    XCTAssertEqual(stories[147], .init(summary: "The home screen holds only what I open, and a cog holds the rest", issue: 166))
    XCTAssertNil(stories[199])
  }

  // #232: each story links to its own heading on GitHub.
  func testEachStoryLinksToItsHeading() {
    let markdown = """
      ### User Story 096:
      - **Summary:** Cockpit in the app
      """
    let base = "https://github.com/example/app/blob/main/docs/stories/"
    let stories = WhatsNew.stories(fromMarkdown: markdown, file: "05-call.md", baseURL: base)
    XCTAssertNil(WhatsNew.stories(fromMarkdown: markdown, file: "05-call.md")[96]?.link, "no base URL, no link")
    XCTAssertEqual(
      stories[96]?.link, base + "05-call.md#user-story-096")
    let days = WhatsNew.build(
      commits: [.init(sha: "a", date: at("2026-10-06T15:00:00Z"), subject: "Story 096: the Cockpit")],
      stories: stories, now: at("2026-10-06T20:00:00Z"), timeZone: la)
    XCTAssertEqual(days.first?.items.first?.link, stories[96]?.link)
    // A feed an older build wrote has no links, and still reads.
    let old = Data(#"{"generated":"","days":[{"day":"2026-10-06","items":[{"story":1,"text":"x","sha":"a"}]}]}"#.utf8)
    XCTAssertNil(WhatsNewFeed.decode(old)?.days.first?.items.first?.link)
    XCTAssertNotNil(WhatsNewFeed.decode(old))
  }

  func testTheFeedIsByLocalDayNewestFirstOneLinePerStoryPerDay() {
    let stories: [Int: WhatsNew.Story] = [147: .init(summary: "A cog for the rest", issue: 166)]
    let commits = [
      WhatsNew.Commit(sha: "e", date: at("2026-10-06T16:00:00Z"), subject: "Story 147 Status names d"),
      WhatsNew.Commit(sha: "d", date: at("2026-10-06T15:00:00Z"), subject: "Story 147: the home screen, launchers only"),
      WhatsNew.Commit(sha: "c", date: at("2026-10-06T14:00:00Z"), subject: "Story 147: a follow-up the same day"),
      // 01:00 UTC on the 6th is still the 5th in Los Angeles.
      WhatsNew.Commit(sha: "b", date: at("2026-10-06T01:00:00Z"), subject: "Story 147: the first cut"),
      WhatsNew.Commit(sha: "a", date: at("2026-10-05T18:00:00Z"), subject: "Card opens the trainer (story 133)"),
      WhatsNew.Commit(sha: "old", date: at("2026-08-01T18:00:00Z"), subject: "Story 100: long ago"),
    ]
    let days = WhatsNew.build(commits: commits, stories: stories, now: at("2026-10-06T20:00:00Z"), timeZone: la)
    XCTAssertEqual(days.map(\.day), ["2026-10-06", "2026-10-05"])
    XCTAssertEqual(days[0].items, [WhatsNewItem(story: 147, text: "A cog for the rest", issue: 166, sha: "d")])
    XCTAssertEqual(days[1].items.map(\.sha), ["b", "a"])
    XCTAssertEqual(days[1].items[1].text, "Card opens the trainer")
    XCTAssertEqual(days[1].items[1].caption, "Story 133")
    XCTAssertEqual(days[0].items[0].caption, "Story 147 · #166")
  }

  // #246: a subject naming no story reaches one through its message, or through its issue's story.
  func testASubjectWithoutAStoryFindsItInTheMessageOrThroughItsIssue() {
    let markdown = """
      ### User Story 198:
      - **Summary:** A call heals
      - **Issues:** [#197](x), [#198](y)
      """
    let issueStories = WhatsNew.issueStories(fromMarkdown: markdown)
    XCTAssertEqual(issueStories, [197: 198, 198: 198])
    let commits = [
      WhatsNew.Commit(
        sha: "c", date: at("2026-10-06T17:00:00Z"), subject: "Native Cockpit: Back in the footer",
        body: "Opening Lavish left no way back. Story 200.\n\nCloses #234"),
      WhatsNew.Commit(sha: "b", date: at("2026-10-06T16:00:00Z"), subject: "Native: a stale retry no longer ends a call (#198)"),
      WhatsNew.Commit(sha: "a", date: at("2026-10-06T15:00:00Z"), subject: "Native: tidy the timer", body: "No story here."),
      WhatsNew.Commit(sha: "m", date: at("2026-10-06T14:00:00Z"), subject: "Merge pull request #9", body: "Story 200"),
    ]
    let items = WhatsNew.build(
      commits: commits, stories: [:], issueStories: issueStories, now: at("2026-10-06T20:00:00Z"), timeZone: la
    ).first?.items ?? []
    XCTAssertEqual(items.map(\.sha), ["c", "b"], "no story by any route, or a merge, does not show")
    XCTAssertEqual(items[0].story, 200)
    XCTAssertEqual(items[0].text, "Native Cockpit: Back in the footer")
    XCTAssertEqual(items[1].story, 198)
    XCTAssertEqual(items[1].issue, 198)
    XCTAssertEqual(items[1].text, "Native: a stale retry no longer ends a call")
  }

  func testAStoryWithoutAMarkdownSummaryShowsTheSubjectsWords() {
    let days = WhatsNew.build(
      commits: [.init(sha: "a", date: at("2026-10-06T15:00:00Z"), subject: "Story 240 (#147): a thicker ring")],
      stories: [:], now: at("2026-10-06T20:00:00Z"), timeZone: la)
    XCTAssertEqual(days.first?.items.first?.text, "A thicker ring")
    XCTAssertEqual(days.first?.items.first?.issue, 147)
  }

  func testTheHomeLineAndLabels() {
    XCTAssertEqual(WhatsNew.homeLine(nil), "nothing new")
    XCTAssertEqual(WhatsNew.homeLine(WhatsNewFeed(generated: "", days: [])), "nothing new")
    let feed = WhatsNewFeed(
      generated: "", days: [.init(day: "2026-10-05", items: [.init(story: 240, text: "Box breathing ring styles", sha: "a")])])
    XCTAssertEqual(WhatsNew.homeLine(feed), "Oct 5 — Box breathing ring styles")
    XCTAssertEqual(WhatsNew.label(day: "2026-10-05", style: .long), "Monday, Oct 5")
    XCTAssertEqual(WhatsNew.label(day: "garbage", style: .long), "garbage")
  }

  func testTheResourceRoundTripsAndABadOneIsNil() throws {
    let feed = WhatsNewFeed(
      generated: "2026-10-06T20:00:00Z",
      days: [.init(day: "2026-10-05", items: [.init(story: 133, text: "Card", issue: 142, sha: "a")])])
    XCTAssertEqual(WhatsNewFeed.decode(try JSONEncoder().encode(feed)), feed)
    XCTAssertNil(WhatsNewFeed.decode(nil))
    XCTAssertNil(WhatsNewFeed.decode(Data("not json".utf8)))
  }

  /// The `git log` text the build script writes: unit separators between fields, a record separator per commit,
  /// and a body that can hold newlines and anything else.
  func testCommitsFromTheLogText() {
    let log = "a1\u{1f}2026-10-06T15:00:00Z\u{1f}Story 148: what's new\u{1f}Body line one\nStory 200.\u{1e}\n"
      + "b2\u{1f}not a date\u{1f}dropped\u{1f}\u{1e}\n"
      + "c3\u{1f}2026-10-05T15:00:00-07:00\u{1f}Merge pull request #1\u{1f}\u{1e}\n"
    let commits = WhatsNew.commits(fromLog: log)
    XCTAssertEqual(commits.map(\.sha), ["a1", "c3"])
    XCTAssertEqual(commits[0].body, "Body line one\nStory 200.")
    XCTAssertEqual(commits[0].subject, "Story 148: what's new")
    XCTAssertTrue(WhatsNew.commits(fromLog: "").isEmpty)
  }

  /// This repository's own stories parse, and each links when given the base URL.
  func testBugKitsOwnStoriesParse() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("docs/stories")
    var all: [Int: WhatsNew.Story] = [:]
    for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".md") && file != "README.md" {
      all.merge(WhatsNew.stories(
        fromMarkdown: try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8), file: file,
        baseURL: "https://example.com/")) { a, _ in a }
    }
    XCTAssertGreaterThan(all.count, 10)
    XCTAssertTrue(all.values.allSatisfy { $0.link?.hasPrefix("https://example.com/") == true })
  }

  func testTheSeenStoreHidesTheRowUntilSomethingNewer() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "bugkit-test-\(UUID().uuidString)"))
    let seen = WhatsNewSeen(defaults: defaults)
    let feed = WhatsNewFeed(generated: "", days: [WhatsNewDay(day: "2026-10-06", items: [WhatsNewItem(story: 1, text: "A", sha: "aaa")])])
    XCTAssertTrue(seen.showsRow(feed))
    var logged: [String] = []
    let lock = NSLock()
    seen.dismiss(feed, logger: { e, f in lock.lock(); logged.append("\(e) \(f["action"]?.display ?? "")"); lock.unlock() })
    XCTAssertFalse(seen.showsRow(feed))
    XCTAssertEqual(logged, ["ui dismiss_whats_new"])
    let newer = WhatsNewFeed(generated: "", days: [WhatsNewDay(day: "2026-10-07", items: [WhatsNewItem(story: 2, text: "B", sha: "bbb")])])
    XCTAssertTrue(seen.showsRow(newer))
    XCTAssertNil(WhatsNewSeen.bundledFeed(Bundle(for: Self.self)))
  }

  func testHomeRowGoesOnceSeenAndComesBackForSomethingNewer() {
    let feed = WhatsNewFeed(
      generated: "2026-10-06",
      days: [WhatsNewDay(day: "2026-10-06", items: [WhatsNewItem(story: 148, text: "New", sha: "bbb")])])
    XCTAssertTrue(WhatsNewFeed.showsOnHome(feed, seen: nil))
    XCTAssertFalse(WhatsNewFeed.showsOnHome(feed, seen: "bbb"))
    XCTAssertTrue(WhatsNewFeed.showsOnHome(feed, seen: "aaa"))
    // Nothing to show: no row at all.
    XCTAssertFalse(WhatsNewFeed.showsOnHome(nil, seen: nil))
    XCTAssertFalse(WhatsNewFeed.showsOnHome(WhatsNewFeed(generated: "", days: []), seen: nil))
  }
}
