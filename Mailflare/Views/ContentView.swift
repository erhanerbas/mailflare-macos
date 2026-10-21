import SwiftUI
import MailflareCore

struct RootView: View {
	@Environment(MailStore.self) private var store

	var body: some View {
		Group {
			if store.phase == .ready { ContentView() } else { AppTheme.background }
		}
		// With no account the mail window stays out of sight and only the sign-in window shows.
		.background(WindowVisibility(isVisible: store.phase == .ready))
		.onChange(of: store.phase, initial: true) { _, phase in
			if phase == .signedOut { SignInWindowController.shared.show(store: store) } else { SignInWindowController.shared.hide() }
		}
	}
}

/// The window: a translucent chrome holding the titlebar band and the sidebar, with
/// one rounded card set into it for the message list and the reader.
struct ContentView: View {
	@Environment(MailStore.self) private var store
	@State private var isSidebarVisible = true
	@AppStorage("listWidth") private var listWidth: Double = 330
	@AppStorage("sidebarWidth") private var sidebarWidth: Double = 264
	@State private var listWidthAtDragStart: Double?
	@State private var sidebarWidthAtDragStart: Double?
	@State private var searchTask: Task<Void, Never>?
	@FocusState private var searchFocused: Bool
	@State private var moreOpen = false

	var body: some View {
		@Bindable var store = store
		HStack(spacing: 0) {
			if isSidebarVisible {
				SidebarView()
					.frame(width: CGFloat(sidebarWidth))
					// A grab handle on the sidebar's trailing edge, over its empty gutter.
					.overlay(alignment: .trailing) {
						ResizeHandle { translation in
							if sidebarWidthAtDragStart == nil { sidebarWidthAtDragStart = sidebarWidth }
							sidebarWidth = min(380, max(220, (sidebarWidthAtDragStart ?? sidebarWidth) + Double(translation)))
						} onEnded: { sidebarWidthAtDragStart = nil }
					}
					.transition(.move(edge: .leading).combined(with: .opacity))
			}
			card
				.padding(.leading, isSidebarVisible ? 0 : WindowChromeMetrics.cardInset)
				.padding(.trailing, WindowChromeMetrics.cardInset)
				.padding(.bottom, WindowChromeMetrics.cardInset)
		}
		.padding(.top, WindowChromeMetrics.titlebarHeight)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background { ZStack { WindowVibrancy(); AppTheme.chrome } }
		.overlay(alignment: .topLeading) { titlebarLeading }
		.overlay(alignment: .topLeading) { if store.settingsPage == nil { titlebarSearch } }
		.overlay(alignment: .topTrailing) { if store.settingsPage == nil { titlebarTrailing } }
		.overlay(alignment: .bottomTrailing) { if store.settingsPage == nil { composeButton } }
		.ignoresSafeArea()
		// An empty toolbar keeps the unified titlebar band, which centres the traffic lights on
		// `titlebarRowCenter`; everything in the band is drawn by this view.
		.toolbar { ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) } }
		.toolbarBackground(.hidden, for: .windowToolbar)
		.sheet(item: $store.compose) { draft in ComposeView(draft: draft) }
		.sheet(isPresented: $store.showAddAccount) { SignInView(isPopup: true) }
		.sheet(item: $store.original) { message in OriginalMessageView(message: message) }
		.onChange(of: store.sidebar) { _, _ in store.sidebarChanged() }
		.onChange(of: store.unreadOnly) { _, _ in store.reload() }
		.onChange(of: store.searchText) { _, _ in
			searchTask?.cancel()
			searchTask = Task {
				try? await Task.sleep(for: .milliseconds(200))
				if !Task.isCancelled { store.reload() }
			}
		}
		.overlay(alignment: .top) {
			if let banner = store.banner {
				BannerView(title: banner) { store.banner = nil }
					.padding(.top, WindowChromeMetrics.titlebarHeight + 8)
					.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.overlay(alignment: .topTrailing) {
			if let toast = store.toast {
				ToastView(toast: toast)
					.padding(.top, WindowChromeMetrics.titlebarHeight + 8)
					.padding(.trailing, WindowChromeMetrics.cardInset + 12)
					.transition(.move(edge: .trailing).combined(with: .opacity))
			}
		}
		.animation(.easeInOut(duration: 0.2), value: store.banner)
		.animation(.easeInOut(duration: 0.2), value: store.toast)
	}

	// MARK: Card

	private var card: some View {
		Group {
			if let page = store.settingsPage {
				SettingsView(page: page)
			} else {
				HStack(spacing: 0) {
					MessageListView()
						.frame(width: CGFloat(listWidth))
					PaneDivider { translation in
						if listWidthAtDragStart == nil { listWidthAtDragStart = listWidth }
						listWidth = min(520, max(280, (listWidthAtDragStart ?? listWidth) + Double(translation)))
					} onEnded: { listWidthAtDragStart = nil }
					ReaderView()
						.frame(minWidth: 320, maxWidth: .infinity)
				}
			}
		}
		.background(AppTheme.background)
		// One loader bar along the top of the card: syncing, or a message body loading.
		.overlay(alignment: .top) {
			LoaderBar(isActive: store.isSyncing || (store.selectedID != nil && store.detail == nil))
		}
		.clipShape(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
	}

	// MARK: Titlebar

	private var titlebarLeading: some View {
		HStack(spacing: 2) {
			TitlebarIconButton(icon: .sidebar, help: "Toggle sidebar (⌃⌘S)") {
				withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible.toggle() }
			}
			.keyboardShortcut("s", modifiers: [.control, .command])
		}
		.padding(.leading, WindowChromeMetrics.sidebarToggleLeading)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - TitlebarIconButton.size / 2)
	}

	/// The search field, always shown over the message list and aligned with its leading edge.
	/// With the sidebar hidden it starts past the sidebar toggle instead.
	private var titlebarSearch: some View {
		@Bindable var store = store
		let listLeading = isSidebarVisible ? CGFloat(sidebarWidth) : 0
		let clearOfToggle = WindowChromeMetrics.sidebarToggleLeading + TitlebarIconButton.size + 8
		let leading = max(listLeading, clearOfToggle)
		let width = max(160, listLeading + CGFloat(listWidth) - leading)
		return HStack(spacing: 6) {
			HIcon(.search, size: 14).foregroundStyle(.secondary)
			TextField("Search", text: $store.searchText)
				.textFieldStyle(.plain).font(Typography.body)
				.focused($searchFocused)
				.onExitCommand { store.searchText = ""; searchFocused = false }
			if !store.searchText.isEmpty {
				Button { store.searchText = "" } label: { HIcon(.close, size: 12) }
					.buttonStyle(.light).foregroundStyle(.secondary)
			}
		}
		.padding(.horizontal, 10)
		.frame(width: width, height: 28)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.contentShape(Rectangle())
		.onTapGesture { searchFocused = true }
		// ⌥⌘F focuses the field.
		.background { Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: [.command, .option]).opacity(0).frame(width: 0, height: 0) }
		.padding(.leading, leading)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - 14)
	}

	/// The actions that apply to the selected message, on the card's trailing edge, grouped by
	/// separators. Nothing shows without a selection.
	private var titlebarTrailing: some View {
		let message = store.selectedMessage
		let role = message.map { store.role(of: $0) } ?? nil
		let isDraft = role == "drafts"
		return HStack(spacing: 8) {
			if let message {
				if !isDraft {
					TitlebarIconButton(icon: .reply, help: "Reply (⌘R)") { store.reply(to: message.id, all: false) }
						.keyboardShortcut("r")
					if store.canReplyAll {
						TitlebarIconButton(icon: .replyAll, help: "Reply All (⇧⌘R)") { store.reply(to: message.id, all: true) }
							.keyboardShortcut("r", modifiers: [.command, .shift])
					}
					TitlebarIconButton(icon: .forward, help: "Forward (⇧⌘F)") { store.forward(message.id) }
						.keyboardShortcut("f", modifiers: [.command, .shift])
					separator
				}
				if role != "archive" && !isDraft {
					TitlebarIconButton(icon: .archive, help: "Archive (⌃⌘A)") { store.archive(message.id) }
						.keyboardShortcut("a", modifiers: [.command, .control])
				}
				TitlebarIconButton(icon: .trash, help: "Move to Trash (⌘⌫)") { store.trash(message.id) }
					.keyboardShortcut(.delete, modifiers: .command)
				if role != "junk" && role != "sent" && !isDraft {
					TitlebarIconButton(icon: .junk, help: "Move to Junk (⇧⌘J)") { store.junk(message.id) }
						.keyboardShortcut("j", modifiers: [.command, .shift])
				}
				if !isDraft {
					separator
					flagMenu(message)
					moreMenu(message, role: role)
				}
			}
		}
		.padding(.trailing, WindowChromeMetrics.cardInset + 8)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - TitlebarIconButton.size / 2)
	}

	/// New Message, as the window's primary action, floating over the reader's bottom-trailing corner.
	private var composeButton: some View {
		Button { store.newMessage() } label: {
			HStack(spacing: 6) {
				HIcon(.compose, size: 15)
				Text(store.minimizedDraft == nil ? "Compose" : "Drafting…")
			}
			.padding(.horizontal, 4)
			.padding(.vertical, 3)
		}
		.buttonStyle(.pillProminent)
		.shadow(color: AppTheme.composerShadow, radius: 10, y: 4)
		.help(store.minimizedDraft == nil ? "New Message (⌘N)" : "Continue your draft (⌘N)")
		.padding(.trailing, WindowChromeMetrics.cardInset + 20)
		.padding(.bottom, WindowChromeMetrics.cardInset + 20)
	}

	private var separator: some View {
		Rectangle().fill(AppTheme.cardStroke).frame(width: 1, height: 16).padding(.horizontal, 8)
	}

	/// The "…" button and its dropdown: the Settings dropdown's card, opening below the button with
	/// its right edge on the button's.
	private func moreMenu(_ message: MessageSummary, role: String?) -> some View {
		let unsubscribe = store.detail.flatMap { $0.summary.id == message.id ? UnsubscribeLink.find(in: $0.html) : nil }
		func choose(_ action: () -> Void) {
			withAnimation(.snappy(duration: 0.2)) { moreOpen = false }
			action()
		}
		return TitlebarIconButton(icon: .more, help: "More", isActive: moreOpen) {
			withAnimation(.snappy(duration: 0.2)) { moreOpen.toggle() }
		}
		.overlay(alignment: .topTrailing) {
			if moreOpen {
				DropdownCard(width: 210, anchor: .topTrailing) {
					DropdownRow(label: "Unsubscribe", icon: .unsubscribe, isEnabled: unsubscribe != nil) {
						choose { if let unsubscribe { NSWorkspace.shared.open(unsubscribe) } }
					}
					DropdownRow(label: "Block Contact", icon: .block) { choose { store.block(message.sender, messageID: message.id) } }
					DropdownRow(label: "Show Original", icon: .sourceCode) { choose { store.original = message } }
					DropdownDivider()
					DropdownLabel(title: "Move to")
					DropdownRow(label: "Archive", icon: .archive, isEnabled: role != "archive") { choose { store.archive(message.id) } }
					DropdownRow(label: "Spam", icon: .junk, isEnabled: role != "junk") { choose { store.junk(message.id) } }
					DropdownRow(label: "Trash", icon: .trash, isEnabled: role != "trash") { choose { store.trash(message.id) } }
				}
				.offset(y: TitlebarIconButton.size + 6)
			}
		}
		.clickAway(isActive: moreOpen) { withAnimation(.snappy(duration: 0.2)) { moreOpen = false } }
		.onChange(of: message.id) { _, _ in moreOpen = false }
	}

	private func flagMenu(_ message: MessageSummary?) -> some View {
		TitlebarMenu(icon: .flag, help: "Flag", isEnabled: message != nil, primaryAction: {
			if let message { store.toggleFlag(message.id) }
		}) {
			Button(message?.flagged == true ? "Remove Flag" : "Flag") { if let message { store.toggleFlag(message.id) } }
			Button(message?.seen == true ? "Mark as Unread" : "Mark as Read") {
				if let message { store.setRead(message.id, !message.seen) }
			}
			if store.supportsReminders {
				Divider()
				Button("Remind Me Tomorrow") {
					if let message { store.remind(message.id, at: Calendar.current.date(byAdding: .day, value: 1, to: .now)) }
				}
				if let message, store.reminders[message.id] != nil {
					Button("Clear Reminder") { store.remind(message.id, at: nil) }
				}
			}
			if store.supportsVIPs {
				Divider()
				Button(store.isVIP(message?.sender) ? "Remove Sender from VIPs" : "Add Sender to VIPs") {
					if let sender = message?.sender { store.toggleVIP(sender) }
				}
				.disabled(message == nil)
			}
		}
	}
}
