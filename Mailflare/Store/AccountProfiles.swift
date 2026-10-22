import Foundation
import MailflareCore
import Observation

/// What the Accounts settings page shows and edits per account: display name, signature.
///
/// The server's values are read over JMAP (`Identity/get`) and written with `Identity/set`. A server
/// that refuses the write (Mailflare's identities are read-only today) keeps the value on this Mac
/// instead, and the page says so. Local values win over the server's, and clearing one restores it.
@MainActor
@Observable
final class AccountProfiles {
	static let defaultSignature = "Sent from Mailflare Desktop"

	private struct Entry: Codable {
		var name: String?
		var signature: String?
	}

	/// What the server reported for an account.
	struct Remote: Equatable {
		var name = ""
		var signature = ""
		/// Whether the server accepted an edit last time (nil until one was tried).
		var editable: Bool?
		var identityID: String?
	}

	private var entries: [String: Entry]
	private(set) var remote: [String: Remote] = [:]
	@ObservationIgnored private var fetched: Set<String> = []

	private static let defaultsKey = "accountProfiles"

	init() {
		if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
		   let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved } else { entries = [:] }
	}

	// MARK: Reading

	/// The name set on this Mac, if any.
	func localName(_ accountID: String) -> String? { entries[accountID]?.name }

	/// The signature in effect: set here, else the server's, else the default.
	func signature(_ accountID: String) -> String {
		if let own = entries[accountID]?.signature, !own.isEmpty { return own }
		if let theirs = remote[accountID]?.signature.trimmingCharacters(in: .whitespacesAndNewlines), !theirs.isEmpty { return theirs }
		return Self.defaultSignature
	}

	/// Whether a signature was set, here or on the server (otherwise the default applies).
	func hasSignature(_ accountID: String) -> Bool { signature(accountID) != Self.defaultSignature }

	/// The signature as a composer block: a gap, then the lines.
	func signatureHTML(_ accountID: String) -> String {
		let lines = signature(accountID).components(separatedBy: .newlines).map { Self.escape($0) }.joined(separator: "<br>")
		return "<div><br></div><div class=\"mailflare-signature\">-- <br>\(lines)</div>"
	}

	private static func escape(_ text: String) -> String {
		text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
	}

	// MARK: Server

	/// Reads the name and signature from the server, once per launch unless `force`.
	func refresh(_ account: Account, force: Bool = false) async {
		guard force || fetched.insert(account.id).inserted else { return }
		guard let found = await Self.fetchIdentity(account) else { return }
		var current = remote[account.id] ?? Remote()
		current.name = found.name; current.signature = found.signature; current.identityID = found.id
		remote[account.id] = current
	}

	/// Saves a name and signature. Returns a note to show when the server did not take them.
	@discardableResult
	func save(_ account: Account, name: String, signature: String) async -> String? {
		let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
		let signature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
		let serverName = remote[account.id]?.name ?? ""
		let serverSignature = remote[account.id]?.signature ?? ""
		let wantedSignature = signature == Self.defaultSignature ? "" : signature

		var note: String?
		if let id = remote[account.id]?.identityID, name != serverName || wantedSignature != serverSignature {
			let accepted = await Self.updateIdentity(account, id: id, name: name, signature: wantedSignature)
			remote[account.id]?.editable = accepted
			if accepted {
				remote[account.id]?.name = name; remote[account.id]?.signature = wantedSignature
			} else {
				note = "Your server doesn't allow changes here, so they are kept on this Mac."
			}
		}
		let accepted = remote[account.id]?.editable == true
		var entry = entries[account.id] ?? Entry()
		entry.name = accepted || name.isEmpty || name == serverName ? nil : name
		entry.signature = accepted || wantedSignature.isEmpty || wantedSignature == serverSignature ? nil : wantedSignature
		entries[account.id] = entry.name == nil && entry.signature == nil ? nil : entry
		persist()
		return note
	}

	func forget(_ accountID: String) {
		entries[accountID] = nil
		remote[accountID] = nil
		persist()
	}

	private func persist() {
		if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
	}

	// MARK: JMAP

	private struct Session {
		var api: URL
		var accountID: String
		var secret: String
	}

	private nonisolated static func session(for account: Account) async -> Session? {
		var parts = URLComponents(string: account.serverUrl.contains("://") ? account.serverUrl : "https://\(account.serverUrl)")
		guard let host = parts?.host, !host.isEmpty, ["http", "https"].contains(parts?.scheme ?? ""),
			  let secret = KeychainCredentialStore().load(accountId: account.id) else { return nil }
		parts?.path = "/.well-known/jmap"; parts?.query = nil; parts?.fragment = nil
		guard let url = parts?.url else { return nil }
		var request = URLRequest(url: url)
		request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
		request.timeoutInterval = 15
		guard let (data, response) = try? await URLSession.shared.data(for: request),
			  (response as? HTTPURLResponse)?.statusCode == 200,
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let api = (json["apiUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
		let primary = json["primaryAccounts"] as? [String: String]
		guard let accountID = primary?["urn:ietf:params:jmap:mail"] ?? (json["accounts"] as? [String: Any])?.keys.first else { return nil }
		return Session(api: api, accountID: accountID, secret: secret)
	}

	private nonisolated static func call(_ session: Session, _ method: String, _ args: [String: Any]) async -> [String: Any]? {
		var request = URLRequest(url: session.api)
		request.httpMethod = "POST"
		request.timeoutInterval = 15
		request.setValue("Bearer \(session.secret)", forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		var arguments = args
		arguments["accountId"] = session.accountID
		let body: [String: Any] = [
			"using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission"],
			"methodCalls": [[method, arguments, "0"]],
		]
		request.httpBody = try? JSONSerialization.data(withJSONObject: body)
		guard let (data, response) = try? await URLSession.shared.data(for: request),
			  (response as? HTTPURLResponse)?.statusCode == 200,
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let first = (json["methodResponses"] as? [[Any]])?.first, first.count > 1, first[0] as? String == method else { return nil }
		return first[1] as? [String: Any]
	}

	/// The identity for the account's own address (else the first), with its name and text signature.
	private nonisolated static func fetchIdentity(_ account: Account) async -> (id: String, name: String, signature: String)? {
		guard let session = await session(for: account),
			  let result = await call(session, "Identity/get", ["ids": NSNull()]),
			  let list = result["list"] as? [[String: Any]], !list.isEmpty else { return nil }
		let pick = list.first { ($0["email"] as? String)?.lowercased() == account.email.lowercased() } ?? list[0]
		guard let id = pick["id"] as? String else { return nil }
		return (id, pick["name"] as? String ?? "", pick["textSignature"] as? String ?? "")
	}

	/// Whether the server applied the change.
	private nonisolated static func updateIdentity(_ account: Account, id: String, name: String, signature: String) async -> Bool {
		guard let session = await session(for: account),
			  let result = await call(session, "Identity/set", ["update": [id: ["name": name, "textSignature": signature]]]) else { return false }
		return (result["updated"] as? [String: Any])?[id] != nil
	}
}
