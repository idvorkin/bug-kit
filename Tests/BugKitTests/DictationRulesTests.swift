import Foundation
import Testing
@testable import BugKit

// The audio session's category and options, as AVDictationCapture.keepsDiscoveryActivation reads them.
@Test func discoveryKeepsActivationOnlyForPlainMixingHosts() {
  // .playback with .mixWithOthers; .ambient with no options
  #expect(
    DictationRules.keepsDiscoveryActivation(
      ambient: false, mixesWithOthers: true, ducksOthers: false, interruptsSpokenAudio: false))
  #expect(
    DictationRules.keepsDiscoveryActivation(
      ambient: true, mixesWithOthers: false, ducksOthers: false, interruptsSpokenAudio: false))
  // .playback with [.mixWithOthers, .duckOthers]
  #expect(
    !DictationRules.keepsDiscoveryActivation(
      ambient: false, mixesWithOthers: true, ducksOthers: true, interruptsSpokenAudio: false))
  // .playback with .interruptSpokenAudioAndMixWithOthers, which also holds .mixWithOthers' bit
  #expect(
    !DictationRules.keepsDiscoveryActivation(
      ambient: false, mixesWithOthers: true, ducksOthers: false, interruptsSpokenAudio: true))
  // .ambient with .duckOthers
  #expect(
    !DictationRules.keepsDiscoveryActivation(
      ambient: true, mixesWithOthers: false, ducksOthers: true, interruptsSpokenAudio: false))
  // .soloAmbient or .playback with no options
  #expect(
    !DictationRules.keepsDiscoveryActivation(
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

// #128, #142: the engine stops when the input changes; it is rebuilt on the new input whenever that comes, so a
// headset settling at start and a mid-dictation move (CG #1398: AirPods HFP 24 kHz mono to USB 48 kHz stereo, 1065 ms
// in) both keep listening. Only a run of rebuilds (a route flapping) stops it.
@Test func aStoppedEngineIsRebuiltOnTheNewInputWheneverItChanges() {
  // Still running: only logged.
  #expect(DictationRules.engineChange(running: true, recentRebuilds: 0) == .ignore)
  #expect(DictationRules.engineChange(running: true, recentRebuilds: 9) == .ignore)
  // Stopped: rebuilt, early or late, up to the limit in the window.
  #expect(DictationRules.engineChange(running: false, recentRebuilds: 0) == .rebuild)
  #expect(DictationRules.engineChange(running: false, recentRebuilds: 2) == .rebuild)
  #expect(DictationRules.engineChange(running: false, recentRebuilds: 3) == .fail)
}

// #142: rebuilds count only inside the window, so a route that changes now and then keeps following it.
@Test func onlyRecentRebuildsCountTowardTheLimit() {
  #expect(DictationRules.recentRebuilds([], now: 100) == 0)
  #expect(DictationRules.recentRebuilds([95, 99], now: 100) == 2)
  #expect(DictationRules.recentRebuilds([90, 99], now: 100) == 2)
  #expect(DictationRules.recentRebuilds([89.9, 99], now: 100) == 1)
  #expect(DictationRules.recentRebuilds([1, 2, 3], now: 100) == 0)
}

// #142: a route change never stops dictation; it is logged as following the new input, or back on the pick (#139).
@Test func aRouteChangeFollowsTheNewInput() {
  #expect(DictationRules.routeChange(inputChanged: true, backOnPick: false) == .follow)
  #expect(DictationRules.routeChange(inputChanged: true, backOnPick: true) == .backOnPick)
  #expect(DictationRules.routeChange(inputChanged: false, backOnPick: false) == .keep)
}

@Test func anEngineChangeCarriesWhatChanged() {
  let before = DictationAudioShape(
    sampleRate: 48_000, channels: 1, inputPorts: ["MicrophoneBuiltIn"], outputPorts: ["Speaker"], ioBufferDuration: 0.02
  )
  let after = DictationAudioShape(
    sampleRate: 24_000, channels: 1, inputPorts: ["BluetoothHFP"], outputPorts: ["BluetoothHFP"],
    ioBufferDuration: 0.016)
  let fields = DictationRules.engineChangeFields(
    sinceStart: 0.1444, thisEngine: true, running: false, before: before, after: after, action: .rebuild)
  #expect(fields["where"] == .string("engine_config"))
  #expect(fields["ms_since_start"] == .int(144))
  #expect(fields["this_engine"] == .bool(true))
  #expect(fields["engine_running"] == .bool(false))
  #expect(fields["sample_rate_before"] == .double(48_000))
  #expect(fields["sample_rate_after"] == .double(24_000))
  #expect(fields["channels_before"] == .int(1))
  #expect(fields["channels_after"] == .int(1))
  #expect(fields["input_before"] == .string("MicrophoneBuiltIn"))
  #expect(fields["input_after"] == .string("BluetoothHFP"))
  #expect(fields["output_after"] == .string("BluetoothHFP"))
  #expect(fields["io_buffer_ms_before"] == .double(20))
  #expect(fields["io_buffer_ms_after"] == .double(16))
  #expect(fields["action"] == .string("rebuild"))
  // No shape at start (the change came before one was read): the after fields alone.
  let early = DictationRules.engineChangeFields(
    sinceStart: 0, thisEngine: false, running: false, before: nil, after: after, action: .fail)
  #expect(early["sample_rate_before"] == nil)
  #expect(early["sample_rate_after"] == .double(24_000))
}

// #139: back on the pick needs a pick, the input now on it, and the tap installed on another input.
@Test func backOnThePickNeedsAPickTheTapLeft() {
  let pick = "Built-In Microphone"
  let airPods = "20:F4:D4:8F:F7:2B-tsco"
  #expect(DictationRules.backOnPick(picked: pick, current: pick, tapInput: airPods))
  #expect(!DictationRules.backOnPick(picked: pick, current: pick, tapInput: pick))
  #expect(!DictationRules.backOnPick(picked: pick, current: airPods, tapInput: airPods))
  #expect(!DictationRules.backOnPick(picked: nil, current: pick, tapInput: airPods))
}

// #133, #139: a route change while dictating says why, from what to what, and what was done.
@Test func aRouteChangeCarriesWhatChanged() {
  let fields = DictationRules.routeChangeFields(
    sinceStart: 4.1024, reason: "new_device_available", inputBefore: ["BluetoothHFP"],
    inputAfter: ["MicrophoneBuiltIn"],
    inputAtStart: "20:F4:D4:8F:F7:2B-tsco", inputNow: "Built-In Microphone", picked: "Built-In Microphone",
    action: .backOnPick)
  #expect(fields["where"] == .string("route_change"))
  #expect(fields["ms_since_start"] == .int(4102))
  #expect(fields["reason"] == .string("new_device_available"))
  #expect(fields["input_before"] == .string("BluetoothHFP"))
  #expect(fields["input_after"] == .string("MicrophoneBuiltIn"))
  #expect(fields["input_id_start"] == .string("20:F4:D4:8F:F7:2B-tsco"))
  #expect(fields["input_id_now"] == .string("Built-In Microphone"))
  #expect(fields["picked"] == .string("Built-In Microphone"))
  #expect(fields["action"] == .string("back_on_pick"))
  let automatic = DictationRules.routeChangeFields(
    sinceStart: 3, reason: "old_device_unavailable", inputBefore: ["BluetoothHFP"], inputAfter: [], inputAtStart: nil,
    inputNow: nil, picked: nil, action: .follow)
  #expect(automatic["picked"] == JSONValue.null)
  #expect(automatic["input_id_now"] == JSONValue.null)
  #expect(automatic["input_after"] == .string(""))
  #expect(automatic["action"] == .string("follow"))
}
