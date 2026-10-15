import Foundation

#if canImport(Security)
import Security
#endif

public protocol CredentialStore: Sendable {
  func read(service: String, account: String) async throws -> String?
  func save(_ value: String, service: String, account: String) async throws
  func delete(service: String, account: String) async throws
}

public enum CredentialStoreError: Error, LocalizedError, Sendable, Equatable {
  case unavailable
  case keychainStatus(Int32)

  public var errorDescription: String? {
    switch self {
    case .unavailable: return "Secure credential storage is unavailable."
    case let .keychainStatus(status): return "Keychain operation failed (status \(status))."
    }
  }
}

public actor InMemoryCredentialStore: CredentialStore {
  private var values: [String: String] = [:]

  public init() {}

  public func read(service: String, account: String) async throws -> String? {
    return values[key(service, account)]
  }

  public func save(_ value: String, service: String, account: String) async throws {
    values[key(service, account)] = value
  }

  public func delete(service: String, account: String) async throws {
    values.removeValue(forKey: key(service, account))
  }

  private func key(_ service: String, _ account: String) -> String { service + "\u{001f}" + account }
}

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
  public let service: String

  public init(service: String = "com.pdfmathreader.credentials") {
    self.service = service
  }

  public func read(service: String = "", account: String) async throws -> String? {
    #if canImport(Security)
    let query = baseQuery(service: service.isEmpty ? self.service : service, account: account)
      .merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
    guard let data = item as? Data else { throw CredentialStoreError.unavailable }
    return String(data: data, encoding: .utf8)
    #else
    throw CredentialStoreError.unavailable
    #endif
  }

  public func save(_ value: String, service: String = "", account: String) async throws {
    #if canImport(Security)
    let resolvedService = service.isEmpty ? self.service : service
    let query = baseQuery(service: resolvedService, account: account)
    let data = Data(value.utf8)
    let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let status = SecItemAdd(item as CFDictionary, nil)
      guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
    } else if updateStatus != errSecSuccess {
      throw CredentialStoreError.keychainStatus(updateStatus)
    }
    #else
    throw CredentialStoreError.unavailable
    #endif
  }

  public func delete(service: String = "", account: String) async throws {
    #if canImport(Security)
    let status = SecItemDelete(baseQuery(service: service.isEmpty ? self.service : service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStoreError.keychainStatus(status)
    }
    #else
    throw CredentialStoreError.unavailable
    #endif
  }

  #if canImport(Security)
  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
  #endif
}
