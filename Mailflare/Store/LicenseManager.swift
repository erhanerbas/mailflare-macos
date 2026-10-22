import Foundation
import Observation
import Security

/// Mailflare Pro for the app. A Mailflare account whose server holds an active Pro or Team license
/// unlocks the app on its own (the server says so in `/api/branding`); otherwise the user can
/// activate a Pro license key with Paymug. The key sits in the Keychain; the rest of the state is a
/// cache in UserDefaults so a launch without a network stays licensed.
@MainActor
@Observable
final class LicenseManager {
	enum Failure: LocalizedError {
		case unreachable
		case rejected(String)

		var errorDescription: String? {
			switch self {
			case .unreachable: "Could not reach Paymug. Check your connection and try again."
			case .rejected(let message): message
			}
		}
	}

	static let productID = "ebafa58f-af9f-4b8a-a48d-6cfd44dd2053"
	static let baseURL = URL(string: "https://app.paymug.co")!
	static let buyURL = URL(string: "https://app.paymug.co/buy/mailflare-pro")!
	/// Paymug asks for the URL of the installation; a desktop app has none, so all installs share this one
	/// and are told apart by their instance id.
	static let instanceURL = "https://app.paymug.co/mailflare-macos"
	/// How long a key keeps working when Paymug cannot be reached.
	private static let offlineGrace: TimeInterval = 14 * 24 * 60 * 60
	private static let revalidateAfter: TimeInterval = 12 * 60 * 60

	private enum Keys {
		static let instanceID = "license.instanceId"
		static let active = "license.active"
		static let validatedAt = "license.validatedAt"
		static let servers = "license.servers"
		static let brands = "license.brands"
		static let brandOwner = "license.brandOwner"
	}

	/// The license key in use, if one was activated.
	private(set) var licenseKey: String?
	private(set) var keyActive: Bool
	/// Accounts whose server holds an active license. One is enough to activate the app, whichever
	/// account is in view.
	private(set) var licensedAccounts: Set<String>
	var serverLicensed: Bool { !licensedAccounts.isEmpty }
	/// The branding each licensed account's server sets. The app wears one of them whichever account
	/// or service is in view, until every licensed account has signed out.
	private var brands: [String: String]
	private var brandOwner: String?

	/// The app name from the licensed server, nil when no server license is active.
	var brandName: String? {
		if let owner = brandOwner, licensedAccounts.contains(owner), let name = brands[owner] { return name }
		return licensedAccounts.sorted().lazy.compactMap { self.brands[$0] }.first
	}
	private(set) var busy = false
	var message: String?

	var isPro: Bool { serverLicensed || keyActive }

	private let keychain = LicenseKeychain()

	init() {
		let defaults = UserDefaults.standard
		licensedAccounts = Set(defaults.stringArray(forKey: Keys.servers) ?? [])
		brands = defaults.dictionary(forKey: Keys.brands) as? [String: String] ?? [:]
		brandOwner = defaults.string(forKey: Keys.brandOwner)
		let key = LicenseKeychain().load()
		licenseKey = key
		let validated = defaults.object(forKey: Keys.validatedAt) as? Date
		// A cached "active" only holds for the grace period since Paymug last confirmed it.
		keyActive = key != nil
			&& defaults.bool(forKey: Keys.active)
			&& (validated.map { Date().timeIntervalSince($0) < Self.offlineGrace } ?? false)
	}

	/// The key with all but its last four characters hidden.
	var maskedKey: String? {
		guard let key = licenseKey else { return nil }
		return key.count <= 4 ? key : String(repeating: "•", count: min(key.count - 4, 12)) + key.suffix(4)
	}

	// MARK: Server license

	/// Records whether an account's server has an active license, and the app name it brands with.
	/// Remembered across launches so an offline start still knows.
	func setServerLicensed(_ licensed: Bool, accountID: String, brandName: String? = nil) {
		if licensed {
			licensedAccounts.insert(accountID)
			if let brandName, !brandName.isEmpty { brands[accountID] = brandName }
			if brandOwner == nil || !licensedAccounts.contains(brandOwner!) { brandOwner = accountID }
		} else {
			licensedAccounts.remove(accountID)
			brands[accountID] = nil
			if brandOwner == accountID { brandOwner = licensedAccounts.sorted().first }
		}
		persist()
	}

	/// Drops accounts that are no longer signed in. The app deactivates once none is left licensed.
	func retain(accountIDs: [String]) {
		let kept = licensedAccounts.intersection(accountIDs)
		guard kept != licensedAccounts else { return }
		licensedAccounts = kept
		brands = brands.filter { kept.contains($0.key) }
		if let owner = brandOwner, !kept.contains(owner) { brandOwner = kept.sorted().first }
		persist()
	}

	private func persist() {
		let defaults = UserDefaults.standard
		defaults.set(Array(licensedAccounts), forKey: Keys.servers)
		defaults.set(brands, forKey: Keys.brands)
		defaults.set(brandOwner, forKey: Keys.brandOwner)
	}

	// MARK: Key

	func activate(key rawKey: String) async {
		let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !key.isEmpty, !busy else { return }
		busy = true; message = nil
		defer { busy = false }
		do {
			let response = try await call("activate", key: key)
			guard response.valid, response.state == "active" else { throw Failure.rejected(response.reason) }
			guard keychain.save(key) else { throw Failure.rejected("The license key could not be saved to the Keychain.") }
			licenseKey = key
			record(active: true)
		} catch {
			message = error.localizedDescription
		}
	}

	/// Frees this Mac's seat and forgets the key.
	func deactivate() async {
		guard licenseKey != nil, !busy else { return }
		busy = true; message = nil
		defer { busy = false }
		do {
			let response = try await call("deactivate", key: nil)
			// An installation Paymug no longer knows is as good as deactivated.
			guard response.state == "deactivated" || !response.valid else { throw Failure.rejected("Paymug did not confirm the deactivation.") }
			keychain.delete()
			licenseKey = nil
			record(active: false)
		} catch {
			message = error.localizedDescription
		}
	}

	/// Asks Paymug whether the activation still stands, at most twice a day. Without a network the
	/// cached answer holds until the grace period ends.
	func revalidate(force: Bool = false) async {
		guard let key = licenseKey, !busy else { return }
		let validated = UserDefaults.standard.object(forKey: Keys.validatedAt) as? Date
		if !force, keyActive, let validated, Date().timeIntervalSince(validated) < Self.revalidateAfter { return }
		do {
			let response = try await call("validate", key: key)
			if response.valid, response.state == "active" {
				record(active: true)
			} else {
				record(active: false)
				message = response.reason
			}
		} catch Failure.unreachable {
			if let validated, Date().timeIntervalSince(validated) >= Self.offlineGrace { keyActive = false }
		} catch {
			message = error.localizedDescription
		}
	}

	private func record(active: Bool) {
		let defaults = UserDefaults.standard
		defaults.set(active, forKey: Keys.active)
		defaults.set(Date(), forKey: Keys.validatedAt)
		keyActive = active
	}

	// MARK: Paymug

	private struct Response: Decodable {
		var valid = false
		var state = "invalid"
		var instanceId: String?
		var error: String?

		var reason: String {
			if let error, !error.isEmpty { return error }
			return state == "expired" ? "This license has expired." : "This license key is not valid."
		}

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			valid = (try? c.decode(Bool.self, forKey: .valid)) ?? false
			state = (try? c.decode(String.self, forKey: .state)) ?? "invalid"
			instanceId = try? c.decode(String.self, forKey: .instanceId)
			error = try? c.decode(String.self, forKey: .error)
		}

		private enum CodingKeys: String, CodingKey { case valid, state, instanceId, error }
	}

	/// A stable id for this installation, created once.
	private var instanceID: String {
		let defaults = UserDefaults.standard
		if let id = defaults.string(forKey: Keys.instanceID) { return id }
		let id = UUID().uuidString.lowercased()
		defaults.set(id, forKey: Keys.instanceID)
		return id
	}

	private func call(_ action: String, key: String?) async throws -> Response {
		var body: [String: String] = ["productId": Self.productID, "instanceId": instanceID]
		if action != "deactivate" {
			body["licenseKey"] = key ?? ""
			body["instanceUrl"] = Self.instanceURL
			body["appVersion"] = MailStore.appVersion
		}
		var request = URLRequest(url: Self.baseURL.appending(path: "api/v1/licenses/\(action)"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.timeoutInterval = 15
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		let data: Data, response: URLResponse
		do { (data, response) = try await URLSession.shared.data(for: request) }
		catch { throw Failure.unreachable }
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		if status >= 500 || status == 429 { throw Failure.unreachable }
		// Paymug answers a rejected key with 409 and a JSON body that says why, so decode any status.
		guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
			throw Failure.rejected("Paymug returned an unexpected response.")
		}
		return decoded
	}
}

/// The license key, kept in the Keychain apart from account secrets.
private struct LicenseKeychain {
	private let service = "xyz.hieunguyen.Mailflare.license"
	private let account = "pro"

	private var query: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
	}

	func load() -> String? {
		var request = query
		request[kSecReturnData as String] = true
		request[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}

	func save(_ key: String) -> Bool {
		let data = Data(key.utf8)
		let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if status == errSecSuccess { return true }
		guard status == errSecItemNotFound else { return false }
		var insert = query
		insert[kSecValueData as String] = data
		insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
	}

	func delete() { SecItemDelete(query as CFDictionary) }
}
