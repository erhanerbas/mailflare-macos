import Foundation
import ServiceManagement

/// The pages of the Settings view, listed in the sidebar in this order.
enum SettingsPage: String, CaseIterable, Identifiable {
	case general, notifications, accounts, license, about

	var id: String { rawValue }

	var title: String {
		switch self {
		case .general: "General"
		case .notifications: "Notifications"
		case .accounts: "Accounts"
		case .license: "License"
		case .about: "About"
		}
	}

	var icon: AppIcon {
		switch self {
		case .general: .settings
		case .notifications: .bell
		case .accounts: .allInboxes
		case .license: .vip
		case .about: .info
		}
	}
}

/// Keys and defaults of the preferences that code outside the Settings view reads.
enum ReadingSettings {
	static let markReadDelayKey = "markReadDelay"
	static let loadRemoteContentKey = "loadRemoteContent"
	static let autoCheckUpdatesKey = "autoCheckUpdates"

	/// Seconds before an opened message is marked read: 0 at once, -1 never.
	static var markReadDelay: Int { UserDefaults.standard.object(forKey: markReadDelayKey) as? Int ?? 0 }
	static var autoCheckUpdates: Bool { UserDefaults.standard.object(forKey: autoCheckUpdatesKey) as? Bool ?? true }
}

enum LaunchAtLogin {
	static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

	/// Registers or removes the login item; returns whether the system now agrees.
	@discardableResult
	static func set(_ enabled: Bool) -> Bool {
		do {
			if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
		} catch {}
		return isEnabled == enabled
	}
}
