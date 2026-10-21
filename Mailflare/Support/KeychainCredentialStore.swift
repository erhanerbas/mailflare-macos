import Foundation
import MailflareCore
import Security

/// Account secrets (app passwords or device keys) live in the Keychain, keyed by the core's
/// account id. The core asks for them per request and never writes them to its database.
final class KeychainCredentialStore: CredentialStore {
	private let service = "xyz.hieunguyen.Mailflare.account"

	private func query(_ accountId: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: accountId]
	}

	func load(accountId: String) -> String? {
		var request = query(accountId)
		request[kSecReturnData as String] = true
		request[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	func save(accountId: String, secret: String) -> Bool {
		let data = Data(secret.utf8)
		let status = SecItemUpdate(query(accountId) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if status == errSecSuccess { return true }
		guard status == errSecItemNotFound else { return false }
		var insert = query(accountId)
		insert[kSecValueData as String] = data
		insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
	}

	func delete(accountId: String) {
		SecItemDelete(query(accountId) as CFDictionary)
	}
}
