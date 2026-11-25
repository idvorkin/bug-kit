// Stories 042 to 045: pairing with the Cockpit by approving a card in the Inbox (bug-kit #144, option C). Every app
// of Igor's on a device shares one identity, a random id and a label, plus the Cockpit's address; each app asks for
// and keeps its own key with only its own scopes. `CockpitPairing` runs the flow: start a request, show its code,
// poll until Igor answers, keep the key. The design is docs/superpowers/specs/2026-11-24-shared-cockpit-pairing-
// design.md; the keyring's side is `POST /pair/start` and `POST /pair/poll`. Neither the handle nor the key is
// ever logged or printed.

import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif

/// This device as every app of Igor's names it to the Cockpit. The first app to pair makes it; the rest read it.
public struct CockpitDevice: Codable, Equatable, Sendable {
  /// A random UUID, made once per device and never changed. The Cockpit groups pending requests by it.
  public let deviceID: String
  /// What the approve card calls the device, as "Igor's iPhone 17 Pro". Igor can rename it.
  public var label: String
  /// The Cockpit's address, once one app knows it, so the next app needs nothing typed.
  public var cockpit: URL?

  public init(deviceID: String, label: String, cockpit: URL?) {
    self.deviceID = deviceID
    self.label = label
    self.cockpit = cockpit
  }

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case label, cockpit
  }

  /// A new identity: a fresh id, and `model` plus the id's first four characters, so two phones of one model get
  /// different labels.
  static func make(model: String) -> CockpitDevice {
    let id = UUID().uuidString
    return CockpitDevice(deviceID: id, label: "\(model) \(id.prefix(4).uppercased())", cockpit: nil)
  }

  /// The hardware model ("iPhone18,1"): the device's own name needs an entitlement on current iOS.
  public static func defaultModel() -> String { BugAppInfo.hardwareModel() }
}

/// What the card says the device is.
public enum CockpitPlatform: String, Codable, Sendable {
  case iOS, iPadOS, macOS, watchOS

  @MainActor public static var current: CockpitPlatform {
    #if os(macOS)
      return .macOS
    #elseif os(watchOS)
      return .watchOS
    #elseif canImport(UIKit)
      return UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
    #else
      return .macOS
    #endif
  }
}

/// What one app asks the Cockpit for: who it is and the scopes it needs, and nothing else.
public struct CockpitPairingRequest: Equatable, Sendable {
  /// A stable short name, as `exercise-analyzer`. The app's key is kept under it.
  public let app: String
  /// The app's name as Igor sees it on the card, as `Exercise Analyzer`.
  public let appLabel: String
  /// Only the scopes this app needs, as `ledger:write`.
  public let scopes: [String]
  /// The app's build, as `2.0.0 (3675)`.
  public let appVersion: String
  public let platform: CockpitPlatform

  public init(app: String, appLabel: String, scopes: [String], appVersion: String, platform: CockpitPlatform) {
    self.app = app
    self.appLabel = appLabel
    self.scopes = scopes
    self.appVersion = appVersion
    self.platform = platform
  }

  /// The request for the running app: its version from the main bundle and the platform it runs on.
  @MainActor public static func current(app: String, appLabel: String, scopes: [String]) -> CockpitPairingRequest {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    return CockpitPairingRequest(
      app: app, appLabel: appLabel, scopes: scopes, appVersion: "\(version) (\(build))", platform: .current)
  }

  /// The body of `POST /pair/start`: the fields agreed with the keyring (#144).
  func body(device: CockpitDevice) -> [String: Any] {
    [
      "app": app, "app_label": appLabel, "device_id": device.deviceID, "device": device.label,
      "platform": platform.rawValue, "scopes": scopes, "app_version": appVersion,
    ]
  }
}

/// A started request: the code Igor matches on the card, and the handle only this app holds.
public struct CockpitPairingStart: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public let code: String
  public let handle: String
  /// When the request lapses unanswered (5 minutes after the start).
  public let expiresAt: Date
  /// How often to poll, in seconds.
  public let pollEvery: TimeInterval

  public var description: String { "CockpitPairingStart(code \(code), handle redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: ["code": code, "expiresAt": expiresAt], displayStyle: .struct)
  }
}

/// This app's key: what it sends to the services in `services` until the Cockpit stops taking it.
public struct CockpitKey: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public let keyID: String
  public let key: String
  public let scopes: [String]
  /// The idle expiry at pairing: it moves later with every use, so it can't say on its own that the key lapsed.
  public let expiresAt: Date
  /// The latest the key can live (90 days from pairing), whatever its use.
  public let hardExpiresAt: Date
  /// Each service's base URL by name, as `ledger`.
  public let services: [String: URL]

  public init(
    keyID: String, key: String, scopes: [String], expiresAt: Date, hardExpiresAt: Date, services: [String: URL]
  ) {
    self.keyID = keyID
    self.key = key
    self.scopes = scopes
    self.expiresAt = expiresAt
    self.hardExpiresAt = hardExpiresAt
    self.services = services
  }

  enum CodingKeys: String, CodingKey {
    case keyID = "key_id"
    case key, scopes, services
    case expiresAt = "expires_at"
    case hardExpiresAt = "hard_expires_at"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    keyID = try values.decode(String.self, forKey: .keyID)
    key = try values.decode(String.self, forKey: .key)
    scopes = try values.decodeIfPresent([String].self, forKey: .scopes) ?? []
    services = try values.decodeIfPresent([String: URL].self, forKey: .services) ?? [:]
    expiresAt = try Self.date(values, .expiresAt)
    hardExpiresAt = try values.contains(.hardExpiresAt) ? Self.date(values, .hardExpiresAt) : expiresAt
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(keyID, forKey: .keyID)
    try values.encode(key, forKey: .key)
    try values.encode(scopes, forKey: .scopes)
    try values.encode(services, forKey: .services)
    try values.encode(expiresAt.ISO8601Format(Self.withFractions), forKey: .expiresAt)
    try values.encode(hardExpiresAt.ISO8601Format(Self.withFractions), forKey: .hardExpiresAt)
  }

  private static let withFractions = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  static func date(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
    guard let date = PairedDevice.date(try values.decode(String.self, forKey: key)) else {
      throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "not ISO 8601")
    }
    return date
  }

  public var description: String { "CockpitKey(\(keyID), \(scopes), until \(hardExpiresAt.ISO8601Format()))" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self, children: ["keyID": keyID, "scopes": scopes, "hardExpiresAt": hardExpiresAt, "services": services],
      displayStyle: .struct)
  }
}

/// Why pairing failed, with the words an app shows.
public enum CockpitPairingError: Error, Equatable, Sendable {
  /// Igor answered Deny (or closed the card).
  case denied
  /// Nobody answered within the request's 5 minutes.
  case expired
  /// The Cockpit holds no such request: it restarted, or the request was superseded.
  case unknown
  case tooMany
  /// The Cockpit could not file the approve card.
  case inboxDown
  /// The Cockpit refused the request itself, with its reason (an unknown scope, a missing field).
  case badRequest(String)
  case unreachable
  case malformed
  case refused(Int)
  /// No address given and none shared by another app.
  case noCockpit
  /// The Cockpit's address is not https: the poll handle and the key would cross the network in the clear.
  case notHTTPS
  /// The Keychain would not keep the key or the identity: the call and its status.
  case notSaved(String)

  public var message: String {
    switch self {
    case .denied: return "The pairing was denied on the Cockpit. Tap Pair to ask again."
    case .expired: return "Nobody approved the pairing within 5 minutes. Tap Pair to ask again."
    case .unknown: return "The Cockpit no longer has this pairing request. Tap Pair to ask again."
    case .tooMany: return "Too many pairing requests are open. Answer them or wait a few minutes, then try again."
    case .inboxDown: return "The Cockpit could not put the approve card in your Inbox. Try again in a minute."
    case .badRequest(let detail): return "The Cockpit refused the pairing request: \(detail)"
    case .unreachable: return "Could not reach the Cockpit. Check that Tailscale is on, then try again."
    case .malformed: return "The Cockpit's answer made no sense. Try pairing again."
    case .refused(let status): return "The Cockpit answered \(status). Try pairing again."
    case .noCockpit:
      return "This app doesn't know the Cockpit's address yet. Pair another of your apps first, or enter it."
    case .notHTTPS: return "The Cockpit's address must start with https://. Check it, then try again."
    case .notSaved(let detail):
      return "The Cockpit approved, but this device couldn't keep the key (\(detail)). Pair again."
    }
  }

  /// A short name for the error, as the copied problem carries it.
  public var name: String {
    switch self {
    case .denied: return "denied"
    case .expired: return "expired"
    case .unknown: return "unknown"
    case .tooMany: return "too_many"
    case .inboxDown: return "inbox_down"
    case .badRequest: return "bad_request"
    case .unreachable: return "unreachable"
    case .malformed: return "malformed"
    case .refused: return "refused"
    case .noCockpit: return "no_cockpit"
    case .notHTTPS: return "not_https"
    case .notSaved: return "not_saved"
    }
  }

  /// The error as a copyable problem for `BugProblemView`.
  public func problem(context: String, build: String = "unknown", extra: [String: JSONValue] = [:]) -> BugProblem {
    var fields = extra
    fields["error"] = .string(name)
    if case .refused(let status) = self { fields["status"] = .string(String(status)) }
    return BugProblem(message: message, context: context, build: build, extra: fields)
  }
}

/// What one poll found.
public enum CockpitPollResult: Equatable, Sendable {
  case pending
  case approved(CockpitKey)
}

/// The keyring's two calls: `POST <cockpit>/pair/start` and `POST <cockpit>/pair/poll`.
public struct CockpitPairingClient: Sendable {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let transport: Transport

  public init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
    self.transport = transport
  }

  /// Files the approve card at an https `cockpit`. Throws `CockpitPairingError`.
  public func start(
    _ request: CockpitPairingRequest, device: CockpitDevice, at cockpit: URL
  ) async throws
    -> CockpitPairingStart
  {
    let (status, data) = try await post(cockpit, "pair/start", request.body(device: device))
    guard (200..<300).contains(status) else { throw Self.error(status, data) }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let code = json["code"] as? String, let handle = json["handle"] as? String, !handle.isEmpty,
      let stamp = json["expires_at"] as? String, let expires = PairedDevice.date(stamp)
    else { throw CockpitPairingError.malformed }
    let every = (json["poll_every_s"] as? NSNumber)?.doubleValue ?? 2
    return CockpitPairingStart(code: code, handle: handle, expiresAt: expires, pollEvery: max(1, every))
  }

  /// Asks whether Igor has answered. A key comes back once, at the first poll after Approve; a service anywhere
  /// but https on the Cockpit's host is malformed. Throws `CockpitPairingError`.
  public func poll(_ handle: String, at cockpit: URL) async throws -> CockpitPollResult {
    let (status, data) = try await post(cockpit, "pair/poll", ["handle": handle])
    switch status {
    case 202: return .pending
    case 200:
      guard let key = try? JSONDecoder().decode(CockpitKey.self, from: data), !key.key.isEmpty,
        let host = cockpit.host, key.services.values.allSatisfy({ PairingLink.isBox($0, host) })
      else { throw CockpitPairingError.malformed }
      return .approved(key)
    default: throw Self.error(status, data)
    }
  }

  private func post(_ cockpit: URL, _ path: String, _ body: [String: Any]) async throws -> (Int, Data) {
    guard cockpit.scheme?.lowercased() == "https" else { throw CockpitPairingError.notHTTPS }
    var request = URLRequest(url: cockpit.appendingPathComponent(path), timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    do {
      let (data, response) = try await transport(request)
      return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    } catch is URLError {
      throw CockpitPairingError.unreachable
    }
  }

  /// The keyring answers a refusal with `{error, detail}`; the status says which.
  static func error(_ status: Int, _ data: Data) -> CockpitPairingError {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    switch status {
    case 403: return .denied
    case 410: return .expired
    case 404: return .unknown
    case 429: return .tooMany
    case 503: return .inboxDown
    case 400:
      return .badRequest((json?["detail"] as? String) ?? (json?["error"] as? String) ?? "bad request")
    default: return .refused(status)
    }
  }
}

/// What an app shows about its pairing with the Cockpit.
public enum CockpitPairingStatus: Equatable, Sendable {
  case unpaired
  /// A request is open: the code to match on the card.
  case waiting(code: String)
  case paired(until: Date)
  /// A service refused the key (idle for 7 days, revoked, or past 90 days), or the 90 days have passed.
  case lapsed

  /// Nothing should be sent with the key until the app pairs again.
  public var needsPairing: Bool {
    switch self {
    case .unpaired, .lapsed: return true
    case .waiting, .paired: return false
    }
  }

  public var message: String {
    switch self {
    case .unpaired: return "Not paired with the Cockpit."
    case .waiting(let code): return "Waiting for you to approve on the Cockpit… code \(code)"
    case .paired: return "Paired"
    case .lapsed: return "Your Cockpit pairing expired, approve again?"
    }
  }
}

/// One app's pairing: the shared identity, this app's key, and the flow between them.
@MainActor
public final class CockpitPairing {
  public let request: CockpitPairingRequest
  private let devices: CockpitDeviceStore
  private let keys: CockpitKeyStore
  private let client: CockpitPairingClient
  private let defaultLabel: () -> String
  private let now: () -> Date
  private let sleep: (TimeInterval) async throws -> Void
  private var refused = false
  private var askedAgain = false

  /// `devices` is the store in the shared access group, `keys` the one in this app's own group. `defaultLabel`
  /// names the device when this app is the first to pair; `now` and `sleep` are for tests.
  public init(
    request: CockpitPairingRequest, devices: CockpitDeviceStore, keys: CockpitKeyStore,
    client: CockpitPairingClient = CockpitPairingClient(),
    defaultLabel: @escaping () -> String = CockpitDevice.defaultModel,
    now: @escaping () -> Date = Date.init,
    sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
  ) {
    self.request = request
    self.devices = devices
    self.keys = keys
    self.client = client
    self.defaultLabel = defaultLabel
    self.now = now
    self.sleep = sleep
  }

  /// This app's key, if it has one. Send it only while `status()` doesn't need pairing.
  public var key: CockpitKey? { keys.load(app: request.app) }

  /// Asks the Cockpit at `cockpit` (or the address another app shared) for this app's key. `onWaiting` gets the
  /// code to show while Igor approves the card. Returns once the key is kept; throws `CockpitPairingError`, and
  /// `CancellationError` when the task is cancelled.
  public func pair(cockpit: URL?, onWaiting: (String) -> Void) async throws -> CockpitKey {
    let device: CockpitDevice
    do {
      device = try devices.identity(defaultLabel: defaultLabel)
    } catch {
      throw CockpitPairingError.notSaved("\(error)")
    }
    guard let cockpit = cockpit ?? device.cockpit else { throw CockpitPairingError.noCockpit }
    let start = try await client.start(request, device: device, at: cockpit)
    onWaiting(start.code)
    while true {
      try await sleep(start.pollEvery)
      if now() >= start.expiresAt { throw CockpitPairingError.expired }
      let result: CockpitPollResult
      do {
        result = try await client.poll(start.handle, at: cockpit)
      } catch CockpitPairingError.unreachable {
        continue  // a blip off the tailnet; the request lives on until it lapses
      }
      guard case .approved(let key) = result else { continue }
      // The keyring hands the key over once: keep it before saying "Paired".
      do {
        try keys.save(key, app: request.app)
      } catch {
        throw CockpitPairingError.notSaved("\(error)")
      }
      try? devices.remember(cockpit: cockpit)
      refused = false
      askedAgain = false
      return key
    }
  }

  /// What the app shows. `waiting` is the app's own state while `pair` runs.
  public func status(now: Date? = nil) -> CockpitPairingStatus {
    guard let key else { return .unpaired }
    if refused || (now ?? self.now()) >= key.hardExpiresAt { return .lapsed }
    return .paired(until: key.hardExpiresAt)
  }

  /// A service answered 401 for this app's key. Returns true the first time since the last key, when the app should
  /// start asking again on its own; false after that, so a lapse files one card, not one per failed request.
  @discardableResult
  public func keyRefused() -> Bool {
    refused = true
    if askedAgain { return false }
    askedAgain = true
    return true
  }

  /// Forgets this app's key only; the shared identity stays for the other apps.
  public func forget() {
    keys.remove(app: request.app)
    refused = false
    askedAgain = false
  }
}
