//  The I/O half of What's new: reads the `git log` text and the stories, hands them to BugKit's WhatsNew.swift
//  (compiled in beside this file by scripts/whats-new.sh, not part of the package) and writes the app's JSON.
//  Usage: whats-new <log file> <stories dir> <out.json> [base URL for story links] [days, default 30]
//         [issues.json: `gh issue list --json number,body`, for each change's fixed reports]

import Foundation

let args = CommandLine.arguments
guard (4...7).contains(args.count) else {
  FileHandle.standardError.write(Data("usage: whats-new <log> <stories dir> <out.json> [base-url] [days] [issues.json]\n".utf8))
  exit(2)
}
let commits = WhatsNew.commits(fromLog: (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? "")
let baseURL = args.count > 4 && !args[4].isEmpty ? args[4] : nil
let days = args.count > 5 ? Int(args[5]) ?? 30 : 30
let reportsByIssue = args.count > 6 && !args[6].isEmpty
  ? WhatsNew.reportsByIssue(fromIssueList: (try? Data(contentsOf: URL(fileURLWithPath: args[6]))) ?? Data()) : [:]
var stories: [Int: WhatsNew.Story] = [:]
var issueStories: [Int: Int] = [:]
let dir = URL(fileURLWithPath: args[2])
for file in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where file.hasSuffix(".md") {
  let text = (try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)) ?? ""
  stories.merge(WhatsNew.stories(fromMarkdown: text, file: file, baseURL: baseURL)) { first, _ in first }
  issueStories.merge(WhatsNew.issueStories(fromMarkdown: text)) { first, _ in first }
}
let now = Date()
let feed = WhatsNewFeed(
  generated: ISO8601DateFormatter().string(from: now),
  days: WhatsNew.build(
    commits: commits, stories: stories, issueStories: issueStories, reportsByIssue: reportsByIssue, now: now, days: days))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
  try encoder.encode(feed).write(to: URL(fileURLWithPath: args[3]))
} catch {
  FileHandle.standardError.write(Data("whats-new: cannot write \(args[3]): \(error)\n".utf8))
  exit(1)
}
let fixed = feed.days.flatMap(\.items).reduce(0) { $0 + ($1.fixedReports?.count ?? 0) }
print("whats-new: \(commits.count) commits, \(stories.count) stories -> \(feed.days.count) days, \(feed.days.reduce(0) { $0 + $1.items.count }) changes, \(fixed) fixed reports")
