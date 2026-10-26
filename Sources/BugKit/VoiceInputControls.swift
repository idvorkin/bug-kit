#if canImport(UIKit) && os(iOS)
import SwiftUI

/// The microphone picker and the live input level, for any voice input built on `NoteDictation` (bug-0b9).
/// Put it beside the app's own mic button; the report dialog shows the same controls under its note.
/// The picker's accessibility identifier is `<identifierPrefix>-microphone-picker` and the meter's
/// `<identifierPrefix>-level`.
public struct BugVoiceInputControls: View {
  @ObservedObject private var dictation: NoteDictation
  private let identifierPrefix: String

  public init(dictation: NoteDictation, identifierPrefix: String = "voice-input") {
    self.dictation = dictation; self.identifierPrefix = identifierPrefix
  }

  public var body: some View {
    HStack(spacing: 12) {
      BugMicrophonePicker(dictation: dictation, accessibilityIdentifier: "\(identifierPrefix)-microphone-picker")
      BugInputLevelMeter(level: dictation.level, accessibilityIdentifier: "\(identifierPrefix)-level")
        .frame(width: 64)
    }
  }
}

/// Automatic, the inputs iOS offers, and "Refresh microphones". The pick applies to the next dictation; the menu is
/// off while dictation is busy or the host holds the microphone (`hostMicrophoneBusy`).
public struct BugMicrophonePicker: View {
  @ObservedObject private var dictation: NoteDictation
  private let identifier: String

  public init(dictation: NoteDictation, accessibilityIdentifier: String = "voice-input-microphone-picker") {
    self.dictation = dictation; identifier = accessibilityIdentifier
  }

  public var body: some View {
    Menu {
      Button { dictation.selectMicrophone(nil) } label: {
        if dictation.selectedMicrophoneID == nil { Label("Automatic", systemImage: "checkmark") }
        else { Text("Automatic") }
      }
      ForEach(dictation.microphones) { microphone in
        Button { dictation.selectMicrophone(microphone.id) } label: {
          if dictation.selectedMicrophoneID == microphone.id { Label(microphone.name, systemImage: "checkmark") }
          else { Text(microphone.name) }
        }
      }
      Button("Refresh microphones") {
        Task { await dictation.refreshMicrophones() }
      }
    } label: {
      LabeledContent("Microphone", value: dictation.selectedMicrophoneName)
    }
    .disabled(dictation.busy || dictation.hostMicrophoneBusy())
    .accessibilityLabel("Microphone: \(dictation.selectedMicrophoneName)")
    .accessibilityIdentifier(identifier)
  }
}

/// A horizontal bar for an input level from 0 (empty) to 1 (full scale). It turns orange near full scale, where the
/// voice is about to clip. Observing `NoteDictation.level` redraws only the bar, not the views around it.
public struct BugInputLevelMeter: View {
  @ObservedObject private var level: DictationInputLevel
  private let identifier: String

  /// A live level, such as `NoteDictation.level`.
  public init(level: DictationInputLevel, accessibilityIdentifier: String = "voice-input-level") {
    self.level = level; identifier = accessibilityIdentifier
  }

  /// A level from the app's own capture, 0...1.
  public init(value: Double, accessibilityIdentifier: String = "voice-input-level") {
    self.init(level: DictationInputLevel(value), accessibilityIdentifier: accessibilityIdentifier)
  }

  public var body: some View {
    let value = min(max(level.value, 0), 1)
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(value > 0.9 ? Color.orange : Color.green)
          .frame(width: geometry.size.width * value)
      }
    }
    .frame(height: 6)
    .animation(.linear(duration: 0.05), value: value)
    .accessibilityElement()
    .accessibilityLabel("Input level")
    .accessibilityValue("\(Int((value * 100).rounded())) percent")
    .accessibilityIdentifier(identifier)
  }
}
#endif
