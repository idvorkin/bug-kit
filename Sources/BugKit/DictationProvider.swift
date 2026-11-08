import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A fresh instance per dictation. Audio is mono, signed little-endian PCM16 at 16 kHz.
/// Each stream value replaces the entire spoken portion of the note; typed text is kept by NoteDictation.
/// `finish` must flush pending results and close the stream; `cancel` must release pending network work.
public protocol BugDictationProvider: Sendable {
  var name: String { get }
  var requiresSpeechAuthorization: Bool { get }
  var onDeviceRecognition: Bool? { get async }
  func start() async throws -> AsyncThrowingStream<String, Error>
  func appendAudio(_ pcm16: Data) async throws
  func finish() async throws
  func cancel() async
}

public extension BugDictationProvider {
  var onDeviceRecognition: Bool? { get async { nil } }
}

/// Apps can fetch a short-lived access token from their server instead of distributing a vendor API key.
public enum DeepgramDictationCredential: Sendable {
  case apiKey(String)
  case accessToken(String)
  var value: String {
    switch self { case .apiKey(let value), .accessToken(let value): value }
  }
}

/// A microphone offered by iOS. The UID is a preference, not a guarantee about the current route.
public struct BugMicrophone: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let kind: String
  public init(id: String, name: String, kind: String) { self.id = id; self.name = name; self.kind = kind }
}

/// Streaming services revise interim text and finalize one segment at a time.
/// Replayed finals and late interims must not duplicate or overwrite committed words.
struct DictationSegments: Sendable {
  private struct Segment: Sendable { var start: Double; var text: String; var final: Bool }
  private var segments: [Segment] = []
  mutating func update(start: Double, text: String, final: Bool) -> String {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let index = segments.firstIndex(where: { $0.start == start }) {
      if !segments[index].final { segments[index] = Segment(start: start, text: text, final: final) }
    } else if !text.isEmpty {
      segments.append(Segment(start: start, text: text, final: final))
      segments.sort { $0.start < $1.start }
    }
    return segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
  }
}

enum DictationProviderError: Error, LocalizedError, Equatable {
  case notStarted, invalidEndpoint, missingCredential, invalidResponse, audioOverflow, finishTimedOut
  var errorDescription: String? {
    switch self {
    case .notStarted: "Speech recognition has not started"
    case .invalidEndpoint: "The speech service needs a secure WebSocket endpoint"
    case .missingCredential: "The speech service has no API key"
    case .invalidResponse: "The speech service returned an unreadable response"
    case .finishTimedOut: "The speech service did not finish in time"
    case .audioOverflow: "The speech service could not keep up with the microphone. Please try again."
    }
  }
}

/// Small transport boundary so streaming behavior can be verified without service credentials.
protocol DictationSocket: Sendable {
  func open() async throws
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func close() async
}

final class URLSessionDictationSocket: DictationSocket, @unchecked Sendable {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  var handshake: URLRequest? { task.originalRequest }
  init(url: URL, credential: DeepgramDictationCredential) {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    session = URLSession(configuration: config)
    // Deepgram reads credentials from the subprotocol; iOS may drop a custom Authorization header in the handshake.
    switch credential {
    case .apiKey(let key): task = session.webSocketTask(with: url, protocols: ["token", key])
    case .accessToken(let token): task = session.webSocketTask(with: url, protocols: ["bearer", token])
    }
    task.maximumMessageSize = 1_048_576
  }
  func open() async throws {
    task.resume()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      task.sendPing { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }
  func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
  func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
  func close() async {
    task.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
  }
}

/// Deepgram's streaming Listen API. The app supplies credentials from its own key store or short-lived token
/// service; BugKit never persists them. For another service, supply your own BugDictationProvider instead.
public actor DeepgramDictationProvider: BugDictationProvider {
  public nonisolated let name = "Deepgram"
  public nonisolated let requiresSpeechAuthorization = false
  private let credential: @Sendable () async throws -> DeepgramDictationCredential
  private let endpoint: URL
  private let model: String
  private let language: String
  private let socketFactory: @Sendable (URL, DeepgramDictationCredential) -> any DictationSocket
  private var socket: (any DictationSocket)?
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?
  private var receiver: Task<Void, Never>?
  private var segments = DictationSegments()
  private var finishing = false
  private var generation = UUID()

  public init(
    credential: @escaping @Sendable () async throws -> DeepgramDictationCredential,
    model: String = "nova-3", language: String = "en",
    endpoint: URL = URL(string: "wss://api.deepgram.com/v1/listen")!
  ) {
    self.credential = credential; self.model = model; self.language = language; self.endpoint = endpoint
    self.socketFactory = { URLSessionDictationSocket(url: $0, credential: $1) }
  }

  init(credential: @escaping @Sendable () async throws -> DeepgramDictationCredential,
       socketFactory: @escaping @Sendable (URL, DeepgramDictationCredential) -> any DictationSocket) {
    self.credential = credential; self.endpoint = URL(string: "wss://api.deepgram.com/v1/listen")!
    self.model = "nova-3"; self.language = "en"; self.socketFactory = socketFactory
  }

  public func start() async throws -> AsyncThrowingStream<String, Error> {
    await cancel()
    let owner = UUID()
    generation = owner
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
          components.scheme == "wss", components.host != nil,
          components.user == nil, components.password == nil else { throw DictationProviderError.invalidEndpoint }
    components.queryItems = (components.queryItems ?? []) + [
      URLQueryItem(name: "model", value: model), URLQueryItem(name: "language", value: language),
      URLQueryItem(name: "encoding", value: "linear16"), URLQueryItem(name: "sample_rate", value: "16000"),
      URLQueryItem(name: "channels", value: "1"), URLQueryItem(name: "interim_results", value: "true"),
      URLQueryItem(name: "smart_format", value: "true"),
    ]
    guard let url = components.url else { throw DictationProviderError.invalidEndpoint }
    let credential = try await credential()
    try Task.checkCancellation()
    guard generation == owner else { throw CancellationError() }
    guard !credential.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationProviderError.missingCredential }
    let socket = socketFactory(url, credential)
    self.socket = socket
    do { try await socket.open() } catch {
      await socket.close(); if generation == owner { self.socket = nil }; throw error
    }
    guard generation == owner, !Task.isCancelled else { await socket.close(); throw CancellationError() }
    segments = DictationSegments()
    finishing = false
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
    self.continuation = continuation
    receiver = Task { [weak self] in await self?.receive(from: socket, owner: owner) }
    return stream
  }

  public func appendAudio(_ pcm16: Data) async throws {
    guard let socket, !finishing else { throw DictationProviderError.notStarted }
    try await socket.send(.data(pcm16))
  }

  public func finish() async throws {
    guard let socket else { return }
    let owner = generation
    finishing = true
    do { try await socket.send(.string(#"{"type":"CloseStream"}"#)) }
    catch { if generation == owner { await cancel() }; throw error }
    // CloseStream produces final Results, then Metadata. Bound a service that never closes its stream.
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while generation == owner, continuation != nil, ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    guard generation == owner else { throw CancellationError() }
    let timedOut = continuation != nil
    await cancel()
    if timedOut { throw DictationProviderError.finishTimedOut }
  }

  public func cancel() async {
    generation = UUID()
    receiver?.cancel(); receiver = nil
    continuation?.finish(); continuation = nil
    let old = socket; socket = nil
    await old?.close()
  }

  private func receive(from socket: any DictationSocket, owner: UUID) async {
    do {
      while !Task.isCancelled, generation == owner {
        let message = try await socket.receive()
        guard generation == owner else { return }
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: continue
        }
        let result = try JSONDecoder().decode(DeepgramResult.self, from: data)
        if result.type == "Results", let alternative = result.channel?.alternatives.first {
          let text = segments.update(start: result.start ?? 0, text: alternative.transcript, final: result.is_final ?? false)
          continuation?.yield(text)
        } else if result.type == "Error" {
          // Do not surface a server-supplied body that might echo credentials or spoken content.
          throw DictationProviderError.invalidResponse
        } else if result.type == "Metadata", finishing {
          continuation?.finish(); continuation = nil
          return
        }
      }
    } catch {
      guard generation == owner else { return }
      continuation?.finish(throwing: error)
      continuation = nil
    }
  }
}

private struct DeepgramResult: Decodable {
  let type: String
  let start: Double?
  let is_final: Bool?
  let channel: Channel?
  struct Channel: Decodable { let alternatives: [Alternative] }
  struct Alternative: Decodable { let transcript: String }
}
