import AppKit
import Observation
import UserNotifications
import MailflareCore

/// Keys and defaults of the Notifications settings.
enum NotificationSettings {
	static let enabledKey = "notificationsEnabled"
	static let previewsKey = "notificationPreviews"
	static let soundKey = "notificationSound"
	static let badgeKey = "dockBadge"

	static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Local notifications for new inbox mail, and the Dock badge. The store polls every account and
/// hands each account's inbox here after a sync; mail that was not in the previous look, is unread
/// and arrived in the last day is announced. The first look at an account only records what is there.
@MainActor
@Observable
final class MailNotifier: NSObject, UNUserNotificationCenterDelegate {
	private(set) var authorization: UNAuthorizationStatus = .notDetermined

	/// Accounts whose new mail is not announced. Everything notifies unless listed here.
	private(set) var mutedAccounts = Set(UserDefaults.standard.stringArray(forKey: "notificationMutedAccounts") ?? [])

	func notifies(_ accountID: String) -> Bool { !mutedAccounts.contains(accountID) }

	func setNotifies(_ on: Bool, accountID: String) {
		if on { mutedAccounts.remove(accountID) } else { mutedAccounts.insert(accountID) }
		UserDefaults.standard.set(Array(mutedAccounts), forKey: "notificationMutedAccounts")
	}

	/// Called with the account and message ids when a notification is clicked.
	@ObservationIgnored var open: (String, String) -> Void = { _, _ in }
	@ObservationIgnored private var known: [String: Set<String>] = [:]
	@ObservationIgnored private let center = UNUserNotificationCenter.current()

	/// More new messages than this in one look are announced as a single notification.
	private static let individualLimit = 3
	private static let freshness: TimeInterval = 24 * 60 * 60

	override init() {
		super.init()
		center.delegate = self
		// The permission is changed in System Settings, so look again whenever the app comes back.
		NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in await self?.refreshAuthorization() }
		}
	}

	private var canPost: Bool { isAllowed }

	/// Whether macOS lets Mailflare post notifications (System Settings → Notifications).
	var isAllowed: Bool { authorization == .authorized || authorization == .provisional }

	/// Mailflare's page in System Settings → Notifications. An app can ask for permission only once;
	/// after that, turning it on or off there is the user's to do.
	static func openSystemSettings() {
		let id = Bundle.main.bundleIdentifier ?? ""
		for string in ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)", "x-apple.systempreferences:com.apple.Notifications-Settings.extension"] {
			if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
		}
	}

	// MARK: Permission

	func refreshAuthorization() async {
		authorization = await center.notificationSettings().authorizationStatus
	}

	func requestAuthorization() async {
		_ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
		await refreshAuthorization()
	}

	/// At launch: learn the current permission, and ask once if notifications are on and it was never asked.
	func prepare() async {
		await refreshAuthorization()
		if authorization == .notDetermined, NotificationSettings.flag(NotificationSettings.enabledKey) {
			await requestAuthorization()
		}
	}

	// MARK: New mail

	func process(accountID: String, inbox: [MessageSummary], accountLabel: String?) {
		let ids = Set(inbox.map(\.id))
		guard let previous = known[accountID] else { known[accountID] = ids; return }
		known[accountID] = ids
		// The inbox was recorded above either way, so unmuting later announces only mail that arrives after.
		guard NotificationSettings.flag(NotificationSettings.enabledKey), canPost, notifies(accountID) else { return }
		let cutoff = Date().addingTimeInterval(-Self.freshness)
		let fresh = inbox.filter { !previous.contains($0.id) && !$0.seen && $0.date > cutoff }
		guard !fresh.isEmpty else { return }
		if fresh.count > Self.individualLimit {
			post(id: "summary-\(accountID)-\(Int(Date().timeIntervalSince1970))", accountID: accountID, messageID: fresh[0].id,
				title: "\(fresh.count) new messages", body: accountLabel ?? "", accountLabel: nil)
		} else {
			for message in fresh {
				let previews = NotificationSettings.flag(NotificationSettings.previewsKey)
				post(id: message.id, accountID: accountID, messageID: message.id,
					title: previews ? message.senderDisplay : "New message",
					body: previews ? (message.subject.isEmpty ? "(No Subject)" : message.subject) : "",
					accountLabel: accountLabel)
			}
		}
	}

	private func post(id: String, accountID: String, messageID: String, title: String, body: String, accountLabel: String?) {
		let content = UNMutableNotificationContent()
		content.title = title
		if let accountLabel { content.subtitle = accountLabel }
		content.body = body
		content.threadIdentifier = accountID
		content.userInfo = ["account": accountID, "message": messageID]
		if NotificationSettings.flag(NotificationSettings.soundKey) { content.sound = .default }
		center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
	}

	/// Takes a message's notification away once it has been read.
	func clear(messageID: String) {
		center.removeDeliveredNotifications(withIdentifiers: [messageID])
	}

	// MARK: Badge

	func setBadge(_ unread: Int) {
		let show = NotificationSettings.flag(NotificationSettings.badgeKey) && unread > 0
		NSApp.dockTile.badgeLabel = show ? (unread > 999 ? "999+" : "\(unread)") : nil
	}

	// MARK: Delegate

	/// New mail is announced with the app in front too: the window may be on another Space, behind
	/// other windows or showing a different mailbox. The sound follows the content's own setting.
	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
		[.banner, .list, .sound]
	}

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
		let info = response.notification.request.content.userInfo
		guard let account = info["account"] as? String, let message = info["message"] as? String else { return }
		await MainActor.run { self.open(account, message) }
	}
}
