import Foundation

/// A named set of inboxes from one or more accounts, listed together as one inbox.
struct InboxView: Identifiable, Codable, Hashable {
	/// One inbox in a view: an address inbox of an account, or the whole account when it has no
	/// address inboxes of its own (`inboxID` is nil).
	struct Member: Codable, Hashable {
		var accountID: String
		var inboxID: String?
	}

	var id = UUID().uuidString
	var name = ""
	var members: [Member] = []

	/// The accounts the view draws from, in first-seen order.
	var accountIDs: [String] {
		var seen = Set<String>()
		return members.map(\.accountID).filter { seen.insert($0).inserted }
	}
}

/// Message ids are only unique within an account (IMAP ids are `INBOX:12`), so in a view that mixes
/// accounts each id carries its account in front, and actions split it again.
enum ViewMessageID {
	private static let separator: Character = "\u{1F}"

	static func make(account: String, message: String) -> String { "\(account)\(separator)\(message)" }

	/// The account and the account's own id for a message; nil account when `id` is not composite.
	static func split(_ id: String) -> (account: String?, message: String) {
		guard let at = id.firstIndex(of: separator) else { return (nil, id) }
		return (String(id[..<at]), String(id[id.index(after: at)...]))
	}
}
