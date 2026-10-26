#if canImport(UIKit) && os(iOS)
import SwiftUI

/// The microphone picker and the live input level, for any voice input built on `NoteDictation` (bug-0b9).
/// Put it beside the app's own mic button; the report dialog shows the same controls under its note.
public struct BugVoiceInputControls: View {
  @ObservedObject private var dictation: NoteDictation

  public init(dictation: NoteDictation) { self.dictation = dictation }

  public var body: some View {
    HStack(spacing: 12) {
      BugMicrophonePicker(dictation: dictation)
      BugInputLevelMeter(level: dictation.inputLevel)
        .frame(width: 64)
    }
  }
}

/// Automatic, the inputs iOS offers, and "Refresh microphones". The pick applies to the next dictation; the menu is
/// off while dictation is busy or the host holds the microphone (`hostMicrophoneBusy`).
public struct BugMicrophonePicker: View {
  @ObservedObject private var dictation: NoteDictation

  public init(dictation: NoteDictation) { self.dictation = dictation }

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
    .accessibilityIdentifier("report-microphone-picker")
  }
}

/// A horizontal bar for an input level from 0 (empty) to 1 (full scale), such as `NoteDictation.inputLevel`.
/// It turns orange near full scale, where the voice is about to clip.
public struct BugInputLevelMeter: View {
  private let level: Double

  public init(level: Double) { self.level = min(max(level, 0), 1) }

  public var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(level > 0.9 ? Color.orange : Color.green)
          .frame(width: geometry.size.width * level)
      }
    }
    .frame(height: 6)
    .animation(.linear(duration: 0.05), value: level)
    .accessibilityElement()
    .accessibilityLabel("Input level")
    .accessibilityValue("\(Int((level * 100).rounded())) percent")
    .accessibilityIdentifier("voice-input-level")
  }
}
#endif
