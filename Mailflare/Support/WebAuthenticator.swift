import AppKit
import AuthenticationServices

/// Runs the provider's sign-in page in `ASWebAuthenticationSession` and returns the redirect URL.
/// The core builds the request and finishes the exchange; this only owns the system browser sheet.
@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
	struct Cancelled: Error {}

	private var session: ASWebAuthenticationSession?

	func authenticate(url: URL, redirectURI: String) async throws -> URL {
		guard let scheme = URL(string: redirectURI)?.scheme else { throw Cancelled() }
		return try await withCheckedThrowingContinuation { continuation in
			let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
				if let callback {
					continuation.resume(returning: callback)
				} else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
					continuation.resume(throwing: Cancelled())
				} else {
					continuation.resume(throwing: error ?? Cancelled())
				}
			}
			session.presentationContextProvider = self
			// Keep the browser's cookies so a second account is a click away.
			session.prefersEphemeralWebBrowserSession = false
			self.session = session
			if !session.start() { continuation.resume(throwing: Cancelled()) }
		}
	}

	nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
		MainActor.assumeIsolated {
			NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
		}
	}
}
