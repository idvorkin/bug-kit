import Foundation
import Testing
@testable import BugKit

// The audio session's category and options, as AVDictationCapture.keepsDiscoveryActivation reads them.
@Test func discoveryKeepsActivationOnlyForPlainMixingHosts() {
  // .playback with .mixWithOthers; .ambient with no options
  #expect(DictationRules.keepsDiscoveryActivation(
    ambient: false, mixesWithOthers: true, ducksOthers: false, interruptsSpokenAudio: false))
  #expect(DictationRules.keepsDiscoveryActivation(
    ambient: true, mixesWithOthers: false, ducksOthers: false, interruptsSpokenAudio: false))
  // .playback with [.mixWithOthers, .duckOthers]
  #expect(!DictationRules.keepsDiscoveryActivation(
    ambient: false, mixesWithOthers: true, ducksOthers: true, interruptsSpokenAudio: false))
  // .playback with .interruptSpokenAudioAndMixWithOthers, which also holds .mixWithOthers' bit
  #expect(!DictationRules.keepsDiscoveryActivation(
    ambient: false, mixesWithOthers: true, ducksOthers: false, interruptsSpokenAudio: true))
  // .ambient with .duckOthers
  #expect(!DictationRules.keepsDiscoveryActivation(
    ambient: true, mixesWithOthers: false, ducksOthers: true, interruptsSpokenAudio: false))
  // .soloAmbient or .playback with no options
  #expect(!DictationRules.keepsDiscoveryActivation(
    ambient: false, mixesWithOthers: false, ducksOthers: false, interruptsSpokenAudio: false))
}

@Test func appleNoSpeechEndsQuietlyOnlyAfterFinish() {
  let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1110)
  let ended = NSError(domain: "kAFAssistantErrorDomain", code: 301)
  let network = NSError(domain: "kAFAssistantErrorDomain", code: 1101)
  #expect(DictationRules.endsQuietly(noSpeech, finishing: true))
  #expect(DictationRules.endsQuietly(ended, finishing: true))
  #expect(!DictationRules.endsQuietly(noSpeech, finishing: false))
  #expect(!DictationRules.endsQuietly(network, finishing: true))
  #expect(!DictationRules.endsQuietly(NSError(domain: NSURLErrorDomain, code: 1110), finishing: true))
  #expect(!DictationRules.endsQuietly(nil, finishing: true))
}
