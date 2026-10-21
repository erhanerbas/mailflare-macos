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
	}

	private var canPost: Bool { authorization == .authorized || authorization == .provisional }

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
		guard NotificationSettings.flag(NotificationSettings.enabledKey), canPost else { return }
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

	/// With the app in front the list already shows the new mail, so nothing pops up.
	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }

	nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
		let info = response.notification.request.content.userInfo
		guard let account = info["account"] as? String, let message = info["message"] as? String else { return }
		await MainActor.run { self.open(account, message) }
	}
}
