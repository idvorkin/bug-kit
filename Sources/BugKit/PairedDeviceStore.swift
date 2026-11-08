// Story 040: where the paired device is kept. One Keychain item, this device only, in an access group every app of
// Igor's team names in its `keychain-access-groups` entitlement, so pairing in one app pairs them all, and Unpair in
// one unpairs them all.

import Foundation
#if canImport(Security)
  import Security
#endif

public protocol PairedDeviceStore: AnyObject {
  func load() -> PairedDevice?
  func save(_ device: PairedDevice) throws
  func remove()
}

#if canImport(Security)
/// The Keychain refused the paired device: the call and its status.
public struct PairedDeviceStoreFailed: Error, CustomStringConvertible {
  public let call: String
  public let status: OSStatus
  public var description: String { "\(call) \(status)" }
}

public final class KeychainPairedDeviceStore: PairedDeviceStore {
  private let query: [String: Any]

  /// `accessGroup` is the shared group with the team prefix, as `ABCDE12345.com.idvorkin.paired-device`; nil keeps
  /// the item in the app's own group (a simulator build without the entitlement).
  public init(accessGroup: String?) {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.idvorkin.paired-device",
      kSecAttrAccount as String: "device",
      // On a Mac, the iOS-style Keychain, where access groups and "this device only" apply.
      kSecUseDataProtectionKeychain as String: true,
    ]
    query[kSecAttrAccessGroup as String] = accessGroup
    self.query = query
  }

  public func load() -> PairedDevice? {
    var item: CFTypeRef?
    var lookup = query
    lookup[kSecReturnData as String] = true
    guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else {
      return nil
    }
    return try? JSONDecoder().decode(PairedDevice.self, from: data)
  }

  /// Updates the item in place, so a refused save leaves the device paired as it was.
  public func save(_ device: PairedDevice) throws {
    let values: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(device),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else {
      throw PairedDeviceStoreFailed(call: "SecItemUpdate", status: updated)
    }
    let added = SecItemAdd(query.merging(values) { $1 } as CFDictionary, nil)
    if added != errSecSuccess { throw PairedDeviceStoreFailed(call: "SecItemAdd", status: added) }
  }

  public func remove() { SecItemDelete(query as CFDictionary) }
}
#endif

/// Keeps the device in memory: for tests, and for previews.
public final class MemoryPairedDeviceStore: PairedDeviceStore {
  private var device: PairedDevice?
  public init(_ device: PairedDevice? = nil) { self.device = device }
  public func load() -> PairedDevice? { device }
  public func save(_ device: PairedDevice) throws { self.device = device }
  public func remove() { device = nil }
}
