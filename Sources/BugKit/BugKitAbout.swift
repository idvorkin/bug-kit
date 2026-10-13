import Foundation

/// Build-provided identity for the shared Settings About screen. Does not query git or a server.
public struct BugKitAboutInfo: Equatable, Sendable {
  public let appName: String
  public let version: String
  public let build: String
  public let commit: String?
  public let repositoryURL: URL?

  public init(bundle: Bundle = .main) {
    self.init(infoDictionary: bundle.infoDictionary ?? [:])
  }

  public init(infoDictionary: [String: Any]) {
    func value(_ key: String) -> String? {
      guard let text = infoDictionary[key] as? String else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    appName = value("CFBundleDisplayName") ?? value("CFBundleName") ?? "App"
    version = value("CFBundleShortVersionString") ?? "Unknown"
    build = value("CFBundleVersion") ?? "Unknown"
    commit = value("BugKitCommit").flatMap { text in
      let sha = text.hasSuffix("-dirty") ? String(text.dropLast(6)) : text
      guard (7...40).contains(sha.count), sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
      return text
    }
    repositoryURL = value("BugKitRepositoryURL").flatMap(Self.repository)
  }

  public var versionAndBuild: String { "\(version) (\(build))" }
  public var shortCommit: String? {
    commit.map { String($0.prefix(7)) + ($0.hasSuffix("-dirty") ? "-dirty" : "") }
  }
  /// A dirty build links its base commit; local modifications are not part of that GitHub commit.
  public var commitURL: URL? {
    guard let repositoryURL, let commit else { return nil }
    let sha = commit.hasSuffix("-dirty") ? String(commit.dropLast(6)) : commit
    return repositoryURL.appendingPathComponent("commit").appendingPathComponent(sha)
  }

  private static func repository(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme == "https", url.host?.lowercased() == "github.com",
          url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
    var parts = url.path.split(separator: "/").map(String.init)
    guard parts.count == 2 else { return nil }
    if parts[1].hasSuffix(".git") { parts[1] = String(parts[1].dropLast(4)) }
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
      $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { return nil }
    return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
  }
}

/// App-owned values such as model name and model version, shown in the order supplied.
public struct BugKitAboutRow: Equatable, Sendable {
  public let title: String
  public let value: String
  public init(title: String, value: String) { self.title = title; self.value = value }
}

#if canImport(SwiftUI)
  import SwiftUI

  /// A shared About destination for iOS, macOS and watchOS Settings.
  public struct BugKitAboutView: View {
    private let info: BugKitAboutInfo
    private let extraRows: [BugKitAboutRow]

    public init(info: BugKitAboutInfo = BugKitAboutInfo(), extraRows: [BugKitAboutRow] = []) {
      self.info = info; self.extraRows = extraRows
    }

    public var body: some View {
      List {
        Section {
          LabeledContent("App", value: info.appName)
          LabeledContent("Version", value: info.versionAndBuild)
          if let commit = info.shortCommit {
            if let url = info.commitURL {
              LabeledContent("Commit") { Link(commit, destination: url) }
            } else {
              LabeledContent("Commit", value: commit)
            }
          } else {
            LabeledContent("Commit", value: "Unknown")
          }
          if let url = info.repositoryURL { Link("Repository on GitHub", destination: url) }
          if info.commit?.hasSuffix("-dirty") == true {
            Text("Includes local changes; the link opens the base commit.").font(.caption).foregroundStyle(.secondary)
          }
        }
        if !extraRows.isEmpty {
          Section {
            ForEach(extraRows.indices, id: \.self) { index in
              LabeledContent(extraRows[index].title, value: extraRows[index].value)
            }
          }
        }
      }
      .navigationTitle("About / version")
      .accessibilityIdentifier("bugkit-about-version")
    }
  }

  /// Place inside a Settings NavigationStack to use the common label and destination.
  public struct BugKitAboutLink: View {
    private let info: BugKitAboutInfo
    private let extraRows: [BugKitAboutRow]

    public init(info: BugKitAboutInfo = BugKitAboutInfo(), extraRows: [BugKitAboutRow] = []) {
      self.info = info; self.extraRows = extraRows
    }

    public var body: some View {
      NavigationLink {
        BugKitAboutView(info: info, extraRows: extraRows)
      } label: {
        Label("About / version", systemImage: "info.circle")
      }
      .accessibilityIdentifier("bugkit-about-version-link")
    }
  }
#endif
