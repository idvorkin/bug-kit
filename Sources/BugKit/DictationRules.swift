import Foundation

/// The rules dictation's iOS-only parts follow, kept out of AVFoundation and Speech so the host tests see them.
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

  /// What to do when the audio engine is reconfigured while dictating (#128, #142). A running engine needs nothing. A
  /// stopped one is rebuilt on the input as it is now, whenever the change comes (a headset settling at start, a USB
  /// microphone or a headset taking the input later, the input going back to the pick), so dictation follows the
  /// route; only a run of `rebuildLimit` rebuilds inside `rebuildWindow` seconds (a route flapping) stops it.
  static func engineChange(running: Bool, recentRebuilds: Int) -> DictationEngineChange {
    if running { return .ignore }
    return recentRebuilds < rebuildLimit ? .rebuild : .fail
  }

  static let rebuildLimit = 3
  static let rebuildWindow = 10.0

  /// How many of this recording's rebuilds (their uptimes) fall inside the window before `now`.
  static func recentRebuilds(_ times: [Double], now: Double) -> Int {
    times.filter { now - $0 <= rebuildWindow }.count
  }

  /// What a route change while dictating does (#142): never stop. The input moving is followed (the engine change that
  /// comes with it rebuilds onto the new input); moving back onto the pick is named as such (#139).
  static func routeChange(inputChanged: Bool, backOnPick: Bool) -> DictationRouteChange {
    backOnPick ? .backOnPick : inputChanged ? .follow : .keep
  }

  /// #139: the input is back on the microphone that was picked, and the tap was installed on another one (the headset
  /// that took the input as dictation started).
  static func backOnPick(picked: String?, current: String?, tapInput: String?) -> Bool {
    guard let picked else { return false }
    return current == picked && tapInput != picked
  }

  /// The `dictation_route_change` log line (#133, #139), and the state a stop for "the microphone changed" copies: why
  /// the system says the route changed, the input port types before and after, the input the tap was installed on,
  /// the one now, the pick (null for Automatic), and what was done.
  static func routeChangeFields(
    sinceStart: Double, reason: String, inputBefore: [String], inputAfter: [String], inputAtStart: String?,
    inputNow: String?, picked: String?, action: DictationRouteChange
  ) -> [String: JSONValue] {
    [
      "where": "route_change", "ms_since_start": .int(Int((sinceStart * 1000).rounded(.down))),
      "reason": .string(reason), "input_before": .string(inputBefore.joined(separator: ",")),
      "input_after": .string(inputAfter.joined(separator: ",")),
      "input_id_start": inputAtStart.map(JSONValue.string) ?? .null,
      "input_id_now": inputNow.map(JSONValue.string) ?? .null, "picked": picked.map(JSONValue.string) ?? .null,
      "action": .string(action.rawValue),
    ]
  }

  /// The `dictation_engine_config` log line, and the state a failure copies: what the microphone was when the tap was
  /// installed, what it is now, and what was done.
  static func engineChangeFields(
    sinceStart: Double, thisEngine: Bool, running: Bool, before: DictationAudioShape?, after: DictationAudioShape,
    action: DictationEngineChange
  ) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [
      "where": "engine_config", "ms_since_start": .int(Int((sinceStart * 1000).rounded(.down))),
      "this_engine": .bool(thisEngine), "engine_running": .bool(running), "action": .string(action.rawValue),
    ]
    fields.merge(after.fields("after")) { first, _ in first }
    if let before { fields.merge(before.fields("before")) { first, _ in first } }
    return fields
  }
}

enum DictationEngineChange: String, Sendable {
  case ignore, rebuild, fail
}

/// What a route change while dictating did (#139, #142): nothing, followed the input to another microphone, or the
/// input came back to the pick. It never stops dictation.
enum DictationRouteChange: String, Sendable {
  case keep, follow
  case backOnPick = "back_on_pick"
}

/// The microphone as the audio session reports it at one moment (`AVAudioSession`'s sample rate, input channels,
/// route port types and I/O buffer duration), so an engine change can say what changed.
struct DictationAudioShape: Equatable, Sendable {
  var sampleRate: Double
  var channels: Int
  var inputPorts: [String]
  var outputPorts: [String]
  var ioBufferDuration: Double

  func fields(_ suffix: String) -> [String: JSONValue] {
    [
      "sample_rate_\(suffix)": .double(sampleRate), "channels_\(suffix)": .int(channels),
      "input_\(suffix)": .string(inputPorts.joined(separator: ",")),
      "output_\(suffix)": .string(outputPorts.joined(separator: ",")),
      "io_buffer_ms_\(suffix)": .double((ioBufferDuration * 1000).rounded()),
    ]
  }
}
