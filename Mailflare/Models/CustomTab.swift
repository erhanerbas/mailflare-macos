import Foundation
import MailflareCore

/// A tab in the sidebar's list under Today: an icon, a name and rules. It lists the Inbox mail that
/// matches them, and shows how many of those are unread.
struct CustomTab: Identifiable, Codable, Hashable {
	/// One condition. Which fields it uses depends on its kind: `text` for the three text kinds, `days`
	/// for `received`, none for the yes/no kinds.
	struct Rule: Identifiable, Codable, Hashable {
		enum Kind: String, Codable, CaseIterable, Identifiable {
			case unread, from, subject, text, attachment, starred, received
			var id: String { rawValue }

			/// The name in the rule's kind menu.
			var title: String {
				switch self {
				case .unread: "Is unread"
				case .from: "From"
				case .subject: "Subject contains"
				case .text: "Contains words"
				case .attachment: "Has an attachment"
				case .starred: "Is starred"
				case .received: "Received"
				}
			}

			/// What fills the value's place for the kinds that need none.
			var hint: String? {
				switch self {
				case .unread: "Only mail not read yet"
				case .attachment: "Only mail with files attached"
				case .starred: "Only mail you starred"
				default: nil
				}
			}

			/// What the text field asks for, for the kinds that have one.
			var placeholder: String? {
				switch self {
				case .from: "name, address or @domain"
				case .subject: "invoice, receipt"
				case .text: "words in the subject, sender or preview"
				default: nil
				}
			}
		}

		var id = UUID().uuidString
		var kind: Kind = .unread
		var text = ""
		/// For `received`: 1 is today, otherwise the number of days back, counting today.
		var days = 1

		static func received(days: Int) -> Rule { Rule(kind: .received, days: days) }

		/// Several values can be given, split by commas: a message matches when it has any of them.
		var terms: [String] {
			text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		}

		/// A text rule with nothing typed yet has nothing to match, so it is left out.
		var isComplete: Bool { kind.placeholder == nil || !terms.isEmpty }

		static let dayChoices: [(label: String, days: Int)] = [("Today", 1), ("In the last 7 days", 7), ("In the last 30 days", 30)]

		/// The rule as a phrase: "from acme.com or news@x.com".
		var summary: String {
			switch kind {
			case .unread: return "unread"
			case .attachment: return "with an attachment"
			case .starred: return "starred"
			case .received: return "received " + (Self.dayChoices.first { $0.days == days }?.label.lowercased() ?? "in the last \(days) days")
			case .from: return "from " + terms.joined(separator: " or ")
			case .subject: return "subject has " + terms.joined(separator: " or ")
			case .text: return "mentions " + terms.joined(separator: " or ")
			}
		}

		func matches(_ message: MessageSummary, now: Date) -> Bool {
			switch kind {
			case .unread: return !message.seen
			case .attachment: return message.hasAttachment
			case .starred: return message.flagged
			case .received:
				if days <= 1 { return Calendar.current.isDate(message.date, inSameDayAs: now) }
				let start = Calendar.current.startOfDay(for: now)
				guard let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: start) else { return false }
				return message.date >= from
			case .from: return Self.contains(terms, in: [message.fromName, message.fromEmail])
			case .subject: return Self.contains(terms, in: [message.subject])
			case .text: return Self.contains(terms, in: [message.subject, message.fromName, message.fromEmail, message.preview])
			}
		}

		private static func contains(_ terms: [String], in fields: [String]) -> Bool {
			terms.contains { term in
				fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
			}
		}
	}

	/// Rules nested as one unit: its own "all" or "any", matched like a single rule by the tab. This is
	/// how "(from Ann and unread) or starred" is written. Groups do not nest further.
	struct Group: Identifiable, Codable, Hashable {
		var id = UUID().uuidString
		var matchAll = false
		var rules: [Rule] = []

		var activeRules: [Rule] { rules.filter(\.isComplete) }

		var summary: String { activeRules.map(\.summary).joined(separator: matchAll ? " and " : " or ") }

		func matches(_ message: MessageSummary, now: Date) -> Bool {
			let active = activeRules
			guard !active.isEmpty else { return false }
			return matchAll ? active.allSatisfy { $0.matches(message, now: now) } : active.contains { $0.matches(message, now: now) }
		}
	}

	var id = UUID().uuidString
	var name = ""
	/// An `AppIcon` raw value.
	var icon = AppIcon.smartMailbox.rawValue
	/// Whether a message must match every rule and group, or just one.
	var matchAll = true
	var rules: [Rule] = []
	var groups: [Group] = []

	init(id: String = UUID().uuidString, name: String = "", icon: String = AppIcon.smartMailbox.rawValue,
		 matchAll: Bool = true, rules: [Rule] = [], groups: [Group] = []) {
		self.id = id; self.name = name; self.icon = icon
		self.matchAll = matchAll; self.rules = rules; self.groups = groups
	}

	// Tabs saved before groups existed have no `groups`.
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		name = try c.decode(String.self, forKey: .name)
		icon = try c.decode(String.self, forKey: .icon)
		matchAll = try c.decode(Bool.self, forKey: .matchAll)
		rules = try c.decode([Rule].self, forKey: .rules)
		groups = try c.decodeIfPresent([Group].self, forKey: .groups) ?? []
	}

	/// Today is the one tab that is always there and cannot be changed: unread mail received today.
	static let today = CustomTab(id: "today", name: "Today", icon: AppIcon.smartMailbox.rawValue, matchAll: true,
								 rules: [Rule(kind: .unread), .received(days: 1)])

	var isBuiltIn: Bool { id == Self.today.id }
	var appIcon: AppIcon { AppIcon(rawValue: icon) ?? .smartMailbox }

	/// The rules and groups that have something to match.
	var activeRules: [Rule] { rules.filter(\.isComplete) }
	var activeGroups: [Group] { groups.filter { !$0.activeRules.isEmpty } }

	/// A tab needs a name and at least one rule to be saved: with none, it would list the whole Inbox.
	var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !(activeRules.isEmpty && activeGroups.isEmpty) }

	/// "unread and (from Ann or starred)"
	var summary: String {
		let parts = activeRules.map(\.summary) + activeGroups.map { "(\($0.summary))" }
		guard !parts.isEmpty else { return "No rules yet" }
		return parts.joined(separator: matchAll ? " and " : " or ")
	}

	func matches(_ message: MessageSummary, now: Date = .now) -> Bool {
		let results = activeRules.map { $0.matches(message, now: now) } + activeGroups.map { $0.matches(message, now: now) }
		guard !results.isEmpty else { return false }
		return matchAll ? results.allSatisfy { $0 } : results.contains { $0 }
	}

	/// Icons the editor offers.
	static let iconChoices: [AppIcon] = [
		.smartMailbox, .vip, .flag, .bell, .clock, .attachment, .label, .folder, .inbox, .sparkles,
		.calendar, .cart, .money, .person, .work, .travel, .home, .bookmark, .parcel, .send,
	]
}
