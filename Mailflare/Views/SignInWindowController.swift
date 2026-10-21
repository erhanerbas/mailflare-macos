import AppKit
import SwiftUI

/// The small sign-in window, shown on its own while there is no account. It is created here rather
/// than as a SwiftUI scene so it never opens by itself: the sign-in state decides when it is on screen.
@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate {
	static let shared = SignInWindowController()

	private var window: NSWindow?
	private weak var store: MailStore?

	func show(store: MailStore) {
		self.store = store
		if window == nil {
			let host = NSHostingController(rootView: SignInView(isPopup: false).environment(store))
			// The window follows the form's own height.
			host.sizingOptions = [.preferredContentSize]
			let window = NSWindow(contentViewController: host)
			window.title = "Sign In"
			window.styleMask = [.titled, .closable, .miniaturizable]
			window.isReleasedWhenClosed = false
			window.delegate = self
			window.center()
			self.window = window
		}
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	/// Hidden rather than closed, so signing out brings the same window back.
	func hide() {
		window?.orderOut(nil)
	}

	/// Closing it with no account signed in quits the app.
	func windowWillClose(_ notification: Notification) {
		if store?.phase != .ready { NSApp.terminate(nil) }
	}
}
