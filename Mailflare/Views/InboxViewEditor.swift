import SwiftUI
import MailflareCore

/// The popup that creates or edits an inbox view: a name, and the accounts and inboxes it lists.
struct InboxViewEditor: View {
	@Environment(MailStore.self) private var store
	@Environment(\.dismiss) private var dismiss

	@State private var view: InboxView
	@FocusState private var nameFocused: Bool
	private let isNew: Bool

	init(view: InboxView, isNew: Bool) {
		_view = State(initialValue: view)
		self.isNew = isNew
	}

	private struct Choice: Identifiable {
		let account: Account
		/// Several address inboxes are listed one by one; otherwise the account itself is the choice.
		let inboxes: [Mailbox]
		var id: String { account.id }
	}

	private var choices: [Choice] {
		store.accountList.map { account in
			let inboxes = store.inboxAddresses(of: account.id)
			return Choice(account: account, inboxes: inboxes.count > 1 ? inboxes : [])
		}
	}

	private var canSave: Bool {
		!view.name.trimmingCharacters(in: .whitespaces).isEmpty && !view.members.isEmpty
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(isNew ? "New Inbox View" : "Edit Inbox View")
					.font(Typography.bodySemibold).frame(maxWidth: .infinity, alignment: .leading)
				TitlebarIconButton(icon: .cancel, help: "Close") { dismiss() }
			}
			.padding(.horizontal, 12).padding(.leading, 4).padding(.vertical, 10)
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.horizontal, 16)

			VStack(alignment: .leading, spacing: 14) {
				VStack(alignment: .leading, spacing: 6) {
					Text("Inbox name").font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
					TextField("Work, Personal, …", text: $view.name)
						.textFieldStyle(.card)
						.focused($nameFocused)
						.onSubmit { if canSave { save() } }
				}
				VStack(alignment: .leading, spacing: 6) {
					Text("Show mail from").font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
					ScrollView {
						VStack(alignment: .leading, spacing: 2) {
							ForEach(choices) { choice in accountRows(choice) }
						}
						.padding(6)
					}
					.frame(height: 250)
					.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				}
				HStack(spacing: 8) {
					if !isNew {
						Button("Delete") { store.deleteInboxView(view.id); dismiss() }
							.buttonStyle(.pill).foregroundStyle(.red)
					}
					Spacer()
					Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
					Button(isNew ? "Create" : "Save") { save() }
						.buttonStyle(.pillProminent).disabled(!canSave).keyboardShortcut(.defaultAction)
				}
			}
			.padding(16)
		}
		.frame(width: 420)
		.background(AppTheme.background)
		.onAppear { nameFocused = true }
	}

	@ViewBuilder
	private func accountRows(_ choice: Choice) -> some View {
		let account = choice.account
		if choice.inboxes.isEmpty {
			checkRow(isOn: binding(.init(accountID: account.id, inboxID: nil)), account: account.id, inbox: nil,
					 title: store.accountName(account), subtitle: account.email, indent: false)
		} else {
			checkRow(isOn: accountBinding(choice), account: account.id, inbox: nil,
					 title: store.accountName(account), subtitle: "\(account.email) (\(choice.inboxes.count) inboxes)", indent: false)
			ForEach(choice.inboxes) { inbox in
				checkRow(isOn: binding(.init(accountID: account.id, inboxID: inbox.id)), account: account.id, inbox: inbox,
						 title: store.label(inbox), subtitle: inbox.inboxEmail, indent: true)
			}
		}
	}

	private func checkRow(isOn: Binding<Bool>, account: String, inbox: Mailbox?, title: String, subtitle: String, indent: Bool) -> some View {
		Toggle(isOn: isOn) {
			HStack(spacing: 10) {
				ProfileAvatar(key: AvatarCache.key(account: account, mailbox: inbox?.id), name: title, size: indent ? 24 : 28)
				VStack(alignment: .leading, spacing: 1) {
					Text(title).font(.system(size: indent ? 13 : 14, weight: indent ? .medium : .semibold)).lineLimit(1)
					Text(subtitle).font(Typography.meta).foregroundStyle(.secondary).lineLimit(1)
				}
				Spacer(minLength: 0)
			}
			.contentShape(Rectangle())
		}
		.toggleStyle(.checkbox)
		.padding(.leading, indent ? 28 : 6).padding(.trailing, 6).padding(.vertical, 5)
	}

	private func binding(_ member: InboxView.Member) -> Binding<Bool> {
		Binding(
			get: { view.members.contains(member) },
			set: { on in
				view.members.removeAll { $0 == member }
				if on { view.members.append(member) }
			})
	}

	/// An account with several inboxes: on when all of them are, and choosing it picks or clears them all.
	private func accountBinding(_ choice: Choice) -> Binding<Bool> {
		let all = choice.inboxes.map { InboxView.Member(accountID: choice.account.id, inboxID: $0.id) }
		return Binding(
			get: { all.allSatisfy { view.members.contains($0) } },
			set: { on in
				view.members.removeAll { all.contains($0) }
				if on { view.members.append(contentsOf: all) }
			})
	}

	private func save() {
		var saved = view
		saved.name = saved.name.trimmingCharacters(in: .whitespaces)
		// Drop inboxes of accounts that were signed out since.
		let known = Set(store.accountList.map(\.id))
		saved.members.removeAll { !known.contains($0.accountID) }
		store.saveInboxView(saved)
		if isNew { store.selectView(saved.id) }
		dismiss()
	}
}
