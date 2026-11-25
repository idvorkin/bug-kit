// Stories 042 and 044: where Cockpit pairing is kept. The device identity is one Keychain item, this device only,
// in the access group every app of Igor's team already names for the paired device (`com.idvorkin.paired-device`),
// so the second app on a device reads what the first one made. Each app's key is an item in that app's own group,
// so no other app can read it and each can be revoked alone.

import Foundation
#if canImport(Security)
  import Security
#endif

/// The shared identity. `insert` must never overwrite: two apps making the identity at once agree on the first.
public protocol CockpitDeviceStore: AnyObject {
  func load() -> CockpitDevice?
  /// Adds `device` if no identity exists. Returns false, changing nothing, when one already does.
  func insert(_ device: CockpitDevice) throws -> Bool
  /// Replaces the stored identity (a new label or the Cockpit's address).
  func replace(_ device: CockpitDevice) throws
}

extension CockpitDeviceStore {
  /// The device's identity, made now with `defaultLabel()` (the hardware model) if this is the first app to ask.
  public func identity(defaultLabel: () -> String) throws -> CockpitDevice {
    if let device = load() { return device }
    let made = CockpitDevice.make(model: defaultLabel())
    if try insert(made) { return made }
    guard let winner = load() else { throw CockpitStoreFailed(call: "identity", status: 0) }
    return winner
  }

  /// Renames the device for every app; the id stays. An empty label keeps the old one.
  @discardableResult
  public func rename(to label: String) throws -> CockpitDevice {
    var device = try identity(defaultLabel: CockpitDevice.defaultModel)
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return device }
    device.label = trimmed
    try replace(device)
    return device
  }

  /// Shares the Cockpit's address with the other apps.
  public func remember(cockpit: URL) throws {
    guard var device = load(), device.cockpit != cockpit else { return }
    device.cockpit = cockpit
    try replace(device)
  }
}

/// One app's key, kept under the app's short name.
public protocol CockpitKeyStore: AnyObject {
  func load(app: String) -> CockpitKey?
  func save(_ key: CockpitKey, app: String) throws
  func remove(app: String)
}

/// The Keychain refused: the call and its status.
public struct CockpitStoreFailed: Error, CustomStringConvertible, Equatable {
  public let call: String
  public let status: Int32
  public var description: String { "\(call) \(status)" }
}

#if canImport(Security)
  /// Builds the base query for one generic-password item, in the data-protection Keychain on a Mac too.
  private func itemQuery(service: String, account: String, accessGroup: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    return query
  }

  private func readItem(_ query: [String: Any]) -> Data? {
    var item: CFTypeRef?
    var lookup = query
    lookup[kSecReturnData as String] = true
    guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  /// The item's data, readable after the first unlock and never restored to another device.
  private func thisDeviceOnly(_ data: Data) -> [String: Any] {
    [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
  }

  public final class KeychainCockpitDeviceStore: CockpitDeviceStore {
    private let query: [String: Any]

    /// `accessGroup` is the shared group with the team prefix, as `<team-id>.com.idvorkin.paired-device` (the
    /// group `KeychainPairedDeviceStore` uses); nil keeps the item in the app's own group (a build without the
    /// entitlement, which then shares nothing).
    public init(accessGroup: String?) {
      query = itemQuery(service: "com.idvorkin.cockpit-device", account: "device", accessGroup: accessGroup)
    }

    public func load() -> CockpitDevice? {
      readItem(query).flatMap { try? JSONDecoder().decode(CockpitDevice.self, from: $0) }
    }

    public func insert(_ device: CockpitDevice) throws -> Bool {
      let values = thisDeviceOnly(try JSONEncoder().encode(device))
      let added = SecItemAdd(query.merging(values) { $1 } as CFDictionary, nil)
      if added == errSecDuplicateItem { return false }
      if added != errSecSuccess { throw CockpitStoreFailed(call: "SecItemAdd", status: added) }
      return true
    }

    public func replace(_ device: CockpitDevice) throws {
      let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(device)]
      let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
      if updated == errSecItemNotFound {
        _ = try insert(device)
      } else if updated != errSecSuccess {
        throw CockpitStoreFailed(call: "SecItemUpdate", status: updated)
      }
    }
  }

  public final class KeychainCockpitKeyStore: CockpitKeyStore {
    private let accessGroup: String?

    /// `accessGroup` is this app's own group; nil (the usual) is the first group in the app's
    /// `keychain-access-groups`, which must be the app's own, never the shared one.
    public init(accessGroup: String? = nil) { self.accessGroup = accessGroup }

    private func query(_ app: String) -> [String: Any] {
      itemQuery(service: "com.idvorkin.cockpit-key", account: app, accessGroup: accessGroup)
    }

    public func load(app: String) -> CockpitKey? {
      readItem(query(app)).flatMap { try? JSONDecoder().decode(CockpitKey.self, from: $0) }
    }

    /// Updates in place, so a refused save leaves the old key as it was.
    public func save(_ key: CockpitKey, app: String) throws {
      let values = thisDeviceOnly(try JSONEncoder().encode(key))
      let updated = SecItemUpdate(query(app) as CFDictionary, values as CFDictionary)
      if updated == errSecSuccess { return }
      guard updated == errSecItemNotFound else { throw CockpitStoreFailed(call: "SecItemUpdate", status: updated) }
      let added = SecItemAdd(query(app).merging(values) { $1 } as CFDictionary, nil)
      if added != errSecSuccess { throw CockpitStoreFailed(call: "SecItemAdd", status: added) }
    }

    public func remove(app: String) { SecItemDelete(query(app) as CFDictionary) }
  }
#endif

/// Keeps the identity in memory: for tests and previews.
public final class MemoryCockpitDeviceStore: CockpitDeviceStore {
  public var stored: CockpitDevice?
  /// Runs once, just before the next insert: a test's stand-in for another app racing this one.
  public var beforeNextInsert: (() -> Void)?

  public init(_ device: CockpitDevice? = nil) { stored = device }
  public func load() -> CockpitDevice? { stored }

  public func insert(_ device: CockpitDevice) throws -> Bool {
    if let race = beforeNextInsert {
      beforeNextInsert = nil
      race()
    }
    guard stored == nil else { return false }
    stored = device
    return true
  }

  public func replace(_ device: CockpitDevice) throws { stored = device }
}

/// Keeps keys in memory: for tests and previews. `refuse` makes every save fail.
public final class MemoryCockpitKeyStore: CockpitKeyStore {
  private var keys: [String: CockpitKey] = [:]
  public var refuse = false

  public init() {}
  public func load(app: String) -> CockpitKey? { keys[app] }

  public func save(_ key: CockpitKey, app: String) throws {
    if refuse { throw CockpitStoreFailed(call: "refused", status: 0) }
    keys[app] = key
  }

  public func remove(app: String) { keys[app] = nil }
}
