#if canImport(UIKit) && os(iOS)
import AVFoundation
import Speech

@MainActor
final class AppleDictationProvider: BugDictationProvider {
  nonisolated let name = "Apple Speech"
  nonisolated let requiresSpeechAuthorization = true
  var onDeviceRecognition: Bool? { request?.requiresOnDeviceRecognition }
  private let logger: BugLogger
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?
  private var join = DictationJoin(typed: "")
  private var owner = UUID()
  private var finishing = false
  private var submittedAudioSeconds: Double = 0

  init(logger: @escaping BugLogger) { self.logger = logger }

  func start() async throws -> AsyncThrowingStream<String, Error> {
    await cancel()
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      throw DictationProviderError.notStarted
    }
    let generation = UUID(); owner = generation
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    self.request = request
    join = DictationJoin(typed: ""); finishing = false; submittedAudioSeconds = 0
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
    self.continuation = continuation
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let segments = result?.bestTranscription.segments ?? []
      let first = segments.first?.timestamp ?? 0
      let end = segments.last.map { $0.timestamp + $0.duration } ?? 0
      let final = result?.isFinal ?? false
      Task { @MainActor in
        guard let self, self.owner == generation else { return }
        if let text {
          let previous = self.join.current, previousEnd = self.join.currentEnd
          if self.join.update(text: text, firstStart: first, lastEnd: end, isFinal: final,
                              observedAudioEnd: self.submittedAudioSeconds) {
            self.logger("dictation_pause", ["kept_chars": .int(previous.count), "new_chars": .int(text.count),
              "prev_end_s": .double(previousEnd), "new_start_s": .double(first), "is_final": .bool(final)])
          }
          self.continuation?.yield(self.join.note)
        }
        if final || DictationRules.endsQuietly(error, finishing: self.finishing) {
          self.continuation?.finish(); self.continuation = nil
        } else if error != nil {
          self.continuation?.finish(throwing: DictationProviderError.invalidResponse); self.continuation = nil
        }
      }
    }
    return stream
  }

  func appendAudio(_ pcm16: Data) async throws {
    guard let request, let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                  channels: 1, interleaved: true),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm16.count / 2)),
          let samples = buffer.int16ChannelData else { throw DictationProviderError.notStarted }
    buffer.frameLength = buffer.frameCapacity
    pcm16.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples[0], count: pcm16.count))
    request.append(buffer)
    submittedAudioSeconds += Double(buffer.frameLength) / format.sampleRate
  }

  func finish() async throws {
    let generation = owner
    finishing = true
    request?.endAudio(); task?.finish()
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while owner == generation, continuation != nil, ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    guard owner == generation else { throw CancellationError() }
    let timedOut = continuation != nil
    await cancel()
    if timedOut { throw DictationProviderError.finishTimedOut }
  }

  func cancel() async {
    owner = UUID()
    task?.cancel(); task = nil; request = nil
    continuation?.finish(); continuation = nil
  }
}
#endif
