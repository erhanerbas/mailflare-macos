import Foundation
import MailflareCore

enum SidebarItem: Hashable {
	case allInboxes, vips, flagged, remindMe, allDrafts, allSent
	case allJunk, allTrash, allArchive
	case smartToday
	/// A tab the user made, by its id (see `CustomTab`).
	case customTab(String)
	case mailbox(String)
}

extension MessageSummary: Identifiable {
	var date: Date { Date(timeIntervalSince1970: TimeInterval(receivedAt)) }
	var senderDisplay: String { fromName.isEmpty ? fromEmail : fromName }
	var sender: EmailAddress { EmailAddress(name: fromName.isEmpty ? nil : fromName, email: fromEmail) }
}

extension Mailbox: Identifiable {
	/// An inbox's label without its address: the display name from "Name <me@example.com>",
	/// or the part before the @ when there is none.
	/// The address in "Name <me@example.com>", or the whole name when there are no brackets.
	var inboxEmail: String {
		if let open = name.firstIndex(of: "<"), let close = name.lastIndex(of: ">"), open < close {
			return String(name[name.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
		}
		return name.trimmingCharacters(in: .whitespaces)
	}

	var inboxLabel: String {
		if let open = name.firstIndex(of: "<") {
			let display = name[..<open].trimmingCharacters(in: .whitespaces)
			if !display.isEmpty { return display }
		}
		let bare = name.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
		return bare.split(separator: "@", maxSplits: 1).first.map(String.init) ?? bare
	}

	/// Mailflare's top-level mailbox per address holds all of its mail; only its children hold messages directly.
	var isAccount: Bool { parentId == nil && role == nil }
}

extension Identity: Identifiable {}

extension Account: Identifiable {
	/// The server's name for the account; its address when the name is just the address.
	var shownName: String {
		displayName.contains("@") ? (displayName.split(separator: "@").first.map(String.init) ?? displayName) : displayName
	}
}

extension EmailAddress: Hashable, Identifiable {
	public var id: String { email }
	var display: String { (name?.isEmpty == false ? name : nil) ?? email }
	var initials: String {
		let parts = display.split(whereSeparator: { " .@".contains($0) }).prefix(2)
		return parts.compactMap(\.first).map { String($0).uppercased() }.joined()
	}
	/// `Name <a@b>` for the To field.
	var formatted: String { name?.isEmpty == false ? "\(name!) <\(email)>" : email }
}

extension Attachment: Identifiable {
	public var id: String { blobId }
	var displayName: String { name ?? "attachment" }
}

struct ComposeDraft: Identifiable {
	let id = UUID()
	/// The composer's heading: what kind of message this is, which the subject never changes.
	var title = "New Message"
	var identityID: String?
	var to = ""
	var cc = ""
	var bcc = ""
	var subject = ""
	/// The editable part of the message, as HTML.
	var body = ""
	/// The quoted original of a reply or forward: shown folded, and appended below the body on send.
	var quotedHTML = ""
	var inReplyTo: String?
	var references: [String] = []
	var attachments: [OutgoingAttachment] = []
	var replacesDraftID: String?
	/// The account the message is written in; nil is the account in view.
	var accountID: String?
}

extension OutgoingAttachment: Identifiable {
	public var id: String { (filePath ?? blobId ?? "") + name }
}

enum SignInOutcome {
	case signedIn
	case needsCode(challenge: String, serverURL: String)
}

enum Addresses {
	/// Parses `a@b, Name <c@d>` into addresses; entries without an `@` are dropped.
	static func parse(_ field: String) -> [EmailAddress] {
		field.split(whereSeparator: { ",;\n".contains($0) }).compactMap { part in
			let s = part.trimmingCharacters(in: .whitespaces)
			if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
				let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
				let name = s[..<lt].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
				return email.contains("@") ? EmailAddress(name: name.isEmpty ? nil : name, email: email) : nil
			}
			return s.contains("@") ? EmailAddress(name: nil, email: s) : nil
		}
	}

	static func format(_ list: [EmailAddress]) -> String { list.map(\.formatted).joined(separator: ", ") }
}

func describe(_ error: Error) -> String {
	if let e = error as? CoreError {
		switch e {
		case .Auth(let m), .Discovery(let m), .Network(let m), .Server(let m),
			 .Storage(let m), .NotFound(let m), .InvalidInput(let m): return m
		}
	}
	return error.localizedDescription
}


/// Dates and times in the user's own locale and clock style (12 or 24 hour), always with the time.
enum MailDate {
	/// List rows: just the time for today's mail, otherwise the date and the time.
	static func list(_ date: Date) -> String {
		if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
		if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
			return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
		}
		return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
	}

	/// The reader: the full date with the time.
	static func full(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

struct Toast: Identifiable, Equatable {
	let id = UUID()
	var title: String
	var detail: String
	var icon: AppIcon
	var isProgress: Bool
}
