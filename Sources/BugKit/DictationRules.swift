import Foundation

/// The two rules dictation's iOS-only parts follow, kept out of AVFoundation and Speech so the host tests see them.
enum DictationRules {
  /// After Stop/Log it, "no speech detected" or a request ended with the audio is a normal end; the note is kept.
  static func endsQuietly(_ error: Error?, finishing: Bool) -> Bool {
    guard finishing, let error = error as NSError?, error.domain == "kAFAssistantErrorDomain" else { return false }
    return [1110, 301].contains(error.code)
  }

  /// Listing the microphones keeps its activation only for a host that mixes (or is ambient) without ducking or
  /// interrupting other audio. `AVDictationCapture.keepsDiscoveryActivation` reads these from the audio session.
  static func keepsDiscoveryActivation(
    ambient: Bool, mixesWithOthers: Bool, ducksOthers: Bool, interruptsSpokenAudio: Bool
  ) -> Bool {
    let changesOtherAudio = ducksOthers || interruptsSpokenAudio
    return !changesOtherAudio && (ambient || mixesWithOthers)
  }
}
