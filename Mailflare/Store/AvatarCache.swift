import AppKit
import CryptoKit
import SwiftUI
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
		// A picture chosen on this Mac is never replaced by the server's.
		if let image = NSImage(contentsOf: localFile(key)) { images[key] = image; return }
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

	private func localFile(_ key: String) -> URL {
		directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".local")
	}

	func hasLocal(_ key: String) -> Bool { FileManager.default.fileExists(atPath: localFile(key).path) }

	/// Uses a picture chosen on this Mac, shrunk to 256 px.
	func setLocal(key: String, from source: URL) -> Bool {
		guard let original = NSImage(contentsOf: source), original.size.width > 0, original.size.height > 0 else { return false }
		let side: CGFloat = 256, scale = max(side / original.size.width, side / original.size.height)
		let size = NSSize(width: original.size.width * scale, height: original.size.height * scale)
		let shrunk = NSImage(size: NSSize(width: side, height: side))
		shrunk.lockFocus()
		original.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
		shrunk.unlockFocus()
		guard let tiff = shrunk.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
			  (try? png.write(to: localFile(key), options: .atomic)) != nil else { return false }
		images[key] = shrunk
		return true
	}

	/// Drops the chosen picture; the server's (or Gravatar's) comes back at the next launch.
	func removeLocal(key: String) {
		try? FileManager.default.removeItem(at: localFile(key))
		images[key] = nil
		requested.remove(key)
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
		// Nothing on the server: the address's Gravatar, then (in the view) a colored initial.
		if http.statusCode == 404 { return await gravatar(email) }
		return http.statusCode == 200 ? .some(data) : nil
	}

	// MARK: Senders

	static func contactKey(_ email: String) -> String { "contact/" + normalize(email) }

	private static func normalize(_ email: String) -> String { email.trimmingCharacters(in: .whitespaces).lowercased() }

	private static func sha256Hex(_ text: String) -> String {
		SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	private static let foundTTL: TimeInterval = 30 * 86400
	private static let missTTL: TimeInterval = 7 * 86400

	/// A sender's Gravatar, once per launch. Both outcomes are remembered on disk: a picture is shown
	/// at once from the file and refreshed after a month, and a miss (a `.miss` marker) is not asked
	/// again for a week, so scrolling a long list does not repeat the lookups.
	func loadContact(email: String) {
		let address = Self.normalize(email)
		guard address.contains("@") else { return }
		let key = Self.contactKey(address)
		guard requested.insert(key).inserted else { return }
		let base = directory.appendingPathComponent("contact_" + Self.sha256Hex(address))
		let file = base.appendingPathExtension("img"), miss = base.appendingPathExtension("miss")
		// A picture chosen on this Mac is never replaced by Gravatar's.
		if let image = NSImage(contentsOf: localFile(key)) { images[key] = image; return }
		Task {
			let cached = await Task.detached(priority: .utility) { Self.readContact(file: file, miss: miss) }.value
			if hasLocal(key) { return }
			if let data = cached.data, let image = NSImage(data: data) { images[key] = image }
			if cached.isFresh { return }
			guard let result = await Self.gravatar(address, size: 96), !hasLocal(key) else { return }
			switch result {
			case .none:
				try? FileManager.default.removeItem(at: file)
				try? Data().write(to: miss, options: .atomic)
				images[key] = nil
			case .some(let data):
				guard let image = NSImage(data: data) else { return }
				try? data.write(to: file, options: .atomic)
				try? FileManager.default.removeItem(at: miss)
				images[key] = image
			}
		}
	}

	private nonisolated static func readContact(file: URL, miss: URL) -> (data: Data?, isFresh: Bool) {
		func age(_ url: URL) -> TimeInterval? {
			guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
			return Date().timeIntervalSince(date)
		}
		if let age = age(file), let data = try? Data(contentsOf: file) { return (data, age < foundTTL) }
		if let age = age(miss) { return (nil, age < missTTL) }
		return (nil, false)
	}

	private static func gravatar(_ email: String, size: Int = 256) async -> Data?? {
		let normalized = normalize(email)
		guard !normalized.isEmpty else { return nil }
		let hash = sha256Hex(normalized)
		guard let url = URL(string: "https://gravatar.com/avatar/\(hash)?s=\(size)&d=404"),
			  let (data, response) = try? await URLSession.shared.data(from: url), let http = response as? HTTPURLResponse else { return nil }
		if http.statusCode == 404 { return .some(nil) }
		return http.statusCode == 200 ? .some(data) : nil
	}
}

/// The look every avatar falls back to when there is no picture: the initial in dark text on one of
/// ten pastel colors picked from a hash of the address or key (the web app's palette and hash).
enum AvatarStyle {
	private static let palette: [UInt32] = [
		0xFFCDD2, 0xF8BBD0, 0xE1BEE7, 0xC5CAE9, 0xBBDEFB, 0xB2DFDB, 0xC8E6C9, 0xFFE0B2, 0xD7CCC8, 0xCFD8DC,
	]

	static let text = Color(red: 0.125, green: 0.129, blue: 0.141)

	static func background(for identity: String) -> Color {
		var hash: Int32 = 0
		for unit in identity.trimmingCharacters(in: .whitespaces).lowercased().utf16 { hash = hash &* 31 &+ Int32(unit) }
		let rgb = palette[Int(UInt32(bitPattern: hash) % UInt32(palette.count))]
		return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
	}
}
