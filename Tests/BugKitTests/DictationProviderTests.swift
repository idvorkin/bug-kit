import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import Testing
@testable import BugKit

@Test func dictationSegmentsKeepFinalsAndReplaceInterims() {
  var text = DictationSegments()
  #expect(text.update(start: 0, text: "turn lef", final: false) == "turn lef")
  #expect(text.update(start: 0, text: "turn left", final: true) == "turn left")
  #expect(text.update(start: 0, text: "turn late", final: false) == "turn left")
  #expect(text.update(start: 2, text: "then", final: false) == "turn left then")
  #expect(text.update(start: 2, text: "then stop", final: true) == "turn left then stop")
  #expect(text.update(start: 2, text: "then stop", final: true) == "turn left then stop")
  #expect(text.update(start: 4, text: "", final: true) == "turn left then stop")
}

@Test func deepgramStreamsAudioAndDrainsFinalWords() async throws {
  let socket = DictationTestSocket()
  let provider = DeepgramDictationProvider(credential: { .apiKey("test-only") }, socketFactory: { _, _ in socket })
  let stream = try await provider.start()
  let words = Task { () throws -> [String] in
    var all: [String] = []
    for try await value in stream { all.append(value) }
    return all
  }
  let audio = Data([0, 0, 1, 0])
  try await provider.appendAudio(audio)
  await socket.push(result(start: 0, text: "turn lef", final: false))
  await socket.push(result(start: 0, text: "turn left", final: true))
  await socket.push(result(start: 2, text: "then", final: false))
  try await provider.finish()
  let transcript = try await words.value
  #expect(transcript.last == "turn left then stop")
  #expect(await socket.audio == [audio])
  #expect(await socket.closeStreamSent)
  #expect(await socket.closed)
}

@Test func deepgramCancelEndsResultsAndReleasesSocket() async throws {
  let socket = DictationTestSocket()
  let provider = DeepgramDictationProvider(credential: { .accessToken("test-token") }, socketFactory: { _, _ in socket })
  let stream = try await provider.start()
  let completion = Task { for try await _ in stream {} }
  await provider.cancel()
  try await completion.value
  #expect(await socket.closed)
}

@Test func deepgramMissingCredentialFailsBeforeOpeningSocket() async {
  let socket = DictationTestSocket()
  let provider = DeepgramDictationProvider(credential: { .apiKey("  ") }, socketFactory: { _, _ in socket })
  do { _ = try await provider.start(); Issue.record("missing credential started a socket") }
  catch { #expect(error as? DictationProviderError == .missingCredential) }
  #expect(await socket.opens == 0)
}

@Test func deepgramCancelDuringCredentialFetchCannotStartLate() async throws {
  let gate = DictationCredentialGate()
  let socket = DictationTestSocket()
  let provider = DeepgramDictationProvider(credential: { await gate.wait() }, socketFactory: { _, _ in socket })
  let start = Task { try await provider.start() }
  for _ in 0..<1_000 {
    if await gate.waiting { break }
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(await gate.waiting)
  await provider.cancel()
  await gate.release()
  do { _ = try await start.value; Issue.record("canceled credential request opened a socket") }
  catch { #expect(error is CancellationError) }
  #expect(await socket.opens == 0)
}

@Test func deepgramUnreadableResponseFailsTheResultStream() async throws {
  let socket = DictationTestSocket()
  let provider = DeepgramDictationProvider(credential: { .apiKey("test-only") }, socketFactory: { _, _ in socket })
  let stream = try await provider.start()
  await socket.push(.string("not json"))
  do { for try await _ in stream {}; Issue.record("unreadable response was accepted") }
  catch { #expect(error is DecodingError) }
  await provider.cancel()
}

@Test func deepgramHandshakeCarriesCredentialsOnlyInTheSubprotocol() async throws {
  for (credential, scheme) in [(DeepgramDictationCredential.apiKey("test-key"), "token"),
                               (.accessToken("test-token"), "bearer")] {
    let opened = DictationOpenedSocket()
    let provider = DeepgramDictationProvider(credential: { credential }, socketFactory: { url, credential in
      let socket = URLSessionDictationSocket(url: url, credential: credential)
      opened.socket = socket
      return DictationTestSocket()
    })
    _ = try await provider.start()
    await provider.cancel()
    let socket = try #require(opened.socket)
    let request = try #require(socket.handshake)
    let url = try #require(request.url?.absoluteString)
    #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "\(scheme), \(credential.value)")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(!url.contains(credential.value))
    #expect(url.contains("encoding=linear16"))
    await socket.close()
  }
}

private final class DictationOpenedSocket: @unchecked Sendable { var socket: URLSessionDictationSocket? }

private func result(start: Double, text: String, final: Bool) -> URLSessionWebSocketTask.Message {
  let body: [String: Any] = ["type": "Results", "start": start, "is_final": final,
    "channel": ["alternatives": [["transcript": text]]]]
  return .data(try! JSONSerialization.data(withJSONObject: body))
}

private actor DictationTestSocket: DictationSocket {
  private var queue: [URLSessionWebSocketTask.Message] = []
  private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
  private(set) var audio: [Data] = []
  private(set) var closeStreamSent = false
  private(set) var closed = false
  private(set) var opens = 0
  func open() async throws { opens += 1; closed = false }
  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    switch message {
    case .data(let data): audio.append(data)
    case .string(let text):
      if text.contains("CloseStream") {
        closeStreamSent = true
        push(result(start: 2, text: "then stop", final: true))
        push(.string(#"{"type":"Metadata"}"#))
      }
    @unknown default: break
    }
  }
  func receive() async throws -> URLSessionWebSocketTask.Message {
    if !queue.isEmpty { return queue.removeFirst() }
    if closed { throw CancellationError() }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func push(_ value: URLSessionWebSocketTask.Message) {
    if let waiter { self.waiter = nil; waiter.resume(returning: value) }
    else { queue.append(value) }
  }
  func close() async {
    closed = true
    waiter?.resume(throwing: CancellationError()); waiter = nil
  }
}

private actor DictationCredentialGate {
  private var continuation: CheckedContinuation<DeepgramDictationCredential, Never>?
  var waiting: Bool { continuation != nil }
  func wait() async -> DeepgramDictationCredential { await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(returning: .apiKey("test-only")); continuation = nil }
}
