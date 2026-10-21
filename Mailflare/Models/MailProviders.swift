import SwiftUI
import MailflareCore

/// How a connection is secured.
enum ConnectionSecurity: String, CaseIterable, Identifiable, Hashable {
	case tls = "SSL/TLS"
	case startTLS = "STARTTLS"
	case none = "None"
	var id: String { rawValue }

	var transport: TransportSecurity {
		switch self {
		case .tls: .tls
		case .startTLS: .startTls
		case .none: .none
		}
	}
}

/// One server endpoint (incoming or outgoing).
struct ServerEndpoint: Hashable {
	var host: String
	var port: Int
	var security: ConnectionSecurity

	var core: MailEndpoint {
		MailEndpoint(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(clamping: port), security: security.transport)
	}
}

enum MailProtocol: String, CaseIterable, Identifiable, Hashable {
	case jmap = "JMAP"
	case imap = "IMAP"
	var id: String { rawValue }
}

/// What the sign-in form needs for a provider.
enum ProviderKind: Hashable {
	/// Mailflare: found over JMAP; the password is the account password or an app password.
	case mailflare
	/// IMAP/SMTP with known servers, filled in by default and open to review.
	case imap(incoming: ServerEndpoint, outgoing: ServerEndpoint)
	/// Every field is entered by hand.
	case custom
}

enum UsernameStyle: Hashable {
	case email       // the full address
	case localPart   // the part before the @
}

struct MailProvider: Identifiable, Hashable {
	let id: String
	let name: String
	/// Letter badge colour (no brand artwork).
	let color: UInt32
	let kind: ProviderKind
	let username: UsernameStyle
	/// Domains that select this provider automatically.
	let domains: [String]

	var initial: String { String(name.prefix(1)) }

	func username(for email: String) -> String {
		switch username {
		case .email: email
		case .localPart: email.split(separator: "@").first.map(String.init) ?? email
		}
	}

	static func imap(
		_ id: String, _ name: String, color: UInt32, imap: String, smtp: String, smtpPort: Int = 465,
		domains: [String], username: UsernameStyle = .email
	) -> MailProvider {
		MailProvider(
			id: id, name: name, color: color,
			kind: .imap(
				incoming: ServerEndpoint(host: imap, port: 993, security: .tls),
				outgoing: ServerEndpoint(host: smtp, port: smtpPort, security: smtpPort == 587 ? .startTLS : .tls)),
			username: username, domains: domains)
	}
}

enum MailProviders {
	static let mailflare = MailProvider(id: "mailflare", name: "Mailflare", color: 0xF4511E, kind: .mailflare, username: .email, domains: [])
	static let custom = MailProvider(id: "custom", name: "Other mail server", color: 0x757575, kind: .custom, username: .email, domains: [])

	/// Common providers with their published IMAP and SMTP settings.
	static let common: [MailProvider] = [
		.imap("gmail", "Gmail", color: 0xEA4335, imap: "imap.gmail.com", smtp: "smtp.gmail.com", domains: ["gmail.com", "googlemail.com"]),
		.imap("outlook", "Outlook", color: 0x0078D4, imap: "outlook.office365.com", smtp: "smtp-mail.outlook.com", smtpPort: 587,
			domains: ["outlook.com", "hotmail.com", "live.com", "msn.com"]),
		.imap("icloud", "iCloud Mail", color: 0x3693F3, imap: "imap.mail.me.com", smtp: "smtp.mail.me.com", smtpPort: 587,
			domains: ["icloud.com", "me.com", "mac.com"]),
		.imap("yahoo", "Yahoo Mail", color: 0x6001D2, imap: "imap.mail.yahoo.com", smtp: "smtp.mail.yahoo.com",
			domains: ["yahoo.com", "ymail.com", "rocketmail.com"]),
		.imap("aol", "AOL Mail", color: 0x31459B, imap: "imap.aol.com", smtp: "smtp.aol.com", domains: ["aol.com"]),
		.imap("zoho", "Zoho Mail", color: 0xE42527, imap: "imap.zoho.com", smtp: "smtp.zoho.com", domains: ["zoho.com", "zohomail.com"]),
		.imap("yandex", "Yandex Mail", color: 0xFC3F1D, imap: "imap.yandex.com", smtp: "smtp.yandex.com", domains: ["yandex.com", "yandex.ru", "ya.ru"]),
		.imap("gmx", "GMX", color: 0x1C449B, imap: "imap.gmx.com", smtp: "mail.gmx.com", smtpPort: 587, domains: ["gmx.com", "gmx.net", "gmx.de"]),
		.imap("fastmail", "Fastmail", color: 0x0067B9, imap: "imap.fastmail.com", smtp: "smtp.fastmail.com", domains: ["fastmail.com", "fastmail.fm"]),
		.imap("mailru", "Mail.ru", color: 0x005FF9, imap: "imap.mail.ru", smtp: "smtp.mail.ru", domains: ["mail.ru", "inbox.ru", "list.ru", "bk.ru"]),
	]

	/// The provider an address belongs to, if it is a well-known one.
	static func match(email: String) -> MailProvider? {
		guard email.contains("@"), let domain = email.split(separator: "@").last?.lowercased() else { return nil }
		return common.first { $0.domains.contains(domain) }
	}
}

/// A coloured letter badge standing in for a provider's logo.
struct ProviderBadge: View {
	let provider: MailProvider
	var size: CGFloat = 26

	var body: some View {
		Group {
			if provider.id == "custom" {
				Text("···").font(.system(size: size * 0.5, weight: .bold))
			} else {
				Text(provider.initial).font(.system(size: size * 0.5, weight: .semibold))
			}
		}
		.foregroundStyle(.white)
		.frame(width: size, height: size)
		.background(Color(nsColor: NSColor(rgb: provider.color)), in: Circle())
	}
}
