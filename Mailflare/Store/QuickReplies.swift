import AppKit

/// Replies being written in the reader's reply box, by message, kept on this Mac until sent or
/// cleared. Typing changes the copy in memory at once; the file is written at most once a second,
/// off the main thread, and once more when the app quits.
@MainActor
final class QuickReplies {
	private var replies: [String: String] = [:]
	private let file: URL?
	private var writeTask: Task<Void, Never>?
	private var quitObserver: NSObjectProtocol?
	private static let interval: Duration = .seconds(1)

	init(file: URL?) {
		self.file = file
		guard let file else { return }
		if let data = try? Data(contentsOf: file) { replies = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:] }
		quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.flush() }
		}
	}

	/// The key of a message: its account and the account's own id for it.
	static func key(account: String, message: String) -> String { account + "\n" + message }

	func reply(for key: String) -> String { replies[key] ?? "" }

	/// Keeps `html` as the reply to a message; an empty reply is dropped.
	func set(_ html: String, for key: String) {
		guard replies[key, default: ""] != html else { return }
		if html.isEmpty { replies[key] = nil } else { replies[key] = html }
		scheduleWrite()
	}

	/// Drops every reply in an account, when it is signed out.
	func forget(account: String) {
		let prefix = account + "\n"
		let before = replies.count
		replies = replies.filter { !$0.key.hasPrefix(prefix) }
		if replies.count != before { scheduleWrite() }
	}

	/// Writes now what a scheduled write would.
	func flush() {
		guard writeTask != nil else { return }
		writeTask?.cancel()
		writeTask = nil
		write(synchronously: true)
	}

	/// Throttled: the first change schedules a write a second later, and changes until then ride along.
	private func scheduleWrite() {
		guard file != nil, writeTask == nil else { return }
		writeTask = Task { [weak self] in
			try? await Task.sleep(for: Self.interval)
			guard let self, !Task.isCancelled else { return }
			self.writeTask = nil
			self.write(synchronously: false)
		}
	}

	private func write(synchronously: Bool) {
		guard let file, let data = try? JSONEncoder().encode(replies) else { return }
		if synchronously {
			try? data.write(to: file, options: .atomic)
		} else {
			Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }
		}
	}
}
