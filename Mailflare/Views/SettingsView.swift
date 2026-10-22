import SwiftUI
import MailflareCore
import UniformTypeIdentifiers

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
					case .ai: AISettingsPage()
					case .license: LicenseSettings()
					case .support: SupportSettings()
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
	/// For lists fetched on demand: shown instead of the options, as skeleton rows, while they load.
	var isLoading = false
	/// Called each time the dropdown opens, so a list can start loading then.
	var onOpen: (() -> Void)?
	var maxHeight: CGFloat = 280
	/// The label when `selection` is not among the options (yet).
	var fallbackLabel: String?
	@State private var isOpen = false
	@State private var isHovering = false
	@State private var query = ""

	/// The options whose label contains what was typed, all of them when nothing was.
	private var matches: [Int] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		guard !q.isEmpty else { return Array(options.indices) }
		return options.indices.filter { options[$0].label.lowercased().contains(q) }
	}

	private var selectedIndex: Int? { options.firstIndex { $0.value == selection } }

	private var currentLabel: String { options.first { $0.value == selection }?.label ?? fallbackLabel ?? "" }

	var body: some View {
		SettingsRow {
			Text(title).font(Typography.body)
			Spacer(minLength: 12)
			Button {
				withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() }
				if isOpen { onOpen?() }
			} label: {
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
		.zIndex(isOpen ? 10 : 0)
		.preference(key: OpenDropdownKey.self, value: isOpen)
		.onChange(of: isOpen) { _, _ in query = "" }
	}

	private var dropdown: some View {
		DropdownCard(width: 190) {
			if isLoading {
				DropdownScroll(maxHeight: maxHeight) {
					ForEach(0..<5, id: \.self) { _ in
						SkeletonBar(height: 12).padding(.horizontal, 10).padding(.vertical, 9)
					}
				}
			} else {
				// Worked out once here: asking per row would scan the whole list for every row.
				let shown = matches
				if options.count > 8 {
					DropdownSearchField(text: $query) {
						if let first = shown.first { selection = options[first].value; withAnimation(.snappy(duration: 0.2)) { isOpen = false } }
					}
				}
				DropdownScroll(maxHeight: maxHeight, target: query.isEmpty ? selectedIndex.map(String.init) : nil) {
					if shown.isEmpty { DropdownNoResults() }
					ForEach(shown, id: \.self) { index in
						DropdownRow(label: options[index].label, isSelected: options[index].value == selection) {
							selection = options[index].value
							withAnimation(.snappy(duration: 0.2)) { isOpen = false }
						}
						.id(String(index))
					}
				}
			}
		}
	}
}

/// A model choice. With one provider the dropdown lists its models; with several it lists the
/// providers first, and choosing one swaps the list for that provider's models.
private struct ModelPickerRow: View {
	var title: String
	var providers: [AIProviderConfig]
	var selection: AISettings.ModelChoice?
	/// When set, a first row that clears the choice (nil), labelled with this.
	var defaultLabel: String?
	var onSelect: (AISettings.ModelChoice?) -> Void

	@State private var isOpen = false
	@State private var isHovering = false
	@State private var drilled: String?
	@State private var query = ""

	private var multiple: Bool { providers.count > 1 }

	private var currentLabel: String {
		guard let selection else { return defaultLabel ?? "" }
		let name = providers.first { $0.id == selection.providerID }?.name
		return multiple ? "\(name.map { $0 + " · " } ?? "")\(selection.model)" : selection.model
	}

	var body: some View {
		SettingsRow {
			Text(title).font(Typography.body)
			Spacer(minLength: 12)
			Button {
				withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() }
			} label: {
				HStack(spacing: 6) {
					Text(currentLabel).font(Typography.body).lineLimit(1).truncationMode(.middle)
						.frame(maxWidth: 300, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
					HIcon(.chevronDown, size: 12).foregroundStyle(.secondary).rotationEffect(.degrees(isOpen ? 180 : 0))
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
			.clickAway(isActive: isOpen) { close() }
		}
		.zIndex(isOpen ? 10 : 0)
		.preference(key: OpenDropdownKey.self, value: isOpen)
		.onChange(of: isOpen) { _, _ in drilled = nil; query = "" }
	}

	private func close() { withAnimation(.snappy(duration: 0.2)) { isOpen = false } }

	private func choose(_ choice: AISettings.ModelChoice?) {
		onSelect(choice)
		close()
	}

	private var dropdown: some View {
		DropdownCard(width: 240) {
			if let defaultLabel, drilled == nil {
				DropdownRow(label: defaultLabel, isSelected: selection == nil) { choose(nil) }
			}
			if multiple && drilled == nil {
				ForEach(providers) { provider in
					DropdownRow(label: provider.name, isSelected: selection?.providerID == provider.id, trailing: .chevronRight) {
						withAnimation(.snappy(duration: 0.2)) { query = ""; drilled = provider.id }
					}
				}
			} else if let provider = providers.first(where: { $0.id == drilled }) ?? (multiple ? nil : providers.first) {
				let q = query.trimmingCharacters(in: .whitespaces).lowercased()
				let models = q.isEmpty ? provider.choices : provider.choices.filter { $0.lowercased().contains(q) }
				if multiple {
					DropdownRow(label: provider.name, icon: .arrowLeft) { withAnimation(.snappy(duration: 0.2)) { drilled = nil } }
					DropdownDivider()
				}
				if provider.choices.count > 8 {
					DropdownSearchField(text: $query) {
						if let first = models.first { choose(.init(providerID: provider.id, model: first)) }
					}
				}
				let current = selection?.providerID == provider.id ? selection?.model : nil
				DropdownScroll(maxHeight: 220, target: q.isEmpty ? current : nil) {
					if models.isEmpty { DropdownNoResults() }
					ForEach(models, id: \.self) { model in
						DropdownRow(label: model, isSelected: model == current) { choose(.init(providerID: provider.id, model: model)) }
							.id(model)
					}
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
	/// The account whose page is open; nil shows the list. The page slides in from the right.
	@State private var openID: String?

	var body: some View {
		ZStack(alignment: .top) {
			if let account = store.accountList.first(where: { $0.id == openID }) {
				AccountDetail(account: account) { withAnimation(.snappy(duration: 0.25)) { openID = nil } }
					.transition(.move(edge: .trailing).combined(with: .opacity))
			} else {
				list.transition(.move(edge: .leading).combined(with: .opacity))
			}
		}
		.frame(maxWidth: .infinity, alignment: .top)
		.clipped()
	}

	private var list: some View {
		VStack(alignment: .leading, spacing: 22) {
			SettingsGroup(title: "Accounts") {
				ForEach(Array(store.accountList.enumerated()), id: \.element.id) { index, account in
					if index > 0 { SettingsDivider() }
					Button { withAnimation(.snappy(duration: 0.25)) { openID = account.id } } label: {
						SettingsRow {
							ProfileAvatar(key: AvatarCache.key(account: account.id), name: store.accountName(account), size: 32)
							VStack(alignment: .leading, spacing: 1) {
								Text(store.accountName(account)).font(Typography.bodySemibold).lineLimit(1)
								Text(account.email).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
							}
							Spacer(minLength: 8)
							HIcon(.chevronRight, size: 12).foregroundStyle(.secondary)
						}
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
				}
			}
			WideButton(title: "Add Account", icon: .add) { store.showAddAccount = true }
		}
	}
}

/// One account: its picture, name and signature.
private struct AccountDetail: View {
	@Environment(MailStore.self) private var store
	var account: Account
	var back: () -> Void

	@State private var name = ""
	@State private var signature = ""
	@State private var loaded = false
	@State private var saving = false
	@State private var note: String?

	private var profiles: AccountProfiles { store.profiles }
	private var key: String { AvatarCache.key(account: account.id) }
	private var remote: AccountProfiles.Remote? { profiles.remote[account.id] }
	private var savedName: String { store.accountName(account) }
	private var savedSignature: String { profiles.signature(account.id) }

	private var isDirty: Bool {
		name.trimmingCharacters(in: .whitespacesAndNewlines) != savedName
			|| signature.trimmingCharacters(in: .whitespacesAndNewlines) != savedSignature
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			Button(action: back) {
				HStack(spacing: 6) {
					HIcon(.arrowLeft, size: 13)
					Text("Accounts").font(Typography.body)
				}
				.foregroundStyle(.secondary)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)

			HStack(spacing: 16) {
				ProfileAvatar(key: key, name: name.isEmpty ? savedName : name, size: 72)
				VStack(alignment: .leading, spacing: 8) {
					Text(account.email).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
					HStack(spacing: 8) {
						Button("Choose Picture…", action: choosePicture).buttonStyle(.pill)
						if store.avatars.hasLocal(key) {
							Button("Remove") { store.avatars.removeLocal(key: key); store.loadAvatars(for: account) }.buttonStyle(.pill)
						}
					}
				}
				Spacer(minLength: 0)
			}

			SettingsGroup(title: "Profile") {
				SettingsRow {
					Text("Name").font(Typography.body)
					Spacer(minLength: 12)
					TextField("Your name", text: $name)
						.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
				}
				SettingsDivider()
				SettingsRow {
					Text("Email").font(Typography.body)
					Spacer(minLength: 12)
					Text(account.email).font(Typography.body).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
				}
			}

			SettingsGroup(title: "Signature", footer: signatureFooter) {
				TextEditor(text: $signature)
					.font(Typography.body)
					.scrollContentBackground(.hidden)
					.frame(minHeight: 96)
					.padding(.vertical, 8)
			}

			HStack(spacing: 8) {
				if saving { ProgressView().controlSize(.small) }
				Spacer()
				Button("Revert") { fill() }.buttonStyle(.pill).disabled(!isDirty || saving)
				Button("Save", action: save).buttonStyle(.pillProminent).disabled(!isDirty || saving)
			}
			if let note {
				Text(note).font(Typography.meta).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
			}

			WideButton(title: "Sign Out") { store.signOut(account) }
		}
		.task {
			fill()
			await profiles.refresh(account)
			// Take the server's values unless the user has started typing.
			if !isDirty { fill() }
			loaded = true
		}
	}

	private var signatureFooter: String {
		var text = profiles.hasSignature(account.id)
			? "Added to new messages, replies and forwards from this account."
			: "No signature is set, so “\(AccountProfiles.defaultSignature)” is added to new messages. Write your own to replace it."
		if remote?.editable == false { text += " Your server doesn't allow edits, so changes stay on this Mac." }
		return text
	}

	private func fill() {
		name = savedName
		signature = savedSignature
		note = nil
	}

	private func save() {
		saving = true; note = nil
		let name = name, signature = signature
		Task {
			note = await profiles.save(account, name: name, signature: signature)
			saving = false
			fill()
			if let kept = note { note = kept }
		}
	}

	private func choosePicture() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.image]
		panel.allowsMultipleSelection = false
		panel.message = "Choose a picture for \(savedName)"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		if !store.avatars.setLocal(key: key, from: url) { note = "That file couldn't be read as a picture." }
	}
}

private struct AISettingsPage: View {
	@Environment(MailStore.self) private var store
	/// Model lists fetched on this page, by service address and key. They are kept while the page is
	/// open and dropped when another settings page is shown.
	@State private var modelCache: [String: [String]] = [:]
	/// The provider being added or edited, with the key typed for it.
	@State private var editing: AIProviderConfig?
	@State private var editingIsNew = false
	@State private var keyText = ""

	private var ai: AISettings { store.ai }

	var body: some View {
		if ai.isConfigured { modelsGroup }
		if ai.providers.isEmpty && editing == nil {
			SettingsGroup(title: "AI Providers", footer: "Add a provider to turn on the assistant. The assistant sends the mail it reads to the provider you choose.") {
				SettingsRow {
					Text("No providers yet").font(Typography.body).foregroundStyle(.secondary)
					Spacer()
				}
			}
		} else if !ai.providers.isEmpty {
			SettingsGroup(title: "AI Providers", footer: "Keys are stored in your Keychain. Switch provider and model from the assistant panel.") {
				ForEach(Array(ai.providers.enumerated()), id: \.element.id) { index, provider in
					if index > 0 { SettingsDivider() }
					SettingsRow {
						VStack(alignment: .leading, spacing: 1) {
							HStack(spacing: 6) {
								Text(provider.name).font(Typography.bodySemibold).lineLimit(1)
								if provider.id == ai.active?.id { Text("In use").font(Typography.meta).foregroundStyle(.secondary) }
							}
							Text(ai.isReady(provider) ? provider.model : "Needs setup")
								.font(Typography.meta).foregroundStyle(ai.isReady(provider) ? Color.secondary : Color.orange).lineLimit(1)
						}
						Spacer(minLength: 8)
						Button("Edit") { edit(provider, isNew: false) }.buttonStyle(.pill)
						Button("Remove") { if editing?.id == provider.id { editing = nil }; ai.remove(provider.id) }.buttonStyle(.pill)
					}
				}
			}
		}
		if editing != nil {
			ProviderEditor(config: Binding(get: { editing ?? AIProviderConfig(preset: .openai) }, set: { editing = $0 }),
						   key: $keyText, isNew: editingIsNew, cache: $modelCache) {
				if let config = editing { ai.save(config, key: keyText) }
				editing = nil
			} cancel: { editing = nil }
		} else {
			WideButton(title: "Add Provider", icon: .add) { edit(AIProviderConfig(preset: .openai), isNew: true) }
		}
	}

	private var modelsGroup: some View {
		let activeChoice = ai.active.map { AISettings.ModelChoice(providerID: $0.id, model: $0.model) }
		return SettingsGroup(title: "Models", footer: "AI Writer follows the assistant's model unless you pick one for it. Each custom prompt is added to that feature's instructions.") {
			ModelPickerRow(
				title: "AI Chat", providers: ai.readyProviders, selection: activeChoice,
				onSelect: { if let c = $0 { ai.select(providerID: c.providerID, model: c.model) } })
			SettingsDivider()
			promptField("Custom prompt for AI Chat, such as “Be concise and sign off with Thanks, Sam”",
						text: Binding(get: { ai.instructions }, set: { ai.instructions = $0 }))
			SettingsDivider()
			ModelPickerRow(
				title: "AI Writer", providers: ai.readyProviders, selection: ai.writerChoice,
				defaultLabel: "Same as AI Chat", onSelect: { ai.selectWriter($0) })
			SettingsDivider()
			promptField("Custom prompt for AI Writer, such as “Friendly, short paragraphs, no jargon”",
						text: Binding(get: { ai.writerInstructions }, set: { ai.writerInstructions = $0 }))
		}
	}

	private func promptField(_ placeholder: String, text: Binding<String>) -> some View {
		TextField(placeholder, text: text, axis: .vertical)
			.textFieldStyle(.plain).font(Typography.body)
			.lineLimit(2...6)
			.padding(.vertical, 12)
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func edit(_ config: AIProviderConfig, isNew: Bool) {
		keyText = ai.apiKey(for: config.id)
		editingIsNew = isNew
		editing = config
	}
}

/// The form for one provider: its service, address, key and model.
private struct ProviderEditor: View {
	@Environment(MailStore.self) private var store
	@Binding var config: AIProviderConfig
	@Binding var key: String
	var isNew: Bool
	@Binding var cache: [String: [String]]
	var save: () -> Void
	var cancel: () -> Void

	@State private var loading = false
	@State private var error: String?
	/// Listing failed, so the model is typed by hand.
	@State private var typeModel = false

	private var cacheKey: String { "\(config.baseURLString)|\(key.trimmingCharacters(in: .whitespaces))" }
	private var canList: Bool { config.baseURL != nil && (!config.preset.needsKey || !key.trimmingCharacters(in: .whitespaces).isEmpty) }

	private var canSave: Bool {
		config.baseURL != nil && !config.model.trimmingCharacters(in: .whitespaces).isEmpty
			&& (!config.preset.needsKey || !key.trimmingCharacters(in: .whitespaces).isEmpty)
	}

	var body: some View {
		SettingsGroup(title: isNew ? "New provider" : "Edit provider") {
			SettingsPicker(
				title: "Service",
				options: AIProviderPreset.allCases.map { ($0.title, $0) },
				selection: Binding(get: { config.preset }, set: { changePreset($0) })
			)
			SettingsDivider()
			SettingsRow {
				Text("Name").font(Typography.body)
				Spacer(minLength: 12)
				TextField("Name", text: $config.name)
					.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
			}
			if config.preset == .custom {
				SettingsDivider()
				SettingsRow {
					Text("Base URL").font(Typography.body)
					Spacer(minLength: 12)
					TextField("https://api.example.com/v1", text: $config.customBaseURL)
						.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
				}
			}
			if config.preset.needsKey {
				SettingsDivider()
				SettingsRow {
					Text("API key").font(Typography.body)
					Spacer(minLength: 12)
					SecureField("Paste your key", text: $key)
						.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
				}
			}
			SettingsDivider()
			if typeModel || !canList {
				SettingsRow {
					Text("Model").font(Typography.body)
					Spacer(minLength: 12)
					TextField(config.preset.defaultModel.isEmpty ? "Model name" : config.preset.defaultModel, text: $config.model)
						.textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Typography.body)
				}
			} else {
				// Opening it fetches the list the first time; later opens reuse what was fetched.
				SettingsPicker(
					title: "Model", options: config.choices.map { ($0, $0) }, selection: $config.model,
					isLoading: config.models.isEmpty, onOpen: { Task { await loadIfNeeded() } },
					maxHeight: 180, fallbackLabel: config.model
				)
			}
		}
		if let error {
			Text(error).font(Typography.meta).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
		} else if !config.models.isEmpty {
			Text("\(config.models.count) models available.").font(Typography.meta).foregroundStyle(.secondary)
		}
		HStack(spacing: 8) {
			Button { Task { await loadModels() } } label: {
				if loading { ProgressView().controlSize(.small) } else { Text("Load Models") }
			}
			.buttonStyle(.pill)
			.disabled(loading || config.baseURL == nil || (config.preset.needsKey && key.trimmingCharacters(in: .whitespaces).isEmpty))
			Spacer()
			Button("Cancel", action: cancel).buttonStyle(.pill)
			Button("Save", action: save).buttonStyle(.pillProminent).disabled(!canSave)
		}
	}

	private func changePreset(_ preset: AIProviderPreset) {
		let previous = config.preset
		config.preset = preset
		config.models = []
		typeModel = false
		error = nil
		if config.name == previous.title || config.name.isEmpty { config.name = preset.title }
		config.model = preset.defaultModel
	}

	/// Uses the list fetched earlier on this page, or fetches it.
	private func loadIfNeeded() async {
		guard config.models.isEmpty, !loading else { return }
		if let cached = cache[cacheKey] { config.models = cached; return }
		await loadModels()
	}

	private func loadModels() async {
		guard let baseURL = config.baseURL else { return }
		loading = true; error = nil
		defer { loading = false }
		do {
			let models = try await AIClient.listModels(baseURL: baseURL, apiKey: key.trimmingCharacters(in: .whitespaces))
			if models.isEmpty { error = "The provider returned no models."; typeModel = true; return }
			cache[cacheKey] = models
			typeModel = false
			config.models = models
			if !models.contains(config.model) { config.model = models.first(where: { $0 == config.preset.defaultModel }) ?? models[0] }
		} catch {
			self.error = error.localizedDescription
			typeModel = true
		}
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

private struct SupportSettings: View {
	private static let issuesURL = URL(string: "https://github.com/hieunc229/mailflare-macos/issues")!

	var body: some View {
		SettingsGroup(title: "Need help?", footer: "Include your macOS version, the Mailflare version (see About) and, for a bug, the steps that cause it. Please leave out passwords, API keys and private mail.") {
			VStack(alignment: .leading, spacing: 6) {
				Text("Found a bug, or want a feature?").font(Typography.bodySemibold)
				Text("Create an issue on GitHub and describe what happened or what you would like. Every report is read there.")
					.font(Typography.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
			.padding(.vertical, 12)
			SettingsDivider()
			SettingsRow {
				Text("Issues").font(Typography.body)
				Spacer(minLength: 16)
				Text("github.com/hieunc229/mailflare-macos/issues").font(Typography.meta).foregroundStyle(.secondary)
					.lineLimit(1).truncationMode(.middle).textSelection(.enabled)
			}
		}
		WideButton(title: "Create a GitHub Issue", icon: .support, prominent: true) { NSWorkspace.shared.open(Self.issuesURL) }
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
