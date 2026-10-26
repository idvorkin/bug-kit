import Foundation

/// The arithmetic behind the voice input meter (bug-0b9): how loud one buffer of PCM16 is, smoothed so the meter
/// does not flicker, and throttled so SwiftUI redraws about 20 times a second instead of once per audio buffer.
/// Platform-free so the host tests cover it; `NoteDictation` feeds it each captured buffer on the main actor.
struct DictationLevel: Sendable {
  /// The quietest level the meter shows; anything below reads as empty.
  static let floorDecibels = -60.0
  /// At most one published value per interval: 20 Hz.
  static let interval = 0.05
  /// How much of the previous level survives one buffer while the voice falls (the rise is immediate).
  static let release = 0.8

  /// The smoothed level, 0...1, including buffers the throttle did not publish.
  private(set) var smoothed = 0.0
  private var nextDue: Double?

  /// Root mean square of mono, signed little-endian PCM16, in dBFS (0 is full scale; silence is -infinity).
  static func decibels(pcm16: Data) -> Double {
    let count = pcm16.count / 2
    guard count > 0 else { return -.infinity }
    var sum = 0.0
    pcm16.withUnsafeBytes { bytes in
      for i in 0..<count {
        let sample = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32_768
        sum += sample * sample
      }
    }
    let rms = (sum / Double(count)).squareRoot()
    return rms > 0 ? 20 * log10(rms) : -.infinity
  }

  /// dBFS onto 0...1, linear in decibels from `floorDecibels` (0) to full scale (1).
  static func normalized(decibels: Double) -> Double {
    guard decibels.isFinite else { return decibels > 0 ? 1 : 0 }
    return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
  }

  /// One captured buffer heard at `time` (seconds, any monotonic clock). Returns the level to publish when the
  /// throttle's next due time has come, else nil. A loud buffer between publishes still shows,
  /// because the smoothed level rises at once and falls only by `release` per buffer.
  mutating func hear(pcm16: Data, at time: Double) -> Double? {
    let level = Self.normalized(decibels: Self.decibels(pcm16: pcm16))
    smoothed = level >= smoothed ? level : smoothed * Self.release + level * (1 - Self.release)
    if let nextDue, time < nextDue { return nil }
    // Due times step by the interval, so buffers that do not divide it evenly still average 20 Hz; after a gap
    // in the audio the schedule restarts from now.
    let next = (nextDue ?? time) + Self.interval
    nextDue = next > time ? next : time + Self.interval
    return smoothed
  }

  mutating func reset() { self = Self() }
}
