// Stories 040 and 041: pairing a device from the link Larry sends. The box's hand-off page opens
// `<scheme>://pair?code=…&host=…` in one of the apps; the app redeems the code with `PairingClient` and keeps the
// `PairedDevice` in a `PairedDeviceStore`, one Keychain item every app on the device shares. The key then opens
// every service on the box until it expires; `PairingStatus` says what the app shows meanwhile. The contract with
// the box is in the pairing design, §7. Neither the code nor the key is ever logged or printed.

import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// `<scheme>://pair?code=<code>&host=<https host, url-encoded>`, as the box's page opens it.
public struct PairingLink: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let code: String
  public let host: URL

  /// `box` is the box's host name the app trusts, as `box.tail1234.ts.net`. Nil for any link that is not a pairing,
  /// or one whose host is not https on `box`: any page can open the link, and the redeem sends the device there.
  public init?(_ url: URL, box: String) {
    guard url.host == "pair",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
      let host = items.first(where: { $0.name == "host" })?.value.flatMap(URL.init(string:)),
      Self.isBox(host, box)
    else { return nil }
    self.code = code
    self.host = host
  }

  /// The link as it may be logged: a `code` replaced by `redacted`, anything else as it was.
  public static func redacted(_ url: URL) -> String {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let items = parts.queryItems,
      items.contains(where: { $0.name == "code" })
    else { return url.absoluteString }
    parts.queryItems = items.map {
      $0.name == "code" ? URLQueryItem(name: "code", value: "redacted") : $0
    }
    return parts.string ?? "redacted"
  }

  /// https on the host `box` names, any port.
  static func isBox(_ url: URL, _ box: String) -> Bool {
    url.scheme == "https" && url.host?.lowercased() == box.lowercased()
  }

  public var description: String { "PairingLink(\(host.absoluteString), code redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["host": host], displayStyle: .struct) }
}

/// This device as the box paired it: its key opens every service in `services` until `expiresAt`.
public struct PairedDevice: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible,
  CustomReflectable
{
  public let deviceID: String
  public let key: String
  /// The name Larry gave it, as "Igor's iPhone".
  public let name: String
  public let expiresAt: Date
  /// Each service's base URL by name, as `ledger`.
  public let services: [String: URL]

  public init(deviceID: String, key: String, name: String, expiresAt: Date, services: [String: URL])
  {
    self.deviceID = deviceID
    self.key = key
    self.name = name
    self.expiresAt = expiresAt
    self.services = services
  }

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case key = "device_key"
    case name
    case expiresAt = "expires_at"
    case services
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try values.decode(String.self, forKey: .deviceID)
    key = try values.decode(String.self, forKey: .key)
    name = try values.decode(String.self, forKey: .name)
    services = try values.decodeIfPresent([String: URL].self, forKey: .services) ?? [:]
    let stamp = try values.decode(String.self, forKey: .expiresAt)
    guard let date = Self.date(stamp) else {
      throw DecodingError.dataCorruptedError(
        forKey: .expiresAt, in: values, debugDescription: "not ISO 8601")
    }
    expiresAt = date
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(deviceID, forKey: .deviceID)
    try values.encode(key, forKey: .key)
    try values.encode(name, forKey: .name)
    try values.encode(services, forKey: .services)
    try values.encode(expiresAt.ISO8601Format(Self.withFractions), forKey: .expiresAt)
  }

  private static let withFractions = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// ISO 8601 with an offset, with or without fractions of a second (Python's `isoformat` gives six digits).
  static func date(_ stamp: String) -> Date? {
    if let date = try? Date(stamp, strategy: withFractions) { return date }
    return try? Date(stamp, strategy: .iso8601)
  }

  public var description: String {
    "PairedDevice(\(name), \(deviceID), until \(expiresAt.ISO8601Format()))"
  }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self, children: ["deviceID": deviceID, "name": name, "expiresAt": expiresAt],
      displayStyle: .struct)
  }
}

/// Why a redeem failed, with the words an app shows.
public enum PairingError: Error, Equatable, Sendable {
  case expired, used, unknown, tooMany, unreachable, malformed
  /// Any other answer from the box.
  case refused(Int)

  public var message: String {
    switch self {
    case .expired: return "That link has expired. Ask Larry to pair again."
    case .used: return "That link was already used. Ask Larry to pair again."
    case .unknown: return "The box does not know that link. Ask Larry to pair again."
    case .tooMany: return "Too many tries. Wait a minute and tap the link again."
    case .unreachable:
      return "Could not reach the box. Check that Tailscale is on, then tap the link again."
    case .malformed: return "The box's answer made no sense. Ask Larry to pair again."
    case .refused(let status): return "The box answered \(status). Ask Larry to pair again."
    }
  }
}

/// Redeems a pairing code with the box (`POST <host>/pair/redeem`).
public struct PairingClient: Sendable {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let transport: Transport

  public init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
    self.transport = transport
  }

  /// `device` describes it for the box's list (model, os, app, build); `replacing` is the device this one was
  /// paired as before, whose key the box then revokes. A service anywhere but https on the link's host is malformed.
  /// Throws `PairingError`.
  public func redeem(_ link: PairingLink, device: [String: String], replacing: String?) async throws
    -> PairedDevice
  {
    var request = URLRequest(
      url: link.host.appendingPathComponent("pair/redeem"), timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["code": link.code, "device": device]
    body["replaces"] = replacing
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(request)
    } catch is URLError {
      throw PairingError.unreachable
    }
    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
    case 200..<300:
      guard let paired = try? JSONDecoder().decode(PairedDevice.self, from: data),
        let box = link.host.host,
        paired.services.values.allSatisfy({ PairingLink.isBox($0, box) })
      else { throw PairingError.malformed }
      return paired
    case 410: throw PairingError.expired
    case 409: throw PairingError.used
    case 404: throw PairingError.unknown
    case 429: throw PairingError.tooMany
    case let status: throw PairingError.refused(status)
    }
  }
}

/// What an app shows about this device's pairing.
public enum PairingStatus: Equatable, Sendable {
  case unpaired
  case paired(name: String, until: Date)
  /// Within 3 days of the expiry; `days` rounded up.
  case expiring(name: String, days: Int)
  case expired(name: String)
  /// A service answered 401 for the key (expired, revoked or unknown on the box).
  case refused(name: String)

  public init(device: PairedDevice?, refused: Bool, now: Date = Date()) {
    guard let device else {
      self = .unpaired
      return
    }
    let left = device.expiresAt.timeIntervalSince(now)
    // An expired key is also refused by the box; "expired" says why.
    if left <= 0 {
      self = .expired(name: device.name)
    } else if refused {
      self = .refused(name: device.name)
    } else if left <= 3 * 86_400 {
      self = .expiring(name: device.name, days: Int((left / 86_400).rounded(.up)))
    } else {
      self = .paired(name: device.name, until: device.expiresAt)
    }
  }

  /// Nothing should be sent with the key: the app asks Larry to pair again.
  public var needsPairing: Bool {
    switch self {
    case .unpaired, .expired, .refused: return true
    case .paired, .expiring: return false
    }
  }

  public func message(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    switch self {
    case .unpaired: return "Not paired. Ask Larry to pair this device."
    case .paired(let name, let until):
      let day = until.formatted(
        Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day())
      return "Paired as \(name) until \(day)"
    case .expiring(let name, let days):
      return
        "\(name)'s key expires in \(days) \(days == 1 ? "day" : "days"). Larry will send a new link."
    case .expired(let name): return "\(name)'s key has expired. Ask Larry to pair again."
    case .refused(let name): return "The box refused \(name)'s key. Ask Larry to pair again."
    }
  }
}
