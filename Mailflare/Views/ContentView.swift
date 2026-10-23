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
	@State private var windowWidth: CGFloat = 0
	/// The sidebar shown over the content, when the window is too narrow to dock it.
	@State private var drawerOpen = false
	@AppStorage("listWidth") private var listWidth: Double = 330
	@AppStorage("sidebarWidth") private var sidebarWidth: Double = 264
	@AppStorage(NotificationSettings.enabledKey) private var notificationsOn = true
	@State private var listWidthAtDragStart: Double?
	@State private var sidebarWidthAtDragStart: Double?
	@State private var searchTask: Task<Void, Never>?
	@FocusState private var searchFocused: Bool
	@State private var moreOpen = false
	@Environment(\.colorScheme) private var colorScheme
	@AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

	/// Dark Glass: the columns stay light inside the dark window.
	private var columnScheme: ColorScheme? { (AppAppearance(rawValue: appearance) ?? .system).lightColumns ? .light : nil }

	var body: some View {
		@Bindable var store = store
		HStack(spacing: 0) {
			if layout.showSidebar {
				SidebarView()
					.frame(width: layout.sidebarW)
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
				.padding(.leading, layout.showSidebar ? 0 : WindowChromeMetrics.cardInset)
				.padding(.trailing, WindowChromeMetrics.cardInset)
				.padding(.bottom, WindowChromeMetrics.cardInset)
			if store.ai.isConfigured && layout.chatDocked {
				// Always mounted so closing can play out: the column's width animates and clips the panel.
				AIChatPanel()
					.environment(\.colorScheme, columnScheme ?? colorScheme)
					.padding(.bottom, WindowChromeMetrics.cardInset)
					.frame(width: AIChatPanel.width + WindowChromeMetrics.cardInset, alignment: .leading)
					.frame(width: store.chatVisible ? AIChatPanel.width + WindowChromeMetrics.cardInset : 0, alignment: .leading)
					.clipped()
					.allowsHitTesting(store.chatVisible)
			}
		}
		.padding(.top, WindowChromeMetrics.titlebarHeight)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background { ZStack { WindowVibrancy(); AppTheme.chrome } }
		.overlay(alignment: .topLeading) { sidebarDrawer }
		.overlay(alignment: .topTrailing) { floatingChat }
		.overlay(alignment: .topLeading) { titlebarLeading }
		.overlay(alignment: .topLeading) { if store.settingsPage == nil && !(layout.single && store.selectedID != nil) { titlebarSearch } }
		.overlay(alignment: .topTrailing) { if store.settingsPage == nil { titlebarTrailing } }
		.overlay(alignment: .topTrailing) { if store.ai.isConfigured { assistantToggle } }
		.overlay(alignment: .bottomTrailing) { if store.settingsPage == nil { composeButton } }
		.animation(.easeInOut(duration: 0.2), value: store.chatOpen)
		.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
		.onChange(of: layout.showSidebar) { _, docked in if docked { drawerOpen = false } }
		.onChange(of: store.sidebar) { _, _ in drawerOpen = false }
		.onChange(of: store.settingsPage) { _, _ in drawerOpen = false }
		.ignoresSafeArea()
		// An empty toolbar keeps the unified titlebar band, which centres the traffic lights on
		// `titlebarRowCenter`; everything in the band is drawn by this view.
		.toolbar { ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) } }
		.toolbarBackground(.hidden, for: .windowToolbar)
		.sheet(item: $store.compose) { draft in ComposeView(draft: draft) }
		.sheet(isPresented: $store.showAddAccount) { SignInView(isPopup: true) }
		.sheet(item: $store.original) { message in OriginalMessageView(message: message) }
	.sheet(item: $store.inboxViewEditor) { view in
		InboxViewEditor(view: view, isNew: !store.inboxViews.contains { $0.id == view.id })
	}
		.sheet(item: $store.customTabEditor) { tab in
			CustomTabEditor(tab: tab, isNew: !store.customTabs.contains { $0.id == tab.id })
		}
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

	// MARK: Layout

	/// Which columns fit, and how wide. The window never overflows: columns first squeeze to their
	/// minimum widths, then close in this order: sidebar, message list. With only the reader left,
	/// the assistant floats over it instead of docking.
	struct PaneLayout {
		var showSidebar: Bool
		var sidebarW: CGFloat
		var showList: Bool
		var listW: CGFloat
		var chatDocked: Bool
		/// One column at a time: the list, or the open message.
		var single: Bool { !showList }
	}

	private static let sidebarMin: CGFloat = 220
	private static let listMin: CGFloat = 280
	private static let readerMin: CGFloat = 320

	private var layout: PaneLayout { computeLayout(sidebar: isSidebarVisible) }

	private func computeLayout(sidebar wantSidebar: Bool) -> PaneLayout {
		let width = windowWidth > 0 ? windowWidth : 1180
		let chat = store.chatVisible ? AIChatPanel.width + WindowChromeMetrics.cardInset : 0
		let space = width - WindowChromeMetrics.cardInset * 2 - Self.readerMin - chat
		let s = CGFloat(sidebarWidth), l = CGFloat(listWidth)
		if wantSidebar, space >= Self.sidebarMin + Self.listMin {
			if s + l <= space { return PaneLayout(showSidebar: true, sidebarW: s, showList: true, listW: l, chatDocked: true) }
			let slack = (s - Self.sidebarMin) + (l - Self.listMin)
			let t = slack > 0 ? min(1, (space - Self.sidebarMin - Self.listMin) / slack) : 0
			return PaneLayout(showSidebar: true, sidebarW: Self.sidebarMin + (s - Self.sidebarMin) * t,
							  showList: true, listW: Self.listMin + (l - Self.listMin) * t, chatDocked: true)
		}
		if space >= Self.listMin {
			return PaneLayout(showSidebar: false, sidebarW: s, showList: true, listW: min(l, space), chatDocked: true)
		}
		return PaneLayout(showSidebar: false, sidebarW: s, showList: false, listW: 0, chatDocked: false)
	}

	/// Docks or undocks the sidebar when it fits; otherwise slides it over the content and back.
	private func toggleSidebar() {
		withAnimation(.easeInOut(duration: 0.2)) {
			if drawerOpen { drawerOpen = false }
			else if isSidebarVisible && layout.showSidebar { isSidebarVisible = false }
			else if !isSidebarVisible && computeLayout(sidebar: true).showSidebar { isSidebarVisible = true }
			else { drawerOpen = true }
		}
	}

	/// The sidebar over the content, for windows too narrow to dock it. A click outside closes it.
	@ViewBuilder
	private var sidebarDrawer: some View {
		if drawerOpen && !layout.showSidebar {
			ZStack(alignment: .topLeading) {
				Color.black.opacity(0.001).contentShape(Rectangle())
					.onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { drawerOpen = false } }
				SidebarView()
					.frame(width: min(CGFloat(sidebarWidth), max(200, windowWidth - 60)))
					.frame(maxHeight: .infinity)
					.background { ZStack { Rectangle().fill(.regularMaterial); AppTheme.chrome } }
					.overlay(alignment: .trailing) { Rectangle().fill(AppTheme.cardStroke).frame(width: 1) }
					.shadow(color: AppTheme.composerShadow, radius: 18, x: 4)
					.padding(.top, WindowChromeMetrics.titlebarHeight)
					.transition(.move(edge: .leading))
			}
		}
	}

	/// The assistant over the reader, when only one column fits.
	@ViewBuilder
	private var floatingChat: some View {
		if store.ai.isConfigured && store.chatVisible && !layout.chatDocked {
			AIChatPanel()
				.environment(\.colorScheme, columnScheme ?? colorScheme)
				.shadow(color: AppTheme.composerShadow, radius: 18, x: -4)
				.padding(.top, WindowChromeMetrics.titlebarHeight)
				.padding(.trailing, WindowChromeMetrics.cardInset)
				.padding(.bottom, WindowChromeMetrics.cardInset)
				.transition(.move(edge: .trailing).combined(with: .opacity))
		}
	}

	// MARK: Card

	private var card: some View {
		Group {
			if let page = store.settingsPage {
				SettingsView(page: page)
			} else if layout.single {
				// One column: the list until a message is chosen, then the message.
				if store.selectedID == nil { MessageListView() } else { ReaderView() }
			} else {
				HStack(spacing: 0) {
					MessageListView()
						.frame(width: layout.listW)
					PaneDivider { translation in
						if listWidthAtDragStart == nil { listWidthAtDragStart = listWidth }
						listWidth = min(520, max(280, (listWidthAtDragStart ?? listWidth) + Double(translation)))
					} onEnded: { listWidthAtDragStart = nil }
					ReaderView()
						.frame(minWidth: Self.readerMin, maxWidth: .infinity)
				}
			}
		}
		.environment(\.colorScheme, columnScheme ?? colorScheme)
		.background(AppTheme.background)
		// One loader bar along the top of the card: syncing, or a message body loading.
		.overlay(alignment: .top) {
			LoaderBar(isActive: store.isSyncing || (store.selectedID != nil && store.detail == nil))
		}
		.clipShape(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
	}

	// MARK: Titlebar

	/// macOS has notifications off for Mailflare.
	private var blockedBySystem: Bool { store.notifier.authorization == .denied }

	private var titlebarLeading: some View {
		HStack(spacing: 2) {
			TitlebarIconButton(icon: .sidebar, help: "Toggle sidebar (⌃⌘S)") { toggleSidebar() }
				.keyboardShortcut("s", modifiers: [.control, .command])
			if blockedBySystem || !notificationsOn {
				// macOS blocks it: only System Settings can lift that. Otherwise it is Mailflare's own switch.
				TitlebarIconButton(icon: .notificationOff, help: "Notification is off", tint: .orange) {
					if blockedBySystem { MailNotifier.openSystemSettings() } else { store.settingsPage = .notifications }
				}
			}
			// Narrow windows show one column at a time; this goes from the message back to the list.
			if layout.single && store.selectedID != nil && store.settingsPage == nil {
				TitlebarIconButton(icon: .arrowLeft, help: "Back to messages") { store.select(nil) }
			}
		}
		.padding(.leading, WindowChromeMetrics.sidebarToggleLeading)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - TitlebarIconButton.size / 2)
	}

	/// The search field, always shown over the message list and aligned with its leading edge.
	/// With the sidebar hidden it starts past the sidebar toggle instead.
	private var titlebarSearch: some View {
		@Bindable var store = store
		let listLeading = layout.showSidebar ? layout.sidebarW : 0
		let clearOfToggle = WindowChromeMetrics.sidebarToggleLeading + TitlebarIconButton.size + 8
		let leading = max(listLeading, clearOfToggle)
		// One column: the field runs to the window's edge, less the assistant button.
		let listEnd = layout.showList ? listLeading + layout.listW : windowWidth - 56
		let width = max(120, listEnd - leading)
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
					// Only where the body has no dark styles of its own to defer to.
					if colorScheme == .dark, columnScheme == nil, let html = store.detail.flatMap({ $0.summary.id == message.id ? $0.html : nil }),
					   !MessageAppearance.supportsDark(html) {
						TitlebarIconButton(
							icon: .colors,
							help: store.adaptColors ? "Show Original Colors" : "Adapt Colors to Dark Mode",
							isActive: !store.adaptColors
						) { store.toggleAdaptColors() }
					}
					flagMenu(message)
					moreMenu(message, role: role)
				}
			}
		}
		.padding(.trailing, WindowChromeMetrics.cardInset + 8 + toggleInset)
		.padding(.top, WindowChromeMetrics.titlebarRowCenter - TitlebarIconButton.size / 2)
	}

	/// Room the assistant panel takes on the trailing edge, which the floating compose button clears.
	/// The title bar's icons ignore it: they stay put when the panel opens.
	private var panelInset: CGFloat { store.chatVisible && layout.chatDocked ? AIChatPanel.width + WindowChromeMetrics.cardInset : 0 }
	/// The assistant button sits at the far right of the title bar; the message actions end before it.
	private var toggleInset: CGFloat { store.ai.isConfigured ? TitlebarIconButton.size + 6 : 0 }

	/// The sparkles button at the far right of the header; it opens and closes the assistant.
	private var assistantToggle: some View {
		TitlebarIconButton(icon: .sparkles, help: store.chatOpen ? "Close Assistant" : "Assistant", isActive: store.chatOpen, tooltipTrailing: true) {
			withAnimation(.easeInOut(duration: 0.2)) { store.chatOpen.toggle() }
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
		.padding(.trailing, WindowChromeMetrics.cardInset + 20 + panelInset)
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
