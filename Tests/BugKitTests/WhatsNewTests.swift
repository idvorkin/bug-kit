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
