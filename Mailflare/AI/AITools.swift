import Foundation
import MailflareCore

/// The mail tools the assistant can call, mirroring the Mailflare web assistant's. They act on the
/// account in view. Nothing here sends mail: `review_draft_send` opens the composer so the user does.
@MainActor
struct AIMailTools {
	let store: MailStore
	/// The content of the draft the last tool call saved, for the chat's button to open.
	let capture = DraftCapture()

	// MARK: Definitions

	private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
		["type": "function", "function": [
			"name": name, "description": description,
			"parameters": ["type": "object", "properties": properties, "required": required],
		] as [String: Any]]
	}

	private static let folders = ["inbox", "sent", "draft", "archived", "trash", "spam"]
	private static let destinations = ["inbox", "archived", "trash", "spam"]
	private static let id: [String: Any] = ["type": "string", "description": "An emailId returned by another tool."]
	private static let prose: [String: Any] = ["type": "string", "description": "The recipient-facing email body as ordinary prose with paragraphs. No Markdown or HTML."]
	private static let recipients: [String: Any] = ["type": "string", "description": "Comma-separated email addresses."]

	static let definitions: [[String: Any]] = [
		tool("list_emails", "List email metadata in a folder with pagination. Omit cursor for the first page; pass the returned nextCursor for the next one.", [
			"folder": ["type": "string", "enum": folders, "description": "Defaults to inbox."],
			"limit": ["type": "integer", "description": "1 to 50, default 20."],
			"cursor": ["type": "string", "description": "Only the exact nextCursor from the previous call."],
		]),
		tool("get_current_email", "Get the email the user has open in the reader right now, with its body. Call this whenever the user says \"this email\", \"this thread\", \"this message\" or \"the open email\". Reports when nothing is open."),
		tool("get_email", "Read one email and its attachment names. Does not mark it read.", ["emailId": id], required: ["emailId"]),
		tool("get_thread", "Read the recent conversation containing an email. Do this before drafting a reply.", ["emailId": id], required: ["emailId"]),
		tool("search_emails", "Search email subject, sender and body.", [
			"query": ["type": "string"], "limit": ["type": "integer", "description": "1 to 50, default 20."],
		], required: ["query"]),
		tool("draft_email", "Save a new email draft. This never sends.", [
			"to": recipients, "cc": recipients, "subject": ["type": "string"], "body": prose,
		], required: ["to", "subject", "body"]),
		tool("draft_reply", "Save a reply draft with recipients and threading taken from the source email. This never sends.", [
			"emailId": id, "body": prose, "replyAll": ["type": "boolean"],
		], required: ["emailId", "body"]),
		tool("edit_draft", "Change a saved draft. Returns its new draftId, which replaces the old one.", [
			"draftId": id, "to": recipients, "cc": recipients, "bcc": recipients,
			"subject": ["type": "string"], "body": prose,
		], required: ["draftId"]),
		tool("review_draft_send", "Open a draft in the composer so the user can review and send it. You cannot send mail yourself.", ["draftId": id], required: ["draftId"]),
		tool("discard_draft", "Delete a draft.", ["draftId": id], required: ["draftId"]),
		tool("mark_email_read", "Mark an email read or unread.", ["emailId": id, "read": ["type": "boolean"]], required: ["emailId", "read"]),
		tool("move_email", "Move an email to inbox, archive, trash or spam.", ["emailId": id, "destination": ["type": "string", "enum": destinations]], required: ["emailId", "destination"]),
		tool("move_emails", "Move up to 20 emails to inbox, archive, trash or spam.", [
			"emailIds": ["type": "array", "items": ["type": "string"]], "destination": ["type": "string", "enum": destinations],
		], required: ["emailIds", "destination"]),
	]

	/// The line shown in the chat while a tool runs, and once it is done.
	static func activity(_ name: String, done: Bool) -> String {
		switch name {
		case "list_emails": done ? "Listed emails" : "Listing emails…"
		case "get_current_email": done ? "Read the open email" : "Reading the open email…"
		case "get_email": done ? "Read an email" : "Reading an email…"
		case "get_thread": done ? "Read the conversation" : "Reading the conversation…"
		case "search_emails": done ? "Searched emails" : "Searching emails…"
		case "draft_email": done ? "Saved a draft" : "Writing a draft…"
		case "draft_reply": done ? "Saved a reply draft" : "Writing a reply…"
		case "edit_draft": done ? "Updated the draft" : "Editing the draft…"
		case "review_draft_send": done ? "Opened the draft for review" : "Opening the draft…"
		case "discard_draft": done ? "Discarded a draft" : "Discarding a draft…"
		case "mark_email_read": done ? "Updated read state" : "Updating read state…"
		case "move_email", "move_emails": done ? "Moved mail" : "Moving mail…"
		default: done ? name : "\(name)…"
		}
	}

	// MARK: Running

	struct Failure: Error { let message: String }

	/// Runs a tool and returns its JSON result; a failure is also JSON, for the model to read.
	func run(name: String, arguments: String) async -> (json: String, ok: Bool) {
		let args = (arguments.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
		do {
			guard store.mailCore != nil else { throw Failure(message: "No account is open.") }
			let result = try await dispatch(name, args)
			return (Self.encode(result), true)
		} catch let failure as Failure {
			return (Self.encode(["error": failure.message]), false)
		} catch {
			return (Self.encode(["error": describe(error)]), false)
		}
	}

	private func dispatch(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
		switch name {
		case "list_emails": return try listEmails(args)
		case "get_current_email": return try await getCurrentEmail()
		case "get_email": return try await getEmail(try string(args, "emailId"))
		case "get_thread": return try await getThread(try string(args, "emailId"))
		case "search_emails": return try await search(args)
		case "draft_email": return try await draftEmail(args)
		case "draft_reply": return try await draftReply(args)
		case "edit_draft": return try await editDraft(args)
		case "review_draft_send": return try reviewDraft(try string(args, "draftId"))
		case "discard_draft": return try discardDraft(try string(args, "draftId"))
		case "mark_email_read": return try markRead(args)
		case "move_email": return try move(ids: [try string(args, "emailId")], to: try string(args, "destination"))
		case "move_emails":
			let ids = (args["emailIds"] as? [String]) ?? []
			guard !ids.isEmpty, ids.count <= 20 else { throw Failure(message: "Give between 1 and 20 emailIds.") }
			return try move(ids: ids, to: try string(args, "destination"))
		default: throw Failure(message: "Unknown tool \(name).")
		}
	}

	private var core: MailCore { store.mailCore! }
	private var accountID: String { store.currentAccountID }

	private func string(_ args: [String: Any], _ key: String) throws -> String {
		guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
			throw Failure(message: "Missing \(key).")
		}
		return value
	}

	private func limit(_ args: [String: Any]) -> UInt32 {
		UInt32(min(50, max(1, (args["limit"] as? Int) ?? 20)))
	}

	// MARK: Reading

	private func role(forFolder folder: String) throws -> String {
		switch folder {
		case "inbox": return "inbox"
		case "sent": return "sent"
		case "draft": return "drafts"
		case "archived": return "archive"
		case "trash": return "trash"
		case "spam": return "junk"
		default: throw Failure(message: "Unknown folder \(folder).")
		}
	}

	private func listEmails(_ args: [String: Any]) throws -> [String: Any] {
		let folder = (args["folder"] as? String) ?? "inbox"
		let count = limit(args)
		var offset: UInt32 = 0
		if let cursor = args["cursor"] as? String, !cursor.isEmpty {
			guard let parsed = UInt32(cursor) else { throw Failure(message: "Invalid cursor. Use only a nextCursor returned by list_emails.") }
			offset = parsed
		}
		let list = try core.messages(accountId: accountID, folder: .role(role: try role(forFolder: folder)), offset: offset, limit: count)
		return [
			"emails": list.map(Self.brief),
			"nextCursor": list.count == Int(count) ? String(offset + count) : NSNull(),
		]
	}

	private func getCurrentEmail() async throws -> [String: Any] {
		guard let id = store.openEmailIDForAI else {
			return ["open": false, "note": "No email is open. Ask the user which email they mean, or use list_emails or search_emails."]
		}
		var result = try await getEmail(id)
		result["open"] = true
		if let message = store.selectedMessage, let role = store.role(of: message) { result["folder"] = role }
		return result
	}

	private func getEmail(_ id: String) async throws -> [String: Any] {
		let detail = try await core.loadMessage(accountId: accountID, messageId: id)
		var result = Self.brief(detail.summary)
		result["to"] = Addresses.format(detail.to)
		result["cc"] = Addresses.format(detail.cc)
		result["body"] = Self.truncate(AIText.plain(fromHTML: detail.html), 12_000)
		result["attachments"] = detail.attachments.map { ["name": $0.name ?? "attachment", "type": $0.mimeType, "size": $0.size] as [String: Any] }
		return result
	}

	private func getThread(_ id: String) async throws -> [String: Any] {
		let anchor = try await core.loadMessage(accountId: accountID, messageId: id)
		let threadID = anchor.summary.threadId
		var found: [MessageSummary] = []
		for role in ["inbox", "sent", "archive", "drafts"] {
			let list = (try? core.messages(accountId: accountID, folder: .role(role: role), offset: 0, limit: 300)) ?? []
			found += list.filter { $0.threadId == threadID }
		}
		if !found.contains(where: { $0.id == id }) { found.append(anchor.summary) }
		let recent = found.sorted { $0.receivedAt < $1.receivedAt }.suffix(8)
		var messages: [[String: Any]] = []
		for summary in recent {
			var item = Self.brief(summary)
			if let detail = try? await core.loadMessage(accountId: accountID, messageId: summary.id) {
				item["body"] = Self.truncate(AIText.plain(fromHTML: detail.html), 4_000)
			}
			messages.append(item)
		}
		return ["threadId": threadID, "messages": messages]
	}

	private func search(_ args: [String: Any]) async throws -> [String: Any] {
		let query = try string(args, "query")
		let count = limit(args)
		var list = try core.search(accountId: accountID, query: query, limit: count)
		if list.isEmpty, let remote = try? await core.searchServer(accountId: accountID, query: query, limit: count) { list = remote }
		return ["emails": list.map(Self.brief)]
	}

	// MARK: Drafting

	private var identity: Identity? { store.identities.first }

	final class DraftCapture {
		var draft: ChatDraft?
		func take() -> ChatDraft? { defer { draft = nil }; return draft }
	}

	/// Tools whose result carries the id of a draft the user can open.
	static func savesDraft(_ name: String) -> Bool { ["draft_email", "draft_reply", "edit_draft"].contains(name) }

	private func draftIDs() -> [String] {
		((try? core.messages(accountId: accountID, folder: .role(role: "drafts"), offset: 0, limit: 100)) ?? []).map(\.id)
	}

	/// Queues the draft, then waits for the core to create it on the server and for it to reach the
	/// local store. `saveDraft` returns the outbox entry's id, which is not the message's: the model
	/// needs the real one for `edit_draft`, `review_draft_send` and `discard_draft`.
	private func saveSettled(_ message: OutgoingMessage) async throws -> String {
		let before = Set(draftIDs())
		let queued = try core.saveDraft(accountId: accountID, message: message)
		for _ in 0..<50 {
			guard let item = (try? core.outbox(accountId: accountID))?.first(where: { $0.clientId == queued }) else { break }
			if let error = item.error { throw Failure(message: "Saving the draft failed: \(error)") }
			try? await Task.sleep(for: .milliseconds(400))
		}
		for _ in 0..<25 {
			if let created = draftIDs().first(where: { !before.contains($0) }) {
				store.aiDidChangeMail()
				return created
			}
			try? await Task.sleep(for: .milliseconds(400))
		}
		store.aiDidChangeMail()
		throw Failure(message: "The draft was queued but has not appeared in Drafts yet. Tell the user to look there shortly; do not retry.")
	}

	private func draftEmail(_ args: [String: Any]) async throws -> [String: Any] {
		guard let identity else { throw Failure(message: "This account has no address to send from.") }
		let to = Addresses.parse(try string(args, "to"))
		guard !to.isEmpty else { throw Failure(message: "Add at least one valid recipient.") }
		let message = OutgoingMessage(
			identityId: identity.id, to: to, cc: Addresses.parse((args["cc"] as? String) ?? ""), bcc: [],
			subject: try string(args, "subject"), html: AIText.html(fromProse: try string(args, "body")),
			inReplyTo: nil, references: [], attachments: [], replacesDraftId: nil)
		let id = try await saveSettled(message)
		capture.draft = ChatDraft(
			draftID: id, isReply: false, accountID: accountID, identityID: identity.id,
			to: Addresses.format(to), cc: Addresses.format(message.cc), bcc: "", subject: message.subject,
			bodyHTML: message.html, quotedHTML: "", inReplyTo: nil, references: [])
		return ["draftId": id, "note": "Saved as a draft. It has not been sent."]
	}

	private func draftReply(_ args: [String: Any]) async throws -> [String: Any] {
		let source = try string(args, "emailId")
		let template = try await core.composeTemplate(accountId: accountID, messageId: source, kind: (args["replyAll"] as? Bool) == true ? .replyAll : .reply)
		guard let identityID = template.identityId ?? identity?.id else { throw Failure(message: "This account has no address to send from.") }
		let body = AIText.html(fromProse: try string(args, "body"))
		let message = OutgoingMessage(
			identityId: identityID, to: template.to, cc: template.cc, bcc: template.bcc, subject: template.subject,
			html: template.quotedHtml.isEmpty ? body : body + "<br>" + template.quotedHtml,
			inReplyTo: template.inReplyTo, references: template.references, attachments: template.attachments,
			replacesDraftId: template.replacesDraftId)
		let id = try await saveSettled(message)
		capture.draft = ChatDraft(
			draftID: id, isReply: true, accountID: accountID, identityID: identityID,
			to: Addresses.format(template.to), cc: Addresses.format(template.cc), bcc: Addresses.format(template.bcc),
			subject: template.subject, bodyHTML: body, quotedHTML: template.quotedHtml,
			inReplyTo: template.inReplyTo, references: template.references)
		return ["draftId": id, "to": Addresses.format(template.to), "subject": template.subject, "note": "Saved as a draft. It has not been sent."]
	}

	private func editDraft(_ args: [String: Any]) async throws -> [String: Any] {
		let draftID = try string(args, "draftId")
		let template = try await core.draftTemplate(accountId: accountID, messageId: draftID)
		guard let identityID = template.identityId ?? identity?.id else { throw Failure(message: "This account has no address to send from.") }
		func addresses(_ key: String, _ current: [EmailAddress]) -> [EmailAddress] {
			(args[key] as? String).map(Addresses.parse) ?? current
		}
		let body = (args["body"] as? String).map(AIText.html(fromProse:)) ?? template.bodyHtml
		let message = OutgoingMessage(
			identityId: identityID, to: addresses("to", template.to), cc: addresses("cc", template.cc), bcc: addresses("bcc", template.bcc),
			subject: (args["subject"] as? String) ?? template.subject,
			html: template.quotedHtml.isEmpty ? body : body + "<br>" + template.quotedHtml,
			inReplyTo: template.inReplyTo, references: template.references, attachments: template.attachments,
			replacesDraftId: draftID)
		let id = try await saveSettled(message)
		capture.draft = ChatDraft(
			draftID: id, isReply: template.inReplyTo != nil, accountID: accountID, identityID: identityID,
			to: Addresses.format(message.to), cc: Addresses.format(message.cc), bcc: Addresses.format(message.bcc),
			subject: message.subject, bodyHTML: body, quotedHTML: template.quotedHtml,
			inReplyTo: template.inReplyTo, references: template.references)
		return ["draftId": id, "note": "Draft updated. It has not been sent."]
	}

	private func reviewDraft(_ id: String) throws -> [String: Any] {
		store.editDraft(id)
		return ["note": "The draft is open in the composer. The user must review it and press Send; it has not been sent."]
	}

	private func discardDraft(_ id: String) throws -> [String: Any] {
		_ = try core.deleteMessages(accountId: accountID, messageIds: [id])
		store.aiDidChangeMail()
		return ["discarded": true]
	}

	// MARK: Changing mail

	private func markRead(_ args: [String: Any]) throws -> [String: Any] {
		let id = try string(args, "emailId")
		let read = (args["read"] as? Bool) ?? true
		try core.setSeen(accountId: accountID, messageIds: [id], seen: read)
		store.aiDidChangeMail()
		return ["emailId": id, "read": read]
	}

	private func move(ids: [String], to destination: String) throws -> [String: Any] {
		guard Self.destinations.contains(destination) else { throw Failure(message: "Unknown destination \(destination).") }
		let role = try self.role(forFolder: destination)
		let moved = try core.moveMessages(accountId: accountID, messageIds: ids, target: .role(role: role))
		store.aiDidChangeMail()
		return ["moved": Int(moved), "destination": destination]
	}

	// MARK: Formatting

	private static func brief(_ m: MessageSummary) -> [String: Any] {
		[
			"emailId": m.id, "threadId": m.threadId,
			"from": m.fromName.isEmpty ? m.fromEmail : "\(m.fromName) <\(m.fromEmail)>",
			"to": m.toDisplay, "subject": m.subject, "snippet": truncate(m.preview, 240),
			"date": ISO8601DateFormatter().string(from: m.date), "read": m.seen,
			"starred": m.flagged, "hasAttachment": m.hasAttachment,
		]
	}

	private static func truncate(_ text: String, _ limit: Int) -> String {
		text.count > limit ? String(text.prefix(limit)) + "… [truncated]" : text
	}

	private static func encode(_ object: [String: Any]) -> String {
		guard JSONSerialization.isValidJSONObject(object),
			  let data = try? JSONSerialization.data(withJSONObject: object),
			  let text = String(data: data, encoding: .utf8) else { return "{}" }
		return text
	}
}

/// Text and HTML conversions for tool results and drafts.
enum AIText {
	/// Readable text for a model: no markup, paragraph breaks kept.
	static func plain(fromHTML html: String) -> String {
		var text = html
		for pattern in ["<style[^>]*>.*?</style>", "<script[^>]*>.*?</script>", "<!--.*?-->"] {
			text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
		}
		text = text.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>|</tr>|</h[1-6]>", with: "\n", options: [.regularExpression, .caseInsensitive])
		text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
		for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
			text = text.replacingOccurrences(of: entity, with: value)
		}
		text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
		text = text.replacingOccurrences(of: "\\n\\s*\\n(\\s*\\n)+", with: "\n\n", options: .regularExpression)
		return text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// An HTML body for the composer from ordinary prose: paragraphs split on blank lines.
	static func html(fromProse prose: String) -> String {
		func escape(_ s: String) -> String {
			s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
		}
		return prose.replacingOccurrences(of: "\r\n", with: "\n")
			.components(separatedBy: "\n\n")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.map { "<div>" + escape($0).replacingOccurrences(of: "\n", with: "<br>") + "</div>" }
			.joined(separator: "<div><br></div>")
	}
}
