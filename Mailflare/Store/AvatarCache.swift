import AppKit
import CryptoKit
import MailflareCore
import Observation

/// Profile pictures for accounts and inboxes: the Mailflare server's own picture when it has one,
/// Gravatar for other servers. Cached on disk so they show at launch; a 404 keeps the initials.
@MainActor
@Observable
final class AvatarCache {
	private(set) var images: [String: NSImage] = [:]
	@ObservationIgnored private var requested: Set<String> = []
	@ObservationIgnored private let directory: URL

	init(directory: URL) {
		self.directory = directory
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	static func key(account: String, mailbox: String? = nil) -> String { mailbox.map { "\(account)/\($0)" } ?? "account/\(account)" }

	/// Starts loading once per launch for `key`; the cached picture appears immediately.
	func load(key: String, account: Account, mailboxID: String?, email: String) {
		guard requested.insert(key).inserted else { return }
		let file = directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".img")
		if let data = try? Data(contentsOf: file), let image = NSImage(data: data) { images[key] = image }
		Task {
			guard let result = await Self.fetch(account: account, mailboxID: mailboxID, email: email) else { return }
			switch result {
			case .none:
				try? FileManager.default.removeItem(at: file)
				images[key] = nil
			case .some(let data):
				guard let image = NSImage(data: data) else { return }
				try? data.write(to: file, options: .atomic)
				images[key] = image
			}
		}
	}

	func forget(account id: String) {
		images = images.filter { !$0.key.contains(id) }
		requested = requested.filter { !$0.contains(id) }
	}

	/// `.some(data)` is a picture, `.none` means the server has none, nil means try again later.
	private static func fetch(account: Account, mailboxID: String?, email: String) async -> Data??  {
		var web = URLComponents(string: account.serverUrl.contains("://") ? account.serverUrl : "https://\(account.serverUrl)")
		guard let host = web?.host, !host.isEmpty, ["http", "https"].contains(web?.scheme ?? "") else {
			return await gravatar(email)
		}
		guard let secret = KeychainCredentialStore().load(accountId: account.id) else { return nil }
		web?.path = "/api/mobile/avatar"; web?.fragment = nil
		web?.queryItems = mailboxID.map { [URLQueryItem(name: "mailbox", value: $0)] }
		guard let url = web?.url else { return nil }
		var request = URLRequest(url: url)
		request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
		guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return nil }
		if http.statusCode == 404 { return .some(nil) }
		return http.statusCode == 200 ? .some(data) : nil
	}

	private static func gravatar(_ email: String) async -> Data?? {
		let normalized = email.trimmingCharacters(in: .whitespaces).lowercased()
		guard !normalized.isEmpty else { return nil }
		let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
		guard let url = URL(string: "https://gravatar.com/avatar/\(hash)?s=256&d=404"),
			  let (data, response) = try? await URLSession.shared.data(from: url), let http = response as? HTTPURLResponse else { return nil }
		if http.statusCode == 404 { return .some(nil) }
		return http.statusCode == 200 ? .some(data) : nil
	}
}
