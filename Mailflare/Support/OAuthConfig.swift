import Foundation
import MailflareCore

/// OAuth client registration for Outlook / Microsoft 365 (the only provider without app passwords). Client ids are public
/// identifiers, never secrets, and come from build settings so a fork can use its own registration:
///
/// - `MAILFLARE_OAUTH_MICROSOFT_CLIENT_ID`: an application (client) id from Entra with the
///   "Mobile and desktop" platform and redirect `msauth.<bundle id>://auth`, unless
///   `MAILFLARE_OAUTH_MICROSOFT_REDIRECT_SCHEME` says otherwise.
///
/// Debug builds also read the same names from the environment.
enum OAuthConfig {
	private static func setting(_ key: String) -> String? {
		var value = Bundle.main.object(forInfoDictionaryKey: key) as? String
		#if DEBUG
		if value?.isEmpty ?? true { value = ProcessInfo.processInfo.environment[key] }
		#endif
		let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		// An unset build setting can leave the literal `$(NAME)` behind.
		return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
	}

	/// The registration for `provider`, or nil when this build has none.
	static func client(for provider: OAuthProvider) -> OAuthClient? {
		switch provider {
		case .microsoft:
			guard let id = setting("MAILFLARE_OAUTH_MICROSOFT_CLIENT_ID") else { return nil }
			let bundle = Bundle.main.bundleIdentifier ?? "xyz.hieunguyen.Mailflare"
			let scheme = setting("MAILFLARE_OAUTH_MICROSOFT_REDIRECT_SCHEME") ?? "msauth.\(bundle)"
			return OAuthClient(provider: .microsoft, clientId: id, redirectUri: "\(scheme)://auth")
		}
	}

	static func isAvailable(_ provider: OAuthProvider) -> Bool { client(for: provider) != nil }
}
