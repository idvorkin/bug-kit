import Foundation
import Testing
@testable import BugKit

@Test func aboutReadsBuildMetadataAndLinksTheFullCommit() {
  let sha = "0123456789abcdef0123456789abcdef01234567"
  let info = BugKitAboutInfo(infoDictionary: [
    "CFBundleDisplayName": "Voice Keyboard", "CFBundleName": "Host",
    "CFBundleShortVersionString": "2.1", "CFBundleVersion": "42",
    "BugKitCommit": sha, "BugKitRepositoryURL": "https://github.com/example/voice-keyboard.git/",
  ])
  #expect(info.appName == "Voice Keyboard")
  #expect(info.versionAndBuild == "2.1 (42)")
  #expect(info.shortCommit == "0123456")
  #expect(info.repositoryURL?.absoluteString == "https://github.com/example/voice-keyboard")
  #expect(info.commitURL?.absoluteString == "https://github.com/example/voice-keyboard/commit/\(sha)")
}

@Test func aboutMissingMetadataUsesHonestFallbacks() {
  let info = BugKitAboutInfo(infoDictionary: [:])
  #expect(info.appName == "App")
  #expect(info.versionAndBuild == "Unknown (Unknown)")
  #expect(info.shortCommit == nil)
  #expect(info.commitURL == nil)
  #expect(info.repositoryURL == nil)
  let named = BugKitAboutInfo(infoDictionary: ["CFBundleDisplayName": "  ", "CFBundleName": "Fixture"])
  #expect(named.appName == "Fixture")
}

@Test func aboutSupportsExistingShortDirtyBuildCommits() {
  let info = BugKitAboutInfo(infoDictionary: ["BugKitCommit": "abcdef1-dirty",
                                            "BugKitRepositoryURL": "https://github.com/example/app"])
  #expect(info.shortCommit == "abcdef1-dirty")
  #expect(info.commitURL?.absoluteString == "https://github.com/example/app/commit/abcdef1")
}

@Test(arguments: ["unknown", "$(BUGKIT_COMMIT)", "main", "123", "abcdefg", "abc/def", String(repeating: "a", count: 41)])
func aboutDoesNotLinkInvalidBuildCommits(_ commit: String) {
  let info = BugKitAboutInfo(infoDictionary: ["BugKitCommit": commit,
                                            "BugKitRepositoryURL": "https://github.com/example/app"])
  #expect(info.commit == nil)
  #expect(info.commitURL == nil)
  #expect(info.repositoryURL != nil)
}

@Test(arguments: ["http://github.com/example/app", "https://github.com.evil.test/example/app",
                  "https://github.com/example/app/issues", "https://github.com/example/app?tab=readme",
                  "https://github.com/example/app#readme", "https://user@github.com/example/app",
                  "https://github.com/example/..", "$(BUGKIT_REPOSITORY_URL)"])
func aboutDoesNotLinkInvalidRepositories(_ repository: String) {
  let info = BugKitAboutInfo(infoDictionary: ["BugKitCommit": "abcdef1", "BugKitRepositoryURL": repository])
  #expect(info.repositoryURL == nil)
  #expect(info.commitURL == nil)
  #expect(info.shortCommit == "abcdef1")
}
