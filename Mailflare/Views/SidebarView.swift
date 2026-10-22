import SwiftUI
import MailflareCore

struct SidebarView: View {
	@Environment(MailStore.self) private var store
	@Environment(AppUpdater.self) private var updater
	@State private var switcherOpen = false

	var body: some View {
		ZStack(alignment: .top) {
			content
			// The dropdown covers the header's place, its top edge level with the main body's.
			if switcherOpen { dropdown.transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top))) }
		}
	}

	private var content: some View {
		VStack(spacing: 0) {
			if store.settingsPage != nil {
				settingsMenu
			} else {
				mailMenu
			}
			footer
		}
	}

	/// Settings take the mailbox list's place: a way back to the inbox, then the pages.
	private var settingsMenu: some View {
		VStack(alignment: .leading, spacing: 2) {
			Button {
				store.settingsPage = nil
			} label: {
				HStack(spacing: 8) {
					HIcon(.arrowLeft, size: 15)
					Text("Back to Inbox").font(Typography.body)
					Spacer(minLength: 0)
				}
				.foregroundStyle(.primary)
				.padding(.horizontal, 12).padding(.vertical, 10)
				.contentShape(Rectangle())
			}
			.buttonStyle(.light)
			.keyboardShortcut(.escape, modifiers: [])
			.help("Back to Inbox (Esc)")
			.padding(.bottom, 6)
			ForEach(SettingsPage.allCases) { page in
				SidebarRow(icon: page.icon, title: page.title, badge: 0, tint: nil, isSelected: store.settingsPage == page) {
					store.settingsPage = page
				}
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, Self.gutter)
		.frame(maxHeight: .infinity, alignment: .top)
	}

	private var mailMenu: some View {
		VStack(spacing: 0) {
			header
				.opacity(switcherOpen ? 0 : 1)
				.allowsHitTesting(!switcherOpen)
			ScrollView {
				VStack(alignment: .leading, spacing: 2) {
					row(.smartToday, "Today", .smartMailbox)
						.padding(.top, 4)
					// Favorites, then everything else for the inbox in view; an item is in one or the other.
					section(id: "favorites", title: "Favorites", keys: store.favoriteKeys, isFavorites: true)
					section(id: "rest", title: store.scopeTitle, keys: store.otherKeys, isFavorites: false)
					if store.isGmail {
						section(id: "labels", title: "Labels", keys: store.labelKeys, isFavorites: false, emptyText: "No labels")
					}
				}
				.padding(.horizontal, Self.gutter)
				.padding(.bottom, 12)
			}
			// A click anywhere else closes the account dropdown.
			.overlay {
				if switcherOpen { Color.clear.contentShape(Rectangle()).onTapGesture { closeSwitcher() } }
			}
		}
	}

	// MARK: Switcher header

	private var multipleInboxes: Bool { store.inboxAddresses.count > 1 }
	/// The same gutter on the left and the right of the sidebar.
	static let gutter: CGFloat = 10

	/// The account/inbox in view: pictures, name and address, with a chevron that opens the switcher.
	private var headerButton: some View {
		let activeView = store.activeView
		let inbox = activeView != nil ? nil : (store.currentInbox ?? (multipleInboxes ? nil : store.inboxAddresses.first))
		let title = activeView?.name ?? inbox.map { store.label($0) }
			?? (multipleInboxes ? "All Inboxes" : (store.account.map(store.accountName) ?? "Mailflare"))
		return Button {
			withAnimation(.snappy(duration: 0.22)) { switcherOpen.toggle() }
		} label: {
			HStack(spacing: 10) {
				if let activeView {
					accountStack(activeView.accountIDs, size: 28, step: 15)
				} else if let inbox, let account = store.account {
					ProfileAvatar(key: AvatarCache.key(account: account.id, mailbox: inbox.id), name: store.label(inbox), size: 34)
				} else if !multipleInboxes, let account = store.account {
					// A single-inbox account (Gmail and the like): the account itself.
					ProfileAvatar(key: AvatarCache.key(account: account.id), name: store.accountName(account), size: 34)
				} else {
					avatarStack(store.inboxAddresses, accountID: store.account?.id ?? "", size: 28, step: 15)
				}
				VStack(alignment: .leading, spacing: 1) {
					Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
					Text(activeView.map(viewSummary) ?? inbox?.inboxEmail ?? (multipleInboxes ? addressSummary : (store.account?.email ?? "")))
						.font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
				}
				Spacer(minLength: 0)
				HIcon(.chevronDown, size: 13).foregroundStyle(.secondary)
					.rotationEffect(.degrees(switcherOpen ? 180 : 0))
			}
			.padding(.horizontal, Self.gutter)
			.padding(.vertical, 10)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Inboxes, accounts and sign-out")
	}

	/// The header is always a bordered card, its top edge level with the main body's; opening the
	/// dropdown grows this same card downward.
	private var header: some View {
		headerButton
			.background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
			.padding(.horizontal, Self.gutter)
			.padding(.bottom, 6)
	}

	/// The open dropdown: the header card extended with the accounts, inboxes and account actions.
	private var dropdown: some View {
		VStack(spacing: 0) {
			headerButton
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.horizontal, 10)
			switcher
		}
		.background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
		.shadow(color: AppTheme.composerShadow, radius: 14, y: 6)
		.padding(.horizontal, Self.gutter)
	}

	/// The first address and how many more there are: "a@x.com +1 more".
	private var addressSummary: String {
		let emails = store.inboxAddresses.map(\.inboxEmail)
		guard let first = emails.first else { return "" }
		return emails.count > 1 ? "\(first) +\(emails.count - 1) more" : first
	}

	/// Up to three account pictures, overlapped.
	private func accountStack(_ ids: [String], size: CGFloat, step: CGFloat) -> some View {
		let shown = Array(ids.prefix(3))
		return ZStack(alignment: .leading) {
			ForEach(Array(shown.enumerated()), id: \.element) { index, id in
				let account = store.accountList.first { $0.id == id }
				ProfileAvatar(key: AvatarCache.key(account: id), name: account.map(store.accountName) ?? "?", size: size)
					.overlay(Circle().stroke(AppTheme.elevated, lineWidth: 2))
					.offset(x: CGFloat(index) * step)
					.zIndex(Double(shown.count - index))
			}
		}
		.frame(width: size + step * CGFloat(max(shown.count - 1, 0)), height: size + 6, alignment: .leading)
	}

	/// "2 inboxes · 2 accounts" under a view's name.
	private func viewSummary(_ view: InboxView) -> String {
		let inboxes = view.members.count, accounts = view.accountIDs.count
		return "\(inboxes) inbox\(inboxes == 1 ? "" : "es") · \(accounts) account\(accounts == 1 ? "" : "s")"
	}

	/// Up to three pictures, overlapped.
	private func avatarStack(_ inboxes: [Mailbox], accountID: String, size: CGFloat, step: CGFloat) -> some View {
		let shown = Array(inboxes.prefix(3))
		return ZStack(alignment: .leading) {
			ForEach(Array(shown.enumerated()), id: \.element.id) { index, inbox in
				ProfileAvatar(key: AvatarCache.key(account: accountID, mailbox: inbox.id), name: store.label(inbox), size: size)
					.overlay(Circle().stroke(AppTheme.elevated, lineWidth: 2))
					.offset(x: CGFloat(index) * step)
					.zIndex(Double(shown.count - index))
			}
		}
		.frame(width: size + step * CGFloat(max(shown.count - 1, 0)), height: size + 6, alignment: .leading)
	}

	/// Each saved account: all of its inboxes, then each inbox on its own. Scrolls only when it is
	/// taller than the room it gets (a `ScrollView` has no height of its own, so it is sized here).
	private var switcher: some View {
		let rows = store.accountList.reduce(0) { total, account in
			let inboxes = store.inboxAddresses(of: account.id).count
			return total + 1 + (inboxes > 1 ? inboxes : 0)
		} + store.inboxViews.count
		let content = VStack(alignment: .leading, spacing: 2) {
			ForEach(Array(store.accountList.enumerated()), id: \.element.id) { index, account in
				if index > 0 { Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 6) }
				accountRows(account)
			}
			if !store.inboxViews.isEmpty {
				Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 6)
				ForEach(store.inboxViews) { view in viewRow(view) }
			}
		}
		.padding(.vertical, 6)
		let natural = CGFloat(rows) * 48 + CGFloat(max(store.accountList.count - 1, 0)) * 14 + 12 + (store.inboxViews.isEmpty ? 0 : 14)
		return VStack(spacing: 0) {
			Group {
				if natural > 280 { ScrollView { content }.frame(height: 280) } else { content }
			}
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.horizontal, 10)
			VStack(alignment: .leading, spacing: 2) {
				actionRow(.allInboxes, "New Inbox View") { closeSwitcher(); store.inboxViewEditor = InboxView() }
				actionRow(.settings, "Manage Account") { closeSwitcher(); store.settingsPage = .accounts }
			}
			.padding(.vertical, 6)
		}
	}

	private func viewRow(_ view: InboxView) -> some View {
	ViewRow(
		isSelected: store.activeViewID == view.id,
		unread: store.unreadCount(of: view),
		action: { store.selectView(view.id); closeSwitcher() },
		edit: { closeSwitcher(); store.inboxViewEditor = view }
	) {
		accountStack(view.accountIDs, size: 24, step: 13)
	} text: {
		Text(view.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
		Text(viewSummary(view)).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
	}
}

private func actionRow(_ icon: AppIcon, _ title: String, action: @escaping () -> Void) -> some View {
		SwitcherRow(isSelected: false, unread: 0, action: action) {
			HIcon(icon, size: 16).foregroundStyle(.secondary).frame(width: 26)
		} text: {
			Text(title).font(Typography.body)
		}
	}

	@ViewBuilder
	private func accountRows(_ account: Account) -> some View {
		let inboxes = store.inboxAddresses(of: account.id)
		let isCurrent = account.id == store.account?.id
		let showInboxes = inboxes.count > 1
		SwitcherRow(
			isSelected: store.activeViewID == nil && isCurrent && (store.currentInbox == nil || !showInboxes),
			unread: store.unreadCount(accountID: account.id, inbox: nil),
			action: { store.selectInbox(nil, accountID: account.id); closeSwitcher() }
		) {
			if showInboxes {
				avatarStack(inboxes, accountID: account.id, size: 26, step: 14)
			} else {
				ProfileAvatar(key: AvatarCache.key(account: account.id), name: store.accountName(account), size: 32)
			}
		} text: {
			Text(store.accountName(account)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
			Text(showInboxes ? "\(account.email) (\(inboxes.count) inboxes)" : account.email)
				.font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
		}
		if showInboxes {
			ForEach(inboxes) { inbox in
				SwitcherRow(
					isSelected: store.activeViewID == nil && isCurrent && store.currentInbox?.id == inbox.id,
					unread: store.unreadCount(accountID: account.id, inbox: inbox),
					indent: true,
					action: { store.selectInbox(inbox, accountID: account.id); closeSwitcher() }
				) {
					ProfileAvatar(key: AvatarCache.key(account: account.id, mailbox: inbox.id), name: store.label(inbox), size: 28)
				} text: {
					Text(store.label(inbox)).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
					Text(inbox.inboxEmail).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
				}
			}
		}
	}

	private func closeSwitcher() { withAnimation(.snappy(duration: 0.22)) { switcherOpen = false } }

	// MARK: Footer

	/// The brand and version as a footnote, with a connection note above it when offline.
	private var footer: some View {
		VStack(alignment: .leading, spacing: 4) {
			if let note = store.connectionNote {
				Text(note).font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
			}
			if let release = updater.available {
				updateNotice(release)
			}
			if !store.license.isPro {
				Button { store.settingsPage = .license } label: {
					HStack(spacing: 8) {
						HIcon(.crown, size: 15)
						Text("Upgrade to Pro").font(.system(size: 13, weight: .medium))
					}
					.frame(maxWidth: .infinity)
					.padding(.vertical, 9)
					.background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
					.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.padding(.bottom, 4)
			}
			Button { store.settingsPage = store.settingsPage ?? .general } label: {
				HStack(spacing: 8) {
					HIcon(.settings, size: 15)
					Text("Settings").font(Typography.body)
					Spacer(minLength: 0)
				}
				.foregroundStyle(store.settingsPage == nil ? Color.secondary : Color.primary)
				.padding(.vertical, 6)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help("Settings (⌘,)")
			HStack(spacing: 6) {
				Text("\(store.displayBrandName) v\(MailStore.appVersion)").font(Typography.meta.weight(.medium)).foregroundStyle(.tertiary).lineLimit(1)
				Spacer(minLength: 0)
				if store.license.isPro {
					Text("PRO")
						.font(.system(size: 10, weight: .bold)).tracking(0.6)
						.foregroundStyle(.secondary)
						.padding(.horizontal, 6).padding(.vertical, 2)
						.background(AppTheme.elevated, in: Capsule())
						.overlay(Capsule().stroke(AppTheme.outline, lineWidth: 1))
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, Self.gutter * 2).padding(.top, 8).padding(.bottom, 12)
	}

	/// A newer release and the button that installs it, or how the install is going.
	private func updateNotice(_ release: AppUpdater.Release) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			switch updater.phase {
			case .idle:
				Text("Version \(release.version) is available").font(.footnote.weight(.medium))
				Button("Update and Restart") { Task { await updater.install() } }
					.buttonStyle(.pillProminent)
					.controlSize(.small)
			case .downloading, .installing:
				HStack(spacing: 6) {
					ProgressView().controlSize(.mini)
					Text(updater.phase == .downloading ? "Downloading \(release.version)…" : "Installing…").font(.footnote)
				}
			case .failed(let message):
				Text(message).font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
				Button("Try Again") { Task { await updater.install() } }
					.buttonStyle(.pill)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.noticeSurface(radius: 12)
		.padding(.bottom, 4)
	}

	/// A section whose title toggles it open or closed. Items can be dragged between Favorites and the
	/// section below; dropping on a Favorites row puts the item just before it.
	private func section(id: String, title: String, keys: [String], isFavorites: Bool, emptyText: String? = nil) -> some View {
		let collapsed = store.collapsedSections.contains(id)
		return VStack(alignment: .leading, spacing: 2) {
			Button {
				withAnimation(.snappy(duration: 0.2)) { store.toggleSection(id) }
			} label: {
				HStack(spacing: 5) {
					Text(title).font(Typography.meta.weight(.medium)).lineLimit(1)
					HIcon(.chevronRight, size: 10)
						.rotationEffect(.degrees(collapsed ? 0 : 90))
					Spacer(minLength: 0)
				}
				.foregroundStyle(.secondary)
				.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help(collapsed ? "Show \(title)" : "Hide \(title)")

			if !collapsed {
				if keys.isEmpty {
					Text(isFavorites ? "Drag items here" : (emptyText ?? "Nothing else"))
						.font(Typography.meta).foregroundStyle(.tertiary)
						.padding(.horizontal, 10).padding(.vertical, 6)
				}
				ForEach(keys, id: \.self) { key in
					if let item = store.item(for: key) {
						itemRow(key: key, item: item, isFavorite: isFavorites)
					}
				}
			}
		}
		.contentShape(Rectangle())
		.dropDestination(for: String.self) { dropped, _ in
			for key in dropped { store.moveItem(key, toFavorites: isFavorites) }
			return !dropped.isEmpty
		}
	}

	private func itemRow(key: String, item: SidebarItem, isFavorite: Bool) -> some View {
		let (title, icon, tint) = look(of: key, item: item)
		return row(item, title, icon, tint: tint)
			.draggable(key)
			.contextMenu {
				Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
					withAnimation(.snappy(duration: 0.2)) { store.moveItem(key, toFavorites: !isFavorite) }
				}
			}
			// Dropping an item on a Favorites row places it just before that row.
			.dropDestination(for: String.self) { dropped, _ in
				guard isFavorite else {
					for dragged in dropped { store.moveItem(dragged, toFavorites: false) }
					return !dropped.isEmpty
				}
				for dragged in dropped { store.moveItem(dragged, toFavorites: true, before: key) }
				return !dropped.isEmpty
			}
	}

	/// The row's name, glyph and tint. Names say "All" when every inbox is in view.
	private func look(of key: String, item: SidebarItem) -> (String, AppIcon, Color?) {
		let all = store.showsAllInboxes
		switch key {
		case "inbox": return (all ? "All Inboxes" : "Inbox", .allInboxes, nil)
		case "vips": return ("VIPs", .vip, nil)
		case "flagged": return ("Flagged", .flag, nil)
		case "remind": return ("Remind Me", .remind, nil)
		case "drafts": return (all ? "All Drafts" : "Drafts", .drafts, nil)
		case "sent": return (all ? "All Sent" : "Sent", .sent, nil)
		case "junk": return (all ? "All Spam" : "Spam", .junk, nil)
		case "trash": return (all ? "All Trash" : "Trash", .trash, nil)
		case "archive": return (all ? "All Archive" : "Archive", .archive, nil)
		default:
			if case .mailbox(let id) = item, let box = store.mailbox(id) {
				// In a view with several accounts, say whose folder it is.
				let owner = ViewMessageID.split(id).account.flatMap { a in store.accountList.first { $0.id == a } }
				let multi = (store.activeView?.accountIDs.count ?? 0) > 1
				return (multi ? owner.map { "\(box.name) — \(store.accountName($0))" } ?? box.name : box.name, icon(for: box), nil)
			}
			return (key, .folder, nil)
		}
	}

	private func icon(for box: Mailbox) -> AppIcon {
		switch box.role {
		case "inbox": .inbox
		case "drafts": .drafts
		case "sent": .sent
		case "junk": .junk
		case "trash": .trash
		case "archive": .archive
		default: store.isGmail ? .label : .folder
		}
	}

	private func row(_ item: SidebarItem, _ title: String, _ icon: AppIcon, tint: Color? = nil) -> some View {
		SidebarRow(icon: icon, title: title, badge: store.unreadCount(for: item), tint: tint, isSelected: store.sidebar == item) {
			store.sidebar = item
		}
	}
}

/// One sidebar line: glyph, name, unread count. Selected rows fill like PiCode's, hovered rows lift faintly.
private struct SidebarRow: View {
	var icon: AppIcon
	var title: String
	var badge: Int
	var tint: Color?
	var isSelected: Bool
	var action: () -> Void

	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				HIcon(icon, size: 16).foregroundStyle(tint ?? (isSelected ? Color.primary : Color.secondary))
				Text(title).font(Typography.body).lineLimit(1).foregroundStyle(.primary.opacity(0.94))
				Spacer(minLength: 4)
				if badge > 0 { Text("\(badge)").font(Typography.meta).foregroundStyle(.secondary) }
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 7)
			.background(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(isSelected ? AppTheme.railSelection : (isHovering ? AppTheme.rowHighlight : .clear))
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
	}
}


/// One line of the account switcher: pictures, name and address, unread count, and a check when chosen.
private struct SwitcherRow<Leading: View, Text_: View>: View {
	var isSelected: Bool
	var unread: Int
	var indent = false
	var action: () -> Void
	@ViewBuilder var leading: Leading
	@ViewBuilder var text: Text_

	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				leading
				VStack(alignment: .leading, spacing: 1) { text }
				Spacer(minLength: 4)
				if unread > 0 { SwiftUI.Text(unread > 999 ? "999+" : "\(unread)").font(Typography.meta).foregroundStyle(.secondary) }
				if isSelected { HIcon(.check, size: 14) }
			}
			.padding(.leading, indent ? 22 : 10).padding(.trailing, 10).padding(.vertical, 6)
			.background(RoundedRectangle(cornerRadius: 9, style: .continuous)
				.fill(isSelected ? AppTheme.railSelection : (isHovering ? AppTheme.rowHighlight : .clear)))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 4)
		.onHover { isHovering = $0 }
	}
}

/// A saved inbox view in the switcher. Hovering it shows an edit button where the unread count sits.
private struct ViewRow<Leading: View, Text_: View>: View {
var isSelected: Bool
var unread: Int
var action: () -> Void
var edit: () -> Void
@ViewBuilder var leading: Leading
@ViewBuilder var text: Text_

@State private var isHovering = false

var body: some View {
	Button(action: action) {
		HStack(spacing: 10) {
			leading
			VStack(alignment: .leading, spacing: 1) { text }
			Spacer(minLength: 4)
			if !isHovering {
				if unread > 0 { SwiftUI.Text(unread > 999 ? "999+" : "\(unread)").font(Typography.meta).foregroundStyle(.secondary) }
				if isSelected { HIcon(.check, size: 14) }
			}
		}
		.padding(.leading, 10).padding(.trailing, 10).padding(.vertical, 6)
		.background(RoundedRectangle(cornerRadius: 9, style: .continuous)
			.fill(isSelected ? AppTheme.railSelection : (isHovering ? AppTheme.rowHighlight : .clear)))
		.contentShape(Rectangle())
	}
	.buttonStyle(.plain)
	.overlay(alignment: .trailing) {
		if isHovering {
			Button(action: edit) {
				HIcon(.edit, size: 14)
					.foregroundStyle(.secondary)
					.frame(width: 26, height: 26)
					.contentShape(Rectangle())
			}
			.buttonStyle(.light)
			.help("Edit inbox view")
			.padding(.trailing, 8)
		}
	}
	.padding(.horizontal, 4)
	.onHover { isHovering = $0 }
}
}

/// A round profile picture, or the initials on a blue circle when there is none.
struct ProfileAvatar: View {
	@Environment(MailStore.self) private var store
	var key: String
	var name: String
	var size: CGFloat

	var body: some View {
		Group {
			if let image = store.avatars.images[key] {
				Image(nsImage: image).resizable().scaledToFill()
			} else {
				Text(initials)
					.font(.system(size: size * 0.42, weight: .semibold))
					.foregroundStyle(.white)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(Color(red: 0.12, green: 0.55, blue: 0.93))
			}
		}
		.frame(width: size, height: size)
		.clipShape(Circle())
	}

	private var initials: String {
		let parts = name.split(whereSeparator: { " .@".contains($0) }).prefix(2)
		let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
		return letters.isEmpty ? "?" : letters
	}
}
