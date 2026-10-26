import Foundation
import Testing
@testable import BugKit

private func pcm16(_ samples: [Int16]) -> Data {
  var data = Data()
  for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
  return data
}

private func sine(amplitude: Double, count: Int = 320) -> Data {
  pcm16((0..<count).map { Int16(amplitude * 32_767 * sin(2 * .pi * 440 * Double($0) / 16_000)) })
}

@Test func silenceReadsAsAnEmptyMeter() {
  #expect(DictationLevel.normalized(decibels: DictationLevel.decibels(pcm16: pcm16(Array(repeating: 0, count: 320)))) == 0)
  #expect(DictationLevel.normalized(decibels: DictationLevel.decibels(pcm16: Data())) == 0)
  // A whisper of noise below the -60 dB floor is still empty.
  #expect(DictationLevel.normalized(decibels: DictationLevel.decibels(pcm16: pcm16([1, -1, 1, -1]))) == 0)
}

@Test func fullScaleReadsAsAFullMeter() {
  let square = pcm16((0..<320).map { $0 % 2 == 0 ? Int16.max : Int16.min })
  #expect(abs(DictationLevel.decibels(pcm16: square)) < 0.01)
  #expect(DictationLevel.normalized(decibels: DictationLevel.decibels(pcm16: square)) > 0.99)
  // A full-scale sine has an RMS 3 dB under full scale.
  let level = DictationLevel.normalized(decibels: DictationLevel.decibels(pcm16: sine(amplitude: 1)))
  #expect(level > 0.94 && level < 0.96)
}

@Test func theMeterIsLinearInDecibels() {
  // A sine at a tenth of full scale is -23 dBFS RMS: (60 - 23) / 60 of the way up.
  let level = DictationLevel.normalized(decibels: DictationLevel.decibels(pcm16: sine(amplitude: 0.1)))
  #expect(abs(level - 37.0 / 60) < 0.01)
  #expect(DictationLevel.normalized(decibels: 6) == 1)
  #expect(DictationLevel.normalized(decibels: -90) == 0)
}

@Test func theMeterRisesAtOnceAndFallsSmoothly() throws {
  var meter = DictationLevel()
  let loud = sine(amplitude: 1), quiet = pcm16(Array(repeating: 0, count: 320))
  let first = meter.hear(pcm16: loud, at: 0)
  let peak = try #require(first)
  #expect(peak > 0.9)
  // Each silent buffer keeps `release` of the level: falling, never jumping to empty.
  var previous = peak
  for i in 1...10 {
    _ = meter.hear(pcm16: quiet, at: Double(i))
    #expect(meter.smoothed < previous)
    #expect(meter.smoothed > previous * 0.7)
    previous = meter.smoothed
  }
  #expect(abs(meter.smoothed - peak * pow(DictationLevel.release, 10)) < 1e-9)
  // Speech coming back is shown at once.
  _ = meter.hear(pcm16: loud, at: 11)
  #expect(meter.smoothed == peak)
}

@Test(arguments: [48_000.0, 44_100.0])
func theMeterPublishesAboutTwentyTimesASecond(sampleRate: Double) {
  var meter = DictationLevel()
  let loud = sine(amplitude: 1)
  // Ten seconds of 1024-frame tap buffers: about 47 (48 kHz) or 43 (44.1 kHz) a second, not a divisor of 20 Hz.
  let buffers = Int(10 * sampleRate / 1024)
  let published = (0..<buffers).compactMap { meter.hear(pcm16: loud, at: Double($0) * 1024 / sampleRate) }
  #expect(published.count >= 195 && published.count <= 201)
}

@Test func aPeakBetweenPublishesStillShows() throws {
  var meter = DictationLevel()
  let quiet = pcm16(Array(repeating: 0, count: 320))
  let start = meter.hear(pcm16: quiet, at: 0)
  let peak = meter.hear(pcm16: sine(amplitude: 1), at: 0.02)
  let next = meter.hear(pcm16: quiet, at: 0.06)
  #expect(start == 0)
  #expect(peak == nil)  // throttled
  let shown = try #require(next)
  #expect(shown > 0.7)
}

@Test func resetEmptiesTheMeter() {
  var meter = DictationLevel()
  _ = meter.hear(pcm16: sine(amplitude: 1), at: 0)
  meter.reset()
  #expect(meter.smoothed == 0)
  let again = meter.hear(pcm16: pcm16([0]), at: 0.001)
  #expect(again == 0)  // publishes at once after a reset
}
