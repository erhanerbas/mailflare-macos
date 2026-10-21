import SwiftUI

/// The Settings page in the main card, chosen from the sidebar's settings menu.
struct SettingsView: View {
	@Environment(MailStore.self) private var store
	var page: SettingsPage

	var body: some View {
		VStack(spacing: 0) {
			Text(page.title)
				.font(.system(size: 15, weight: .semibold))
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 24)
				.frame(height: PaneHeader.height)
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
			ScrollView {
				VStack(alignment: .leading, spacing: 22) {
					switch page {
					case .general: GeneralSettings()
					case .notifications: NotificationSettingsPage()
					case .accounts: AccountSettings()
					case .license: LicenseSettings()
					case .about: AboutSettings()
					}
				}
				.frame(maxWidth: 560, alignment: .leading)
				.padding(24)
				.frame(maxWidth: .infinity, alignment: .top)
			}
		}
		.background(AppTheme.background)
	}
}

// MARK: Building blocks

/// A titled card of rows. Rows are separated with `SettingsDivider`, and each brings its own
/// vertical padding, so a single row and a long list both sit evenly.
/// Set by an open dropdown so its group is drawn above the groups after it.
private struct OpenDropdownKey: PreferenceKey {
	static let defaultValue = false
	static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct SettingsGroup<Content: View>: View {
	var title: String
	var footer: String?
	@ViewBuilder var content: Content
	@State private var hasOpenDropdown = false

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 0) { content }
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 14)
				.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			if let footer {
				Text(footer).font(Typography.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
		}
		.onPreferenceChange(OpenDropdownKey.self) { hasOpenDropdown = $0 }
		.zIndex(hasOpenDropdown ? 10 : 0)
	}
}

private struct SettingsDivider: View {
	var body: some View { Rectangle().fill(AppTheme.cardStroke).frame(height: 1) }
}

/// One line of a group: content with the group's row padding.
private struct SettingsRow<Content: View>: View {
	@ViewBuilder var content: Content

	var body: some View {
		HStack(spacing: 10) { content }
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 12)
	}
}

/// The label on the left, the switch on the right.
private struct SettingsToggle: View {
	var title: String
	var detail: String?
	@Binding var isOn: Bool

	var body: some View {
		SettingsRow {
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(Typography.body)
				if let detail {
					Text(detail).font(Typography.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 12)
			Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
		}
	}
}

/// A choice drawn as its current value and a chevron; opening it drops a card like the account
/// dropdown's, with a check on the chosen row.
private struct SettingsPicker<Value: Hashable>: View {
	var title: String
	var options: [(label: String, value: Value)]
	@Binding var selection: Value
	@State private var isOpen = false
	@State private var isHovering = false

	private var currentLabel: String { options.first { $0.value == selection }?.label ?? "" }

	var body: some View {
		SettingsRow {
			Text(title).font(Typography.body)
			Spacer(minLength: 12)
			Button { withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() } } label: {
				HStack(spacing: 6) {
					Text(currentLabel).font(Typography.body)
					HIcon(.chevronDown, size: 12).foregroundStyle(.secondary)
						.rotationEffect(.degrees(isOpen ? 180 : 0))
				}
				.padding(.horizontal, 8).padding(.vertical, 4)
				.background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering || isOpen ? AppTheme.rowHighlight : .clear))
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.onHover { isHovering = $0 }
			.overlay(alignment: .topTrailing) {
				if isOpen { dropdown.offset(y: 32) }
			}
			// A click anywhere else closes it.
			.clickAway(isActive: isOpen) { withAnimation(.snappy(duration: 0.2)) { isOpen = false } }
		}
		.zIndex(isOpen ? 1 : 0)
		.preference(key: OpenDropdownKey.self, value: isOpen)
	}

	private var dropdown: some View {
		DropdownCard(width: 190) {
			ForEach(Array(options.enumerated()), id: \.offset) { _, option in
				DropdownRow(label: option.label, isSelected: option.value == selection) {
					selection = option.value
					withAnimation(.snappy(duration: 0.2)) { isOpen = false }
				}
			}
		}
	}
}

/// A button as wide as the page, outside any group.
private struct WideButton: View {
	var title: String
	var icon: AppIcon?
	var prominent = false
	var action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				if let icon { HIcon(icon, size: 14) }
				Text(title)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 7)
		}
		.buttonStyle(PillButtonStyle(prominent: prominent))
	}
}

// MARK: Pages

private struct GeneralSettings: View {
	@AppStorage(ReadingSettings.autoCheckUpdatesKey) private var autoCheck = true
	@AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
	@AppStorage(MessageAppearance.adaptKey) private var adaptColors = true
	@AppStorage(ReadingSettings.markReadDelayKey) private var markReadDelay = 0
	@AppStorage(ReadingSettings.loadRemoteContentKey) private var loadRemote = true
	@State private var launchAtLogin = LaunchAtLogin.isEnabled

	var body: some View {
		SettingsGroup(title: "General") {
			SettingsToggle(title: "Open Mailflare at login", isOn: Binding(
				get: { launchAtLogin },
				set: { launchAtLogin = $0; if !LaunchAtLogin.set($0) { launchAtLogin = LaunchAtLogin.isEnabled } }
			))
			SettingsDivider()
			SettingsToggle(
				title: "Check for updates automatically",
				detail: "New versions come from the Mailflare releases on GitHub.",
				isOn: $autoCheck)
			SettingsDivider()
			SettingsPicker(
				title: "Appearance",
				options: AppAppearance.allCases.map { ($0.title, $0.rawValue) },
				selection: $appearance)
			SettingsDivider()
			SettingsToggle(
				title: "Adapt message colors in dark mode",
				detail: "Re-colors mail that has no dark styles of its own. The reader's color button overrides it per sender.",
				isOn: $adaptColors)
			SettingsDivider()
			SettingsPicker(
				title: "Mark as read",
				options: [("Immediately", 0), ("After 3 seconds", 3), ("After 10 seconds", 10), ("Never", -1)],
				selection: $markReadDelay)
			SettingsDivider()
			SettingsToggle(
				title: "Load remote content",
				detail: "Images, styles and fonts a message loads from the internet. Always blocked in Spam.",
				isOn: $loadRemote)
		}
		.onChange(of: appearance) { _, value in (AppAppearance(rawValue: value) ?? .system).apply() }
	}
}

private struct NotificationSettingsPage: View {
	@Environment(MailStore.self) private var store
	@AppStorage(NotificationSettings.enabledKey) private var enabled = true
	@AppStorage(NotificationSettings.previewsKey) private var previews = true
	@AppStorage(NotificationSettings.soundKey) private var sound = true
	@AppStorage(NotificationSettings.badgeKey) private var badge = true

	var body: some View {
		if store.notifier.authorization == .denied {
			SettingsGroup(title: "Permission") {
				SettingsRow {
					Text("Notifications for Mailflare are turned off in System Settings.")
						.font(Typography.meta).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
					Spacer(minLength: 8)
					Button("Open System Settings") {
						if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
					}
					.buttonStyle(.pill)
				}
			}
		}
		SettingsGroup(title: "New mail", footer: "Mailflare checks every account for new mail about once a minute while it is open.") {
			SettingsToggle(title: "Show notifications", detail: "For new mail in any account's inbox.", isOn: $enabled)
			SettingsDivider()
			SettingsToggle(title: "Show previews", detail: "Include the sender and subject. Off, a notification only says there is new mail.", isOn: $previews)
				.disabled(!enabled)
			SettingsDivider()
			SettingsToggle(title: "Play a sound", isOn: $sound)
				.disabled(!enabled)
			SettingsDivider()
			SettingsToggle(title: "Show unread count on the Dock icon", isOn: $badge)
		}
		.onChange(of: enabled) { _, on in if on { Task { await store.notifier.requestAuthorization() } } }
		.onChange(of: badge) { _, _ in store.updateBadge() }
		.task { await store.notifier.refreshAuthorization() }
	}
}

private struct AccountSettings: View {
	@Environment(MailStore.self) private var store

	var body: some View {
		SettingsGroup(title: "Accounts") {
			ForEach(Array(store.accountList.enumerated()), id: \.element.id) { index, account in
				if index > 0 { SettingsDivider() }
				SettingsRow {
					ProfileAvatar(key: AvatarCache.key(account: account.id), name: store.accountName(account), size: 32)
					VStack(alignment: .leading, spacing: 1) {
						Text(store.accountName(account)).font(Typography.bodySemibold).lineLimit(1)
						Text(account.email).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
					}
					Spacer(minLength: 8)
					Button("Sign Out") { store.signOut(account) }.buttonStyle(.pill)
				}
			}
		}
		WideButton(title: "Add Account", icon: .add) { store.showAddAccount = true }
	}
}

private struct LicenseSettings: View {
	@Environment(MailStore.self) private var store
	@Environment(\.openURL) private var openURL
	@State private var keyText = ""

	private var license: LicenseManager { store.license }

	var body: some View {
		SettingsGroup(title: "Mailflare Pro", footer: footer) {
			SettingsRow {
				Text("Plan").font(Typography.body)
				Spacer()
				Text(license.isPro ? "Pro" : "Free").font(Typography.body).foregroundStyle(.secondary)
			}
			if license.serverLicensed {
				SettingsDivider()
				SettingsRow {
					Text("Activated by").font(Typography.body)
					Spacer(minLength: 16)
					Text(store.account.map { "\($0.serverUrl)" } ?? "Your server")
						.font(Typography.meta).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
				}
			}
			if let masked = license.maskedKey {
				SettingsDivider()
				SettingsRow {
					Text("License key").font(Typography.body)
					Spacer(minLength: 16)
					Text(masked).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
				}
			}
		}
		if license.licenseKey != nil {
			if license.busy {
				ProgressView().controlSize(.small).frame(maxWidth: .infinity)
			} else {
				WideButton(title: "Deactivate This Mac") { Task { await license.deactivate() } }
			}
		} else {
			SettingsGroup(title: "Activate a license key") {
				SettingsRow {
					TextField("License key", text: $keyText)
						.textFieldStyle(.plain)
						.font(Typography.body)
						.onSubmit(activate)
					Button("Activate", action: activate)
						.buttonStyle(.pillProminent)
						.disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty || license.busy)
				}
			}
			if license.busy { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
			if !license.isPro {
				WideButton(title: "Buy Mailflare Pro", prominent: true) { openURL(LicenseManager.buyURL) }
			}
		}
		if let message = license.message {
			Text(message).font(Typography.meta).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
		}
	}

	private var footer: String {
		license.serverLicensed
			? "Your Mailflare server has an active license, so this app is activated while you are signed in to it."
			: "Signing in to a Mailflare account whose server has a Pro license activates the app automatically. Otherwise enter the key from your purchase email."
	}

	private func activate() {
		let key = keyText
		Task { await license.activate(key: key); if license.keyActive { keyText = "" } }
	}
}

private struct AboutSettings: View {
	@Environment(AppUpdater.self) private var updater

	var body: some View {
		SettingsGroup(title: "Mailflare") {
			SettingsRow {
				Text("Version").font(Typography.body)
				Spacer()
				Text(AppUpdater.currentVersion).font(Typography.body).foregroundStyle(.secondary)
			}
			SettingsDivider()
			SettingsRow {
				Text("Mail data").font(Typography.body)
				Spacer(minLength: 16)
				Text(MailStore.dataDirectoryDescription).font(Typography.meta).foregroundStyle(.secondary)
					.lineLimit(1).truncationMode(.middle).textSelection(.enabled)
			}
		}
		if let release = updater.available {
			switch updater.phase {
			case .idle:
				WideButton(title: "Update to \(release.version) and Restart", prominent: true) { Task { await updater.install() } }
			case .downloading, .installing:
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text(updater.phase == .downloading ? "Downloading \(release.version)…" : "Installing…").font(Typography.body)
				}
				.frame(maxWidth: .infinity).padding(.vertical, 7)
			case .failed(let message):
				Text(message).font(Typography.meta).foregroundStyle(.orange)
				WideButton(title: "Try Again") { Task { await updater.install() } }
			}
		} else {
			WideButton(title: "Check for Updates") { Task { await updater.check() } }
		}
	}
}
