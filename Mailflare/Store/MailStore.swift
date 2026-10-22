import Foundation
import Observation
import AppKit
import MailflareCore

/// Hands core events back to the main actor.
private final class CoreEvents: CoreListener {
	nonisolated(unsafe) weak var store: MailStore?
	func onEvent(event: CoreEvent) {
		Task { @MainActor [weak store] in store?.handle(event) }
	}
}

@MainActor
@Observable
final class MailStore {
	enum Phase { case signedOut, connecting, ready }

	/// Starts as `.connecting` until `restore()` knows whether an account exists, so neither the
	/// main window nor the sign-in window flashes up first.
	var phase: Phase = .connecting
	var accountList: [Account] = []
	/// Set while the sign-in popup is up over the main window (adding another account).
	var showAddAccount = false
	/// The Settings page in view; nil shows the mailbox. Settings replace the list and reader.
	var settingsPage: SettingsPage?
	@ObservationIgnored private var markReadTask: Task<Void, Never>?
	let notifier = MailNotifier()
	/// Accounts with a background (quick) sync in flight: they refresh the list without the loader.
	@ObservationIgnored private var quietSyncs: Set<String> = []
	var banner: String?
	/// A short confirmation shown at the top right (sent, saved); it clears itself.
	var toast: Toast?
	@ObservationIgnored private var toastTask: Task<Void, Never>?
	var isSyncing = false
	/// Shown quietly in the sidebar when the server can't be reached; saved mail stays usable.
	var connectionNote: String?

	@ObservationIgnored private var core: MailCore?
	@ObservationIgnored private let events = CoreEvents()
	var account: Account?
	var mailboxes: [Mailbox] = []
	var identities: [Identity] = []
	var flaggedCount = 0
	var inboxUnread = 0
	/// The address mailbox the sidebar is scoped to; nil means all inboxes.
	var scopeID: String? = UserDefaults.standard.string(forKey: "scopeInbox")
	var brandName = "Mailflare"
	/// A licensed server's branding follows the app across accounts; otherwise the account's own.
	var displayBrandName: String { license.brandName ?? brandName }
	let license = LicenseManager()
	let ai = AISettings()
	let chat = AIChatModel()
	/// Whether the panel is showing: open, and a provider is set up to answer.
	var chatVisible: Bool { chatOpen && ai.isConfigured }
	/// Whether the assistant panel is open.
	var chatOpen = UserDefaults.standard.bool(forKey: "chatOpen") {
		didSet { UserDefaults.standard.set(chatOpen, forKey: "chatOpen") }
	}
	var mailCore: MailCore? { core }
	var currentAccountID: String { accountID }
	/// The raw id of the email in the reader, for the assistant's context.
	var openEmailIDForAI: String? { selectedID.map { owner(of: $0).message } }
	/// After the assistant changed mail: refresh what is on screen.
	func aiDidChangeMail() { invalidateCaches(); reload(); refreshMailboxes() }
	let profiles = AccountProfiles()
	@ObservationIgnored private(set) var avatars = AvatarCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mailflare-avatars", isDirectory: true))

	var sidebar: SidebarItem = .allInboxes
	var messages: [MessageSummary] = []
	var total = 0
	var selectedID: String?
	var detail: MessageDetail?
	var searchText = ""
	/// Whether the open message's colors are re-made for the dark window (see `MessageAppearance`);
	/// the toolbar's colors button flips it for that sender.
	var adaptColors = true
	var unreadOnly = false
	var compose: ComposeDraft?

	/// Inbox views: named sets of inboxes, across accounts, listed together. Saved on this Mac.
	var inboxViews: [InboxView] = MailStore.loadInboxViews()
	/// The view whose inboxes are listed; nil lists the account in view as usual.
	var activeViewID: String?
	/// The view open in the create/edit popup.
	var inboxViewEditor: InboxView?
	var activeView: InboxView? { activeViewID.flatMap { id in inboxViews.first { $0.id == id } } }

	var vips: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "vips") ?? [])
	var reminders: [String: Date] = {
		(UserDefaults.standard.dictionary(forKey: "reminders") as? [String: Double])?.mapValues { Date(timeIntervalSince1970: $0) } ?? [:]
	}()

	@ObservationIgnored private var detailTask: Task<Void, Never>?
	@ObservationIgnored private var pollTask: Task<Void, Never>?
	@ObservationIgnored private var olderTask: Task<Void, Never>?
	@ObservationIgnored private var pageLimit = 50
	private let pageSize = 50
	/// Smart mailboxes and filters read a wider local window and filter it in memory.
	private let scanLimit: UInt32 = 1000

	init() {
		events.store = self
		notifier.open = { [weak self] account, message in self?.openMessage(accountID: account, messageID: message) }
		do {
			var base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
				.appendingPathComponent("Mailflare", isDirectory: true)
			#if DEBUG
			// Debug builds can point at a scratch directory so tests never touch a real account's cache.
			if let scratch = ProcessInfo.processInfo.environment["MAILFLARE_DATA_DIR"] { base = URL(fileURLWithPath: scratch, isDirectory: true) }
			#endif
			avatars = AvatarCache(directory: base.appendingPathComponent("avatars", isDirectory: true))
			let core = try MailCore(dataDir: base.path, credentials: KeychainCredentialStore())
			core.setListener(listener: events)
			self.core = core
		} catch {
			banner = "Could not open the mail database (\(Self.dataDirectoryDescription)): \(describe(error))"
		}
	}

	private var accountID: String { account?.id ?? "" }

	static var dataDirectoryDescription: String {
		(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Mailflare").path ?? "Application Support/Mailflare")
			.replacingOccurrences(of: NSHomeDirectory(), with: "~")
	}

	// MARK: Sign-in

	func restore() async {
		guard phase == .connecting else { return }
		guard let core else { phase = .signedOut; return }
		#if DEBUG
		// Debug builds only: sign in from launch variables so screenshots need no typing.
		let env = ProcessInfo.processInfo.environment
		if let key = env["MAILFLARE_DEV_KEY"], let email = env["MAILFLARE_DEV_EMAIL"] {
			phase = .connecting
			do { activate(try await core.signIn(email: email, appPassword: key, serverUrl: env["MAILFLARE_DEV_SERVER"])) }
			catch { phase = .signedOut; banner = describe(error) }
			return
		}
		#endif
		if let first = try? core.accounts().first {
			if KeychainCredentialStore().load(accountId: first.id) == nil {
				// Cached mail stays on disk; signing in again replaces the key for the same account.
				endSession("Your saved sign-in could not be read from the Keychain. Sign in again.")
				return
			}
			activate(first)
			return
		}
		phase = .signedOut
	}

	/// Tries the account password first (device key + MFA), then falls back to an app password.
	func signIn(server: String, email: String, password: String, deviceName: String) async throws -> SignInOutcome {
		guard let core else { throw CoreError.Storage(message: "The mail database is not available.") }
		let url = server.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.normalize(server)
		do {
			switch try await core.signInWithPassword(email: email, password: password, serverUrl: url, deviceName: deviceName) {
			case .signedIn(let account):
				activate(account)
				return .signedIn
			case .mfaRequired(let challenge, let serverURL):
				return .needsCode(challenge: challenge, serverURL: serverURL)
			}
		} catch let error as CoreError {
			switch error {
			case .Network:
				// Say which address was tried: with no server given, the core guesses from the email's domain.
				if url == nil {
					let domain = email.split(separator: "@").last.map(String.init) ?? "your email's domain"
					throw CoreError.Network(message: "Could not reach a Mailflare server at \(domain). Enter your server address (for example mail.\(domain)).")
				}
				throw CoreError.Network(message: "Could not connect to \(server.trimmingCharacters(in: .whitespaces)). Check the address and your connection.")
			case .Auth, .Discovery:
				do {
					activate(try await core.signIn(email: email, appPassword: password, serverUrl: url))
					return .signedIn
				} catch let second as CoreError {
					if case .Auth = second { throw CoreError.Auth(message: "Invalid credentials. Use your account password or an app password.") }
					throw second
				}
			default: throw error
			}
		}
	}

	/// IMAP accounts: the core checks the login on the incoming and outgoing servers, then stores it.
	func signInIMAP(email: String, password: String, config: MailServerConfig) async throws {
		guard let core else { throw CoreError.Storage(message: "The mail database is not available.") }
		activate(try await core.signInImap(email: email.trimmingCharacters(in: .whitespaces), password: password, config: config))
	}

	func completeMFA(email: String, challenge: String, code: String, serverURL: String, deviceName: String) async throws {
		guard let core else { return }
		activate(try await core.completeMfa(email: email, challengeToken: challenge, code: code, serverUrl: serverURL, deviceName: deviceName))
	}

	private static func normalize(_ server: String) -> String {
		var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
		if !s.contains("://") {
			let local = s.hasPrefix("localhost") || s.hasPrefix("127.0.0.1")
			s = (local ? "http://" : "https://") + s
		}
		return s
	}

	private func activate(_ account: Account) {
		self.account = account
		accountList = (try? core?.accounts()) ?? [account]
		showAddAccount = false
		activeViewID = nil
		banner = nil
		connectionNote = nil
		phase = .ready
		sidebar = .allInboxes
		selectedID = nil; detail = nil
		refreshMailboxes()
		reload()
		loadBrand()
		refreshLicenses()
		for a in accountList { loadAvatars(for: a); loadNames(for: a) }
		// Record what each inbox holds now, so only mail arriving after this is announced.
		for a in accountList { checkNewMail(accountID: a.id) }
		Task { await notifier.prepare() }
		sync()
		startPolling()
	}

	func switchAccount(_ target: Account) {
		guard target.id != account?.id else { return }
		pollTask?.cancel()
		reloadScratch()
		activate(target)
	}

	private func reloadScratch() {
		messages = []; mailboxes = []; identities = []; detail = nil; selectedID = nil
		compose = nil; minimizedDraft = nil; searchText = ""; scopeID = nil
		chat.reset()
		UserDefaults.standard.removeObject(forKey: "scopeInbox")
	}

	/// Signs out one saved account: the one in view the usual way, any other quietly in the background.
	func signOut(_ target: Account) {
		if target.id == account?.id { signOut(); return }
		try? core?.signOut(accountId: target.id)
		profiles.forget(target.id)
		accountList = (try? core?.accounts()) ?? accountList.filter { $0.id != target.id }
		license.retain(accountIDs: accountList.map(\.id))
	}

	func signOut(notice: String? = nil) {
		pollTask?.cancel()
		if let id = account?.id { try? core?.signOut(accountId: id); profiles.forget(id) }
		account = nil; mailboxes = []; identities = []; messages = []; detail = nil; selectedID = nil
		compose = nil; minimizedDraft = nil; searchText = ""; settingsPage = nil
		chat.reset()
		// VIPs and reminders belong to the account that was signed in.
		vips = []; reminders = [:]
		scopeID = nil; brandName = "Mailflare"
		license.retain(accountIDs: (try? core?.accounts().map(\.id)) ?? [])
		UserDefaults.standard.removeObject(forKey: "scopeInbox")
		UserDefaults.standard.removeObject(forKey: "vips")
		UserDefaults.standard.removeObject(forKey: "reminders")
		// Another saved account takes over; otherwise the sign-in window comes back.
		accountList = (try? core?.accounts()) ?? []
		if let next = accountList.first(where: { KeychainCredentialStore().load(accountId: $0.id) != nil }) {
			activate(next)
			return
		}
		phase = .signedOut
		banner = notice
		notifier.setBadge(0)
	}

	// MARK: Inbox views

	/// The account that holds a message, and the account's own id for it. Outside a view the id is plain.
	private func owner(of id: String) -> (account: String, message: String) {
		let parts = ViewMessageID.split(id)
		return (parts.account ?? accountID, parts.message)
	}

	/// The account a listed message belongs to; nil for the account in view outside a view.
	func accountID(of message: MessageSummary) -> String? { ViewMessageID.split(message.id).account }

	private static func tagged(_ detail: MessageDetail, id: String) -> MessageDetail {
		var copy = detail
		copy.summary.id = id
		return copy
	}

	@ObservationIgnored private var identityCache: [String: [Identity]] = [:]

	func identities(forAccount id: String) -> [Identity] {
		if id == account?.id { return identities }
		if let cached = identityCache[id] { return cached }
		let loaded = (try? core?.identities(accountId: id)) ?? []
		identityCache[id] = loaded
		return loaded
	}

	/// The addresses a draft can be sent from: those of the account it is written in.
	func identities(for draft: ComposeDraft) -> [Identity] { draft.accountID.map(identities(forAccount:)) ?? identities }

	private static func loadInboxViews() -> [InboxView] {
		guard let data = UserDefaults.standard.data(forKey: "inboxViews") else { return [] }
		return (try? JSONDecoder().decode([InboxView].self, from: data)) ?? []
	}

	private func persistInboxViews() {
		UserDefaults.standard.set(try? JSONEncoder().encode(inboxViews), forKey: "inboxViews")
	}

	func saveInboxView(_ view: InboxView) {
		if let index = inboxViews.firstIndex(where: { $0.id == view.id }) { inboxViews[index] = view } else { inboxViews.append(view) }
		persistInboxViews()
		if activeViewID == view.id { pageLimit = pageSize; reload() }
	}

	func deleteInboxView(_ id: String) {
		inboxViews.removeAll { $0.id == id }
		persistInboxViews()
		if activeViewID == id { activeViewID = nil; selectedID = nil; detail = nil; pageLimit = pageSize; reload() }
	}

	func selectView(_ id: String) {
		guard inboxViews.contains(where: { $0.id == id }) else { return }
		activeViewID = id
		settingsPage = nil
		sidebar = .allInboxes
		searchText = ""
		selectedID = nil; detail = nil
		pageLimit = pageSize
		reload()
	}

	/// Unread inbox mail across the view's inboxes.
	func unreadCount(of view: InboxView) -> Int {
		view.members.reduce(0) { total, member in
			guard let inboxID = member.inboxID else { return total + unreadCount(accountID: member.accountID, inbox: nil) }
			guard let inbox = inboxAddresses(of: member.accountID).first(where: { $0.id == inboxID }) else { return total }
			return total + unreadCount(accountID: member.accountID, inbox: inbox)
		}
	}

	// MARK: Sync

	func sync(quick: Bool = false) {
		guard let core, account != nil else { return }
		let id = accountID
		if quick { quietSyncs.insert(id) }
		Task {
			do {
				if quick { try await core.syncQuick(accountId: id) } else { try await core.sync(accountId: id) }
				connectionNote = nil
			} catch let error as CoreError {
				guard account?.id == id else { return }
				switch error {
				case .Auth:
					// The server no longer accepts this device's key (revoked, or the password changed).
					endSession("Your session has ended. Sign in again.")
				case .Network:
					connectionNote = "Can’t reach the server. Showing saved mail."
				default:
					if !quick { banner = describe(error) }
				}
			} catch { if !quick { banner = describe(error) } }
		}
	}

	/// Back to the sign-in screen without discarding anything cached: signing in again to the
	/// same account replaces its key and the saved mail is still there.
	private func endSession(_ notice: String) {
		pollTask?.cancel()
		account = nil; mailboxes = []; identities = []; messages = []; detail = nil; selectedID = nil
		connectionNote = nil; isSyncing = false
		phase = .signedOut
		banner = notice
	}

	private func startPolling() {
		pollTask?.cancel()
		pollTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(60))
				self?.pollAll()
			}
		}
	}

	/// A quick sync of the account in view and of every other saved account, so mail for any of
	/// them is noticed. Errors on the others are ignored; they show when that account is opened.
	private func pollAll() {
		sync(quick: true)
		guard let core else { return }
		let current = account?.id
		for other in accountList where other.id != current && KeychainCredentialStore().load(accountId: other.id) != nil {
			let id = other.id
			quietSyncs.insert(id)
			Task { try? await core.syncQuick(accountId: id) }
		}
	}

	/// Hands an account's inbox to the notifier and refreshes the Dock badge.
	private func checkNewMail(accountID id: String) {
		guard let core, let account = accountList.first(where: { $0.id == id }) else { return }
		let inbox = (try? core.messages(accountId: id, folder: .role(role: "inbox"), offset: 0, limit: 50)) ?? []
		notifier.process(accountID: id, inbox: inbox, accountLabel: accountList.count > 1 ? accountName(account) : nil)
		updateBadge()
	}

	/// The Dock badge counts unread inbox mail across every account.
	func updateBadge() {
		notifier.setBadge(accountList.reduce(0) { $0 + unreadCount(accountID: $1.id, inbox: nil) })
	}

	/// Opens a message from a notification: its account, the combined inbox, then the message.
	func openMessage(accountID: String, messageID: String) {
		NSApp.activate(ignoringOtherApps: true)
		NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
		guard phase == .ready else { return }
		settingsPage = nil
		if accountID != account?.id, let target = accountList.first(where: { $0.id == accountID }) { switchAccount(target) }
		searchText = ""; unreadOnly = false
		sidebar = .allInboxes
		setScope(nil)
		select(messageID)
	}

	func handle(_ event: CoreEvent) {
		switch event {
		case .syncStarted(let id): if id == account?.id, !quietSyncs.contains(id) { isSyncing = true }
		case .syncFinished(let id, let error):
			invalidateCaches()
			quietSyncs.remove(id)
			if id != account?.id, activeView?.accountIDs.contains(id) == true { reload() }
			if id == account?.id {
				isSyncing = false
				refreshMailboxes(); reload()
				// Sent mail may have just arrived, which is where names come from.
				if let a = account { loadNames(for: a) }
				// Failures are classified where `sync()` throws; a clean finish means we're connected.
				if error == nil { connectionNote = nil }
			}
			checkNewMail(accountID: id)
		case .mailboxesChanged: invalidateCaches(); refreshMailboxes()
		case .messagesChanged, .newMail: invalidateCaches(); reload()
		case .outboxChanged: checkOutbox()
		case .messageSent(_, let subject): showToast("Message sent", detail: subject, icon: .check)
		}
	}

	private func checkOutbox() {
		guard let core, account != nil else { return }
		if let bad = (try? core.outbox(accountId: accountID))?.first(where: { $0.error != nil }) {
			toast = nil
			banner = "“\(bad.subject.isEmpty ? "A message" : bad.subject)” could not be sent: \(bad.error ?? "unknown error")"
		}
	}

	// MARK: Mailboxes

	func refreshMailboxes() {
		guard let core, account != nil else { return }
		mailboxes = (try? core.mailboxes(accountId: accountID)) ?? mailboxes
		identities = (try? core.identities(accountId: accountID)) ?? identities
		if let a = account { loadAvatars(for: a) }
		updateBadge()
		if let id = scopeID, !mailboxes.contains(where: { $0.id == id && $0.isAccount }) { setScope(nil) }
		if let scope = currentInbox {
			let starred = (try? core.messages(accountId: accountID, folder: .starred, offset: 0, limit: scanLimit)) ?? []
			flaggedCount = starred.filter(inScope).count
			inboxUnread = Int(mailboxes.first { $0.parentId == scope.id && $0.role == "inbox" }?.unreadEmails ?? 0)
		} else {
			flaggedCount = Int((try? core.messageCount(accountId: accountID, folder: .starred)) ?? 0)
			inboxUnread = Int((try? core.unreadCount(accountId: accountID, folder: .role(role: "inbox"))) ?? 0)
		}
	}

	// MARK: Favorites and sections

	/// Everything the sidebar can list below Today, by stable key. Favorites is a chosen subset; the
	/// rest are listed in the section below it, so nothing appears twice.
	static let defaultFavorites = ["inbox", "vips", "flagged", "remind", "drafts", "sent"]
	private static let systemKeys = ["inbox", "vips", "flagged", "remind", "drafts", "sent", "junk", "trash", "archive"]

	/// VIPs and reminders exist only on this Mac: neither the Mailflare server nor the core has them
	/// (no VIP list, no snooze). They stay hidden until a mail service supports them.
	static let supportsVIPs = false
	static let supportsReminders = false
	var supportsVIPs: Bool { Self.supportsVIPs }
	var supportsReminders: Bool { Self.supportsReminders }

	var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favoriteItems") ?? MailStore.defaultFavorites
	var collapsedSections: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? [])

	func item(for key: String) -> SidebarItem? {
		switch key {
		case "inbox": return .allInboxes
		case "vips": return supportsVIPs ? .vips : nil
		case "flagged": return .flagged
		case "remind": return supportsReminders ? .remindMe : nil
		case "drafts": return .allDrafts
		case "sent": return .allSent
		case "junk": return .allJunk
		case "trash": return .allTrash
		case "archive": return .allArchive
		default:
			guard key.hasPrefix("folder:") else { return nil }
			let id = String(key.dropFirst("folder:".count))
			return mailbox(id) != nil ? .mailbox(id) : nil
		}
	}

	/// Gmail keeps its folders as labels, so its account gets a Labels section instead of folders in
	/// the main list. Recognised by its IMAP server (which also covers Google Workspace domains).
	var isGmail: Bool {
		guard let account, activeViewID == nil else { return false }
		let host = account.serverUrl.lowercased()
		let domain = account.email.split(separator: "@").last.map { $0.lowercased() } ?? ""
		return host.contains("gmail.com") || host.contains("googlemail.com") || domain == "gmail.com" || domain == "googlemail.com"
	}

	/// The Gmail labels not already in Favorites.
	var labelKeys: [String] {
		guard isGmail else { return [] }
		let chosen = Set(favorites)
		return folderKeys.filter { !chosen.contains($0) }
	}

	/// Custom folders are listed when one inbox is in view, or when the account has only one.
	private var folderKeys: [String] {
		if let view = activeView { return viewFolderKeys(view) }
		guard currentInbox != nil || inboxAddresses.count <= 1 else { return [] }
		if inboxAddresses.isEmpty { return plainFolders.map { "folder:\($0.id)" } }
		return accounts.flatMap { children(of: $0) }.filter { $0.role == nil }.map { "folder:\($0.id)" }
	}

	/// The folders and labels of every account in a view, keyed by account and mailbox.
	private func viewFolderKeys(_ view: InboxView) -> [String] {
		view.accountIDs.flatMap { account -> [String] in
			let boxes = mailboxes(of: account)
			let members = view.members.filter { $0.accountID == account }
			let folders: [Mailbox]
			if Self.addressMailboxes(in: boxes).isEmpty {
				folders = boxes.filter { $0.role == nil && !$0.name.hasPrefix("[") }
			} else {
				let wanted = Set(members.compactMap(\.inboxID)), everything = members.contains { $0.inboxID == nil }
				folders = boxes.filter { box in
					guard box.role == nil, let parent = box.parentId else { return false }
					return everything || wanted.contains(parent)
				}
			}
			return folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
				.map { "folder:" + ViewMessageID.make(account: account, message: $0.id) }
		}
	}

	/// Folders and labels of a single-inbox account (IMAP): top-level mailboxes without a role, minus
	/// the provider's non-selectable containers such as Gmail's "[Gmail]".
	private var plainFolders: [Mailbox] {
		mailboxes.filter { $0.role == nil && !$0.name.hasPrefix("[") }
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	/// Where a message can be moved: grouped by inbox when there are several, one flat list otherwise.
	var moveTargets: [(title: String?, boxes: [Mailbox])] {
		if inboxAddresses.isEmpty {
			let system = mailboxes.filter { $0.role != nil }.sorted {
				(Self.roleOrder.firstIndex(of: $0.role ?? "") ?? 99) < (Self.roleOrder.firstIndex(of: $1.role ?? "") ?? 99)
			}
			return [(nil, system + plainFolders)]
		}
		return accounts.map { (inboxAddresses.count > 1 ? label($0) : nil, children(of: $0)) }
	}

	/// The favorites that still exist, in the user's order.
	var favoriteKeys: [String] { favorites.filter { item(for: $0) != nil } }

	/// Everything not in Favorites, in the usual order.
	var otherKeys: [String] {
		let chosen = Set(favorites)
		// Gmail's labels have their own section.
		return (Self.systemKeys + (isGmail ? [] : folderKeys)).filter { !chosen.contains($0) && item(for: $0) != nil }
	}

	/// Moves `key` into Favorites (before `before`, or at the end) or back out of it.
	func moveItem(_ key: String, toFavorites: Bool, before: String? = nil) {
		guard item(for: key) != nil else { return }
		var list = favorites.filter { $0 != key }
		if toFavorites {
			if let before, let index = list.firstIndex(of: before) { list.insert(key, at: index) } else { list.append(key) }
		}
		favorites = list
		UserDefaults.standard.set(list, forKey: "favoriteItems")
	}

	func toggleSection(_ id: String) {
		if collapsedSections.contains(id) { collapsedSections.remove(id) } else { collapsedSections.insert(id) }
		UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections")
	}

	// MARK: Inbox scope (one address, or all of them)

	/// Address mailboxes: top-level mailboxes holding an inbox of their own. Mailflare has one per
	/// address; Gmail and other single-inbox providers have none, so nothing says "All" for them.
	static func addressMailboxes(in list: [Mailbox]) -> [Mailbox] {
		let owners = Set(list.filter { $0.role == "inbox" }.compactMap(\.parentId))
		return list.filter { $0.isAccount && owners.contains($0.id) }.sorted { $0.sortOrder < $1.sortOrder }
	}

	var inboxAddresses: [Mailbox] { Self.addressMailboxes(in: mailboxes) }

	/// True only when several inboxes are combined in the view, the one case that is "All …".
	var showsAllInboxes: Bool { activeViewID != nil || (currentInbox == nil && inboxAddresses.count > 1) }
	var currentInbox: Mailbox? { scopeID.flatMap { id in inboxAddresses.first { $0.id == id } } }

	/// What the sidebar header shows: the chosen inbox, "All Inboxes", or the only inbox there is.
	var scopeTitle: String {
		if let view = activeView { return view.name }
		if let inbox = currentInbox { return label(inbox) }
		if inboxAddresses.count == 1 { return label(inboxAddresses[0]) }
		if inboxAddresses.isEmpty, let account { return accountName(account) }
		return "All Inboxes"
	}

	func setScope(_ id: String?) {
		scopeID = id
		activeViewID = nil
		if let id { UserDefaults.standard.set(id, forKey: "scopeInbox") } else { UserDefaults.standard.removeObject(forKey: "scopeInbox") }
		if case .mailbox = sidebar { sidebar = .allInboxes }
		pageLimit = pageSize
		refreshMailboxes()
		reload()
	}

	/// Whether a message belongs to the chosen inbox (always true when scoped to all).
	private func inScope(_ m: MessageSummary) -> Bool {
		guard let scope = scopeID else { return true }
		return mailbox(m.mailboxId)?.parentId == scope
	}

	/// A system folder within the chosen inbox, or across all inboxes.
	private func scopedFolder(_ role: String) -> Folder {
		if let inbox = currentInbox, let leaf = mailboxes.first(where: { $0.parentId == inbox.id && $0.role == role }) {
			return .mailbox(id: leaf.id)
		}
		return .role(role: role)
	}

	// MARK: Accounts and their inboxes (the switcher)

	/// Address mailboxes of any saved account, read from the local store.
	func inboxAddresses(of accountID: String) -> [Mailbox] {
		if accountID == account?.id { return inboxAddresses }
		return Self.addressMailboxes(in: mailboxes(of: accountID))
	}

	/// Unread in an address's inbox, or across all of an account's inboxes when `inbox` is nil.
	func unreadCount(accountID: String, inbox: Mailbox?) -> Int {
		guard let core else { return 0 }
		return mailboxes(of: accountID).filter { $0.role == "inbox" && (inbox == nil || $0.parentId == inbox?.id) }.reduce(0) { $0 + Int($1.unreadEmails) }
	}

	/// Switches to `inbox` (or all of the account's inboxes), changing account first when needed.
	func selectInbox(_ inbox: Mailbox?, accountID: String) {
		if accountID != account?.id, let target = accountList.first(where: { $0.id == accountID }) { switchAccount(target) }
		setScope(inbox?.id)
	}

	// MARK: Names

	/// Display names learned from the user's own sent mail, by lower-cased address. Providers like
	/// Gmail and iCloud name an account after its address, so the name the user's mail goes out under
	/// is what they actually call themselves.
	var knownNames: [String: String] = [:]

	private static func nameKey(_ email: String) -> String { "name.\(email.lowercased())" }

	/// An inbox's label: a name the mailbox carries, else the sent-mail name, else the part before the @.
	func label(_ address: Mailbox) -> String {
		let own = address.inboxLabel
		let email = address.inboxEmail
		let bare = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
		guard own == bare else { return own }
		return knownNames[email.lowercased()] ?? own
	}

	/// An account's name: the server's when it has one (IMAP accounts are named after their address),
	/// else the sent-mail name, else the part before the @.
	func accountName(_ account: Account) -> String {
		if let own = profiles.localName(account.id) { return own }
		guard account.displayName.contains("@") else { return account.displayName }
		return knownNames[account.email.lowercased()] ?? account.shownName
	}

	/// Learns names from the Sent folder: each of the user's own addresses is paired with the display
	/// name its sent mail carries, and cached for the next launch. Safe to repeat; it reads local mail.
	func loadNames(for account: Account) {
		guard let core else { return }
		let defaults = UserDefaults.standard
		let addresses = [account.email] + inboxAddresses(of: account.id).map(\.inboxEmail)
		for email in addresses {
			if let cached = defaults.string(forKey: Self.nameKey(email)), knownNames[email.lowercased()] == nil {
				knownNames[email.lowercased()] = cached
			}
		}
		let own = Set(addresses.map { $0.lowercased() })
		let sent = (try? core.messages(accountId: account.id, folder: .role(role: "sent"), offset: 0, limit: 60)) ?? []
		for message in sent {
			let email = message.fromEmail.lowercased()
			let name = message.fromName.trimmingCharacters(in: .whitespaces)
			guard own.contains(email), !name.isEmpty, name.lowercased() != email, knownNames[email] != name else { continue }
			knownNames[email] = name
			defaults.set(name, forKey: Self.nameKey(email))
		}
	}

	/// Starts loading profile pictures for an account and its inboxes (once per launch).
	func loadAvatars(for account: Account) {
		avatars.load(key: AvatarCache.key(account: account.id), account: account, mailboxID: nil, email: account.email)
		for inbox in inboxAddresses(of: account.id) {
			avatars.load(key: AvatarCache.key(account: account.id, mailbox: inbox.id), account: account, mailboxID: inbox.id, email: inbox.inboxEmail)
		}
	}

	// MARK: Brand

	func loadBrand() {
		guard let account else { return }
		let key = "brand.\(account.id)"
		brandName = UserDefaults.standard.string(forKey: key) ?? "Mailflare"
		let id = account.id
		Task {
			guard let json = await Self.fetchBranding(of: account), self.account?.id == id else { return }
			guard let name = json["appName"] as? String else { return }
			brandName = name.isEmpty ? "Mailflare" : name
			UserDefaults.standard.set(brandName, forKey: key)
		}
	}

	/// A server with an active Pro or Team license activates the app for as long as the account is
	/// signed in, so every saved account is asked, not only the one in view.
	func refreshLicenses() {
		license.retain(accountIDs: accountList.map(\.id))
		for account in accountList {
			Task {
				guard let json = await Self.fetchBranding(of: account),
					  let licensed = json["canCustomizeBranding"] as? Bool else { return }
				license.setServerLicensed(licensed, accountID: account.id, brandName: json["appName"] as? String)
			}
		}
	}

	private nonisolated static func fetchBranding(of account: Account) async -> [String: Any]? {
		var parts = URLComponents(string: account.serverUrl.contains("://") ? account.serverUrl : "https://\(account.serverUrl)")
		guard parts?.host != nil, ["http", "https"].contains(parts?.scheme ?? "") else { return nil }
		parts?.path = "/api/branding"; parts?.query = nil; parts?.fragment = nil
		guard let url = parts?.url,
			  let (data, response) = try? await URLSession.shared.data(from: url),
			  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
		return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
	}

	static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

	/// The address sections the sidebar lists: the chosen inbox only, or all of them.
	var accounts: [Mailbox] { currentInbox.map { [$0] } ?? inboxAddresses }

	private static let roleOrder = ["inbox", "drafts", "sent", "junk", "trash", "archive"]

	/// Folders first, then system mailboxes in Mail's order.
	func children(of account: Mailbox) -> [Mailbox] {
		let kids = mailboxes.filter { $0.parentId == account.id }
		let folders = kids.filter { $0.role == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		let system = kids.filter { $0.role != nil }.sorted {
			(Self.roleOrder.firstIndex(of: $0.role ?? "") ?? 99) < (Self.roleOrder.firstIndex(of: $1.role ?? "") ?? 99)
		}
		return folders + system
	}

	/// A mailbox of the account in view, or (as `ViewMessageID`) of another account in an inbox view.
	func mailbox(_ id: String) -> Mailbox? {
		let parts = ViewMessageID.split(id)
		guard let account = parts.account else { return mailboxes.first { $0.id == id } }
		return mailboxes(of: account).first { $0.id == parts.message }
	}
	/// Everything in an inbox view is inbox mail, from accounts whose mailboxes are not loaded here.
	func role(of message: MessageSummary) -> String? {
		guard activeViewID != nil, let account = ViewMessageID.split(message.id).account else { return mailbox(message.mailboxId)?.role }
		return mailboxes(of: account).first { $0.id == message.mailboxId }?.role
	}

	func unreadCount(for item: SidebarItem) -> Int {
		switch item {
		case .allInboxes: activeView.map(unreadCount(of:)) ?? inboxUnread
		case .flagged: activeViewID == nil ? flaggedCount : 0
		case .mailbox(let id): mailbox(id).map { $0.role == "drafts" ? 0 : Int($0.unreadEmails) } ?? 0
		default: 0
		}
	}

	private func scopedTitle(_ base: String, all: String) -> String {
		if showsAllInboxes { return all }
		return currentInbox.map { "\(base) — \(label($0))" } ?? base
	}

	var title: String {
		if let view = activeView {
			let base: String? = switch sidebar {
			case .allDrafts: "Drafts"
			case .allSent: "Sent"
			case .allJunk: "Spam"
			case .allTrash: "Trash"
			case .allArchive: "Archive"
			case .flagged: "Flagged"
			case .smartToday: "Today"
			case .mailbox(let id): mailbox(id)?.name
			case .allInboxes, .vips, .remindMe: nil
			}
			return base.map { "\($0) — \(view.name)" } ?? view.name
		}
		switch sidebar {
		case .mailbox(let id):
			guard let box = mailbox(id) else { return "Mailflare" }
			let parent = box.parentId.flatMap(mailbox)?.name ?? ""
			return parent.isEmpty ? box.name : "\(box.name) — \(parent)"
		case .allInboxes: return scopedTitle("Inbox", all: "All Inboxes")
		case .vips: return "VIPs"
		case .flagged: return "Flagged"
		case .remindMe: return "Remind Me"
		case .allDrafts: return scopedTitle("Drafts", all: "All Drafts")
		case .allSent: return scopedTitle("Sent", all: "All Sent")
		case .allJunk: return scopedTitle("Spam", all: "All Spam")
		case .allTrash: return scopedTitle("Trash", all: "All Trash")
		case .allArchive: return scopedTitle("Archive", all: "All Archive")
		case .smartToday: return "Today"
		}
	}

	var subtitle: String { "\(total) message\(total == 1 ? "" : "s")" }

	// MARK: Listing (local store reads; the core keeps it current)

	/// The core folder that backs the sidebar item, or nil for items derived in memory.
	private var folder: Folder? {
		switch sidebar {
		case .allInboxes: scopedFolder("inbox")
		case .allDrafts: scopedFolder("drafts")
		case .allSent: scopedFolder("sent")
		case .allJunk: scopedFolder("junk")
		case .allTrash: scopedFolder("trash")
		case .allArchive: scopedFolder("archive")
		case .flagged: scopeID == nil ? .starred : nil
		case .mailbox(let id): .mailbox(id: id)
		case .vips, .remindMe, .smartToday: nil
		}
	}

	private func matchesSidebar(_ m: MessageSummary) -> Bool {
		switch sidebar {
		case .allInboxes: role(of: m) == "inbox" && inScope(m)
		case .allDrafts: role(of: m) == "drafts" && inScope(m)
		case .allSent: role(of: m) == "sent" && inScope(m)
		case .allJunk: role(of: m) == "junk" && inScope(m)
		case .allTrash: role(of: m) == "trash" && inScope(m)
		case .allArchive: role(of: m) == "archive" && inScope(m)
		case .flagged: m.flagged && inScope(m)
		case .mailbox(let id): m.mailboxId == id
		case .vips: vips.contains(m.fromEmail.lowercased()) && inScope(m)
		case .remindMe: reminders[m.id] != nil && inScope(m)
		case .smartToday: Calendar.current.isDateInToday(m.date) && inScope(m)
		}
	}

	func reload() {
		guard let core, account != nil else { return }
		if activeView != nil { reloadView(); return }
		let id = accountID
		let q = searchText.trimmingCharacters(in: .whitespaces)
		var list: [MessageSummary]
		var count: Int?
		do {
			if !q.isEmpty {
				list = try core.search(accountId: id, query: q, limit: 300).filter(matchesSidebar)
			} else if sidebar == .remindMe {
				list = reminders.keys.compactMap { try? core.messageSummary(accountId: id, messageId: $0) }.filter(inScope).sorted { $0.receivedAt > $1.receivedAt }
			} else if let folder, !unreadOnly {
				let page = try fetch(id, folder, limit: UInt32(pageLimit))
				list = page.list
				count = page.count
			} else {
				// Derived or filtered views scan a wide local window of the right folder.
				let source = folder ?? (sidebar == .flagged ? .starred : scopedFolder("inbox"))
				list = try fetch(id, source, limit: scanLimit).list.filter(matchesSidebar)
			}
		} catch {
			banner = describe(error)
			return
		}
		if unreadOnly { list = list.filter { !$0.seen } }
		messages = list
		total = count ?? list.count
	}

	/// The view lists what "All Inboxes" does, across its inboxes: the same sidebar item, read from
	/// each account's local store through the shared list cache, merged newest first. Each message id
	/// carries its account (`ViewMessageID`).
	private func reloadView() {
		guard let view = activeView else { return }
		let q = searchText.trimmingCharacters(in: .whitespaces)
		let item = sidebar

		/// Whether `box` of `account` is inside one of the view's inboxes.
		func inView(_ account: String, _ box: Mailbox) -> Bool {
			view.members.contains { $0.accountID == account && ($0.inboxID == nil || box.parentId == $0.inboxID) }
		}
		func matches(_ account: String, _ m: MessageSummary) -> Bool {
			guard let box = mailboxes(of: account).first(where: { $0.id == m.mailboxId }), inView(account, box) else { return false }
			switch item {
			case .allInboxes: return box.role == "inbox"
			case .allDrafts: return box.role == "drafts"
			case .allSent: return box.role == "sent"
			case .allJunk: return box.role == "junk"
			case .allTrash: return box.role == "trash"
			case .allArchive: return box.role == "archive"
			case .flagged: return m.flagged
			case .smartToday: return box.role == "inbox" && Calendar.current.isDateInToday(m.date)
			case .mailbox(let id): return ViewMessageID.split(id).message == m.mailboxId
			case .vips, .remindMe: return false
			}
		}

		let role: String? = switch item {
		case .allInboxes: "inbox"
		case .allDrafts: "drafts"
		case .allSent: "sent"
		case .allJunk: "junk"
		case .allTrash: "trash"
		case .allArchive: "archive"
		default: nil
		}
		// Role folders and single folders are paged from the store; the rest scan a wide window.
		var paged: [(account: String, folder: Folder)] = []
		var scanned: [(account: String, folder: Folder)] = []
		for account in view.accountIDs where accountList.contains(where: { $0.id == account }) {
			switch item {
			case .flagged: scanned.append((account, .starred))
			case .smartToday, .vips, .remindMe:
				for box in mailboxes(of: account) where box.role == "inbox" && inView(account, box) { scanned.append((account, .mailbox(id: box.id))) }
			case .mailbox(let id):
				let parts = ViewMessageID.split(id)
				if parts.account == account { paged.append((account, .mailbox(id: parts.message))) }
			default:
				for box in mailboxes(of: account) where box.role == role && inView(account, box) { paged.append((account, .mailbox(id: box.id))) }
			}
		}

		let filtered = !q.isEmpty || unreadOnly || !scanned.isEmpty
		var list: [MessageSummary] = []
		var count = 0
		do {
			if !q.isEmpty, let core {
				for account in view.accountIDs where accountList.contains(where: { $0.id == account }) {
					list += try core.search(accountId: account, query: q, limit: 300).filter { matches(account, $0) }.map { tag($0, account) }
				}
			} else {
				for source in paged {
					let page = try fetch(source.account, source.folder, limit: filtered ? scanLimit : UInt32(pageLimit))
					list += page.list.map { tag($0, source.account) }
					count += page.count
				}
				for source in scanned {
					list += try fetch(source.account, source.folder, limit: scanLimit).list.filter { matches(source.account, $0) }.map { tag($0, source.account) }
				}
			}
		} catch {
			banner = describe(error)
			return
		}
		if unreadOnly { list = list.filter { !$0.seen } }
		list.sort { $0.receivedAt > $1.receivedAt }
		if !filtered { list = Array(list.prefix(pageLimit)) }
		messages = list
		total = filtered ? list.count : count
	}

	private func tag(_ message: MessageSummary, _ account: String) -> MessageSummary {
		var tagged = message
		tagged.id = ViewMessageID.make(account: account, message: message.id)
		return tagged
	}

	// MARK: Local reads, shared

	/// What the local store returned for a folder, kept until mail changes. Every list (an inbox on its
	/// own, an inbox view, the sidebar counts) reads through these, so a folder already read for one is
	/// not read again for another. Nothing here touches the network: syncing fills the store.
	@ObservationIgnored private var listCache: [String: (limit: UInt32, list: [MessageSummary], count: Int)] = [:]
	@ObservationIgnored private var mailboxCache: [String: [Mailbox]] = [:]

	private func invalidateCaches() {
		listCache.removeAll()
		mailboxCache.removeAll()
	}

	private func fetch(_ accountID: String, _ folder: Folder, limit: UInt32) throws -> (list: [MessageSummary], count: Int) {
		guard let core else { return ([], 0) }
		let key = "\(accountID)|\(folder)"
		if let hit = listCache[key], hit.limit >= limit { return (Array(hit.list.prefix(Int(limit))), hit.count) }
		let list = try core.messages(accountId: accountID, folder: folder, offset: 0, limit: limit)
		let count = Int(try core.messageCount(accountId: accountID, folder: folder))
		listCache[key] = (limit, list, count)
		return (list, count)
	}

	/// Any saved account's mailboxes: the account in view from memory, the others from the store once.
	func mailboxes(of accountID: String) -> [Mailbox] {
		if accountID == account?.id { return mailboxes }
		if let cached = mailboxCache[accountID] { return cached }
		let loaded = (try? core?.mailboxes(accountId: accountID)) ?? []
		mailboxCache[accountID] = loaded
		return loaded
	}

	func loadMoreIfNeeded(current: MessageSummary) {
		if activeView != nil {
			guard messages.last?.id == current.id, searchText.isEmpty, !unreadOnly, messages.count < total else { return }
			pageLimit += pageSize
			reload()
			return
		}
		guard messages.last?.id == current.id, searchText.isEmpty, let core, let folder, !unreadOnly else { return }
		if messages.count < total {
			pageLimit += pageSize
			reload()
		} else if olderTask == nil {
			// Local window exhausted: ask the server for older mail.
			let id = accountID
			olderTask = Task {
				defer { olderTask = nil }
				if let n = try? await core.fetchOlder(accountId: id, folder: folder), n > 0 {
						invalidateCaches()
					pageLimit += pageSize
					reload()
				}
			}
		}
	}

	func sidebarChanged() {
		pageLimit = pageSize
		reload()
	}

	/// Re-derives `adaptColors` for the selected sender: their own choice, else the Settings default.
	func refreshAdaptColors() {
		adaptColors = MessageAppearance.adapts(sender: selectedMessage?.fromEmail ?? "")
	}

	func toggleAdaptColors() {
		adaptColors.toggle()
		if let sender = selectedMessage?.fromEmail { MessageAppearance.setAdapts(adaptColors, sender: sender) }
	}

	var selectedMessage: MessageSummary? { selectedID.flatMap { id in messages.first { $0.id == id } } }

	/// Whether Reply All would reach anyone beyond Reply: the reply target (Reply-To, else the
	/// sender) and every To/Cc recipient, less this account's own addresses, come to more than one.
	/// False until the body has loaded.
	var canReplyAll: Bool {
		guard let detail, detail.summary.id == selectedID else { return false }
		let mine = Set(identities(forAccount: owner(of: detail.summary.id).account).map { $0.email.lowercased() })
		let target = detail.replyTo.isEmpty ? [detail.summary.fromEmail] : detail.replyTo.map(\.email)
		let everyone = target + (detail.to + detail.cc).map(\.email)
		return Set(everyone.map { $0.lowercased() }).subtracting(mine).count > 1
	}

	// MARK: Selection and body

	func select(_ id: String?) {
		guard id != selectedID else { return }
		selectedID = id
		detail = nil
		refreshAdaptColors()
		detailTask?.cancel()
		markReadTask?.cancel()
		guard let id, let core else { return }
		if let m = messages.first(where: { $0.id == id }), !m.seen { scheduleMarkRead(id) }
		let (acct, raw) = owner(of: id)
		if let cached = try? core.cachedMessage(accountId: acct, messageId: raw) { detail = Self.tagged(cached, id: id); return }
		detailTask = Task { [weak self] in
			do {
				let d = try await core.loadMessage(accountId: acct, messageId: raw)
				if !Task.isCancelled, self?.selectedID == id { self?.detail = Self.tagged(d, id: id) }
			} catch { if !Task.isCancelled { self?.banner = describe(error) } }
		}
	}

	/// Marks an opened message read as the Reading setting says: at once, after a delay, or never.
	private func scheduleMarkRead(_ id: String) {
		let delay = ReadingSettings.markReadDelay
		if delay == 0 { setRead(id, true); return }
		guard delay > 0 else { return }
		markReadTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(delay))
			if !Task.isCancelled, self?.selectedID == id { self?.setRead(id, true) }
		}
	}

	// MARK: Actions (the core applies locally at once and replays them to the server)

	private func attempt(_ work: () throws -> Void) {
		invalidateCaches()
		do { try work() } catch { banner = describe(error) }
	}

	private func nextSelection(after id: String) -> String? {
		guard let i = messages.firstIndex(where: { $0.id == id }) else { return nil }
		return messages.indices.contains(i + 1) ? messages[i + 1].id : (i > 0 ? messages[i - 1].id : nil)
	}

	/// Runs a change that may remove the message from the current list, keeping a sensible selection.
	private func leaving(_ id: String, _ work: () throws -> Void) {
		let next = nextSelection(after: id)
		attempt(work)
		reload()
		refreshMailboxes()
		if selectedID == id, !messages.contains(where: { $0.id == id }) {
			selectedID = nil; detail = nil
			select(next)
		}
	}

	func setRead(_ id: String, _ read: Bool) {
		let (acct, raw) = owner(of: id)
		attempt { try core?.setSeen(accountId: acct, messageIds: [raw], seen: read) }
		if read { notifier.clear(messageID: raw) }
		reload(); refreshMailboxes()
	}

	func toggleFlag(_ id: String) {
		guard let m = messages.first(where: { $0.id == id }) else { return }
		let (acct, raw) = owner(of: id)
		leaving(id) { try core?.setFlagged(accountId: acct, messageIds: [raw], flagged: !m.flagged) }
	}

	func move(_ id: String, to box: Mailbox) {
		let (acct, raw) = owner(of: id)
		leaving(id) { _ = try core?.moveMessages(accountId: acct, messageIds: [raw], target: .mailbox(id: box.id)) }
	}

	func archive(_ id: String) { moveToRole(id, "archive") }
	func junk(_ id: String) { moveToRole(id, "junk") }
	private func moveToRole(_ id: String, _ role: String) {
		let (acct, raw) = owner(of: id)
		leaving(id) { _ = try core?.moveMessages(accountId: acct, messageIds: [raw], target: .role(role: role)) }
	}
	/// Moves to Trash, or deletes permanently from Trash and Drafts.
	func trash(_ id: String) {
		let (acct, raw) = owner(of: id)
		leaving(id) { _ = try core?.deleteMessages(accountId: acct, messageIds: [raw]) }
	}

	// VIPs and reminders live on this Mac only; the server has no such concept.

	func toggleVIP(_ address: EmailAddress) {
		let e = address.email.lowercased()
		if vips.contains(e) { vips.remove(e) } else { vips.insert(e) }
		UserDefaults.standard.set(Array(vips), forKey: "vips")
		if sidebar == .vips { reload() }
	}

	func isVIP(_ address: EmailAddress?) -> Bool { address.map { vips.contains($0.email.lowercased()) } ?? false }

	/// Senders blocked on this Mac: their mail is moved to Spam when blocked.
	private(set) var blockedSenders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "blockedSenders") ?? [])

	/// Blocks `address` and moves its messages in the list to Spam.
	func block(_ address: EmailAddress, messageID: String) {
		let email = address.email.lowercased()
		blockedSenders.insert(email)
		UserDefaults.standard.set(Array(blockedSenders), forKey: "blockedSenders")
		let ids = messages.filter { $0.fromEmail.lowercased() == email && role(of: $0) != "junk" }.map(\.id)
		for id in ids where id != messageID { junk(id) }
		junk(messageID)
		banner = "Blocked \(address.display)"
	}

	func remind(_ id: String, at date: Date?) {
		reminders[id] = date
		if date == nil { reminders.removeValue(forKey: id) }
		UserDefaults.standard.set(reminders.mapValues(\.timeIntervalSince1970), forKey: "reminders")
		if sidebar == .remindMe { reload() }
	}

	// MARK: Compose

	/// The message whose raw source is open in the Original Message popup.
	var original: MessageSummary?

	/// The raw message (headers and MIME body) and the cached file it came from. The core's
	/// attachment download takes `<message id>#raw` for this: the server's own blob on JMAP, a full
	/// fetch over IMAP.
	func loadOriginal(_ id: String) async throws -> (source: String, path: String) {
		guard let core else { throw CoreError.InvalidInput(message: "No account is open.") }
		let (acct, raw) = owner(of: id)
		let blob = Attachment(blobId: "\(raw)#raw", name: "original-\(raw).eml", mimeType: "message/rfc822", size: 0)
		let path = try await core.downloadAttachment(accountId: acct, attachment: blob)
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		return (String(decoding: data, as: UTF8.self), path)
	}

	/// A message put away with the composer's minimize button; the Compose button reopens it.
	var minimizedDraft: ComposeDraft?

	func minimize(_ draft: ComposeDraft) {
		minimizedDraft = draft
		compose = nil
	}

	func newMessage() {
		if let draft = minimizedDraft {
			minimizedDraft = nil
			compose = draft
			return
		}
		var d = ComposeDraft()
		d.identityID = (scopeID.flatMap { scope in identities.first { $0.id.hasPrefix(scope + "~") } } ?? identities.first)?.id
		d.body = profiles.signatureHTML(accountID)
		compose = d
	}

	private func draft(from t: ComposeTemplate, title: String, accountID acct: String) -> ComposeDraft {
		var d = ComposeDraft()
		d.title = title
		d.accountID = acct
		d.identityID = t.identityId ?? identities(forAccount: acct).first?.id
		d.to = Addresses.format(t.to); d.cc = Addresses.format(t.cc); d.bcc = Addresses.format(t.bcc)
		d.subject = t.subject
		d.inReplyTo = t.inReplyTo
		d.references = t.references
		d.attachments = t.attachments
		d.replacesDraftID = t.replacesDraftId
		// A saved draft already carries the signature it was written with.
		d.body = title == "Draft" || !t.bodyHtml.isEmpty ? t.bodyHtml : profiles.signatureHTML(acct)
		d.quotedHTML = t.quotedHtml
		return d
	}

	func reply(to id: String, all: Bool) { template(id, title: all ? "Reply All" : "Reply") { try await $0.composeTemplate(accountId: $1, messageId: $2, kind: all ? .replyAll : .reply) } }
	func forward(_ id: String) { template(id, title: "Forward") { try await $0.composeTemplate(accountId: $1, messageId: $2, kind: .forward) } }
	/// Opens a draft the assistant wrote as it was then, not as the saved draft is now.
	func openChatDraft(_ saved: ChatDraft) {
		var d = ComposeDraft()
		d.title = saved.isReply ? "Reply" : "New Message"
		d.accountID = saved.accountID
		d.identityID = saved.identityID
		d.to = saved.to; d.cc = saved.cc; d.bcc = saved.bcc
		d.subject = saved.subject
		d.body = saved.bodyHTML
		d.quotedHTML = saved.quotedHTML
		d.inReplyTo = saved.inReplyTo
		d.references = saved.references
		// Sending removes the saved copy; one already replaced or deleted is ignored.
		d.replacesDraftID = saved.draftID
		compose = d
	}

	func editDraft(_ id: String, title: String = "Draft") { template(id, title: title) { try await $0.draftTemplate(accountId: $1, messageId: $2) } }

	private func template(_ id: String, title: String, _ make: @escaping (MailCore, String, String) async throws -> ComposeTemplate) {
		guard let core else { return }
		let (acct, raw) = owner(of: id)
		Task {
			do { compose = draft(from: try await make(core, acct, raw), title: title, accountID: acct) } catch { banner = describe(error) }
		}
	}

	private func outgoing(_ d: ComposeDraft) throws -> OutgoingMessage {
		let available = identities(for: d)
		guard let identity = available.first(where: { $0.id == d.identityID }) ?? available.first else {
			throw CoreError.InvalidInput(message: "This account has no address to send from.")
		}
		return OutgoingMessage(
			identityId: identity.id, to: Addresses.parse(d.to), cc: Addresses.parse(d.cc), bcc: Addresses.parse(d.bcc),
			subject: d.subject, html: Self.html(of: d), inReplyTo: d.inReplyTo, references: d.references,
			attachments: d.attachments, replacesDraftId: d.replacesDraftID)
	}

	/// The body, then the quoted original below it.
	private static func html(of d: ComposeDraft) -> String {
		let body = d.body.isEmpty ? "<div><br></div>" : d.body
		return d.quotedHTML.isEmpty ? body : body + "<br>" + d.quotedHTML
	}

	let templates = ComposeTemplates()

	/// Queues the message in the core's outbox and returns at once; failures surface via the outbox event.
	func commit(_ draft: ComposeDraft, send: Bool) throws {
		guard let core else { return }
		let message = try outgoing(draft)
		invalidateCaches()
		let acct = draft.accountID ?? accountID
		if send {
			guard !message.to.isEmpty else { throw CoreError.InvalidInput(message: "Add at least one valid recipient.") }
			_ = try core.send(accountId: acct, message: message)
			showToast("Sending…", detail: message.subject, icon: .send, isProgress: true, duration: 8)
		} else {
			_ = try core.saveDraft(accountId: acct, message: message)
			showToast("Draft saved", detail: message.subject, icon: .check)
		}
		compose = nil
	}

	func showToast(_ title: String, detail: String = "", icon: AppIcon, isProgress: Bool = false, duration: Double = 3) {
		let item = Toast(title: title, detail: detail, icon: icon, isProgress: isProgress)
		toast = item
		toastTask?.cancel()
		toastTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(duration))
			if !Task.isCancelled, self?.toast?.id == item.id { self?.toast = nil }
		}
	}

	func suggestions(_ prefix: String) -> [EmailAddress] {
		guard let core, prefix.count >= 2 else { return [] }
		return (try? core.suggestContacts(accountId: accountID, prefix: prefix, limit: 5)) ?? []
	}

	// MARK: Attachments

	func save(_ attachment: Attachment) {
		guard let core else { return }
		let acct = selectedID.map { owner(of: $0).account } ?? accountID
		Task {
			do {
				let path = try await core.downloadAttachment(accountId: acct, attachment: attachment)
				let panel = NSSavePanel()
				panel.nameFieldStringValue = attachment.displayName
				if panel.runModal() == .OK, let url = panel.url {
					try? FileManager.default.removeItem(at: url)
					try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
				}
			} catch { banner = describe(error) }
		}
	}
}

extension String {
	var htmlEscaped: String {
		replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
	}
}
