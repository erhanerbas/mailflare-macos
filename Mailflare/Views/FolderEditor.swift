import SwiftUI
import MailflareCore

/// The popup for a folder (a label on Gmail): name a new one, rename one, or confirm deleting one.
struct FolderEditor: View {
	let request: MailStore.FolderRequest

	@Environment(MailStore.self) private var store
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@FocusState private var nameFocused: Bool

	private var support: FolderSupport? { store.folderSupport(accountID: request.accountID) }
	private var noun: String { support?.noun ?? "folder" }

	private var mailbox: Mailbox? {
		switch request.kind {
		case .create: nil
		case let .rename(box), let .delete(box): box
		}
	}

	private var isDelete: Bool {
		if case .delete = request.kind { return true }
		return false
	}

	private var title: String {
		switch request.kind {
		case .create: "New \(noun.capitalized)"
		case .rename: "Rename \(noun.capitalized)"
		case .delete: "Delete \(noun.capitalized)"
		}
	}

	private var actionTitle: String {
		switch request.kind {
		case .create: "Create"
		case .rename: "Rename"
		case .delete: "Delete"
		}
	}

	private var canSubmit: Bool {
		if isDelete { return true }
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		return !trimmed.isEmpty && trimmed != mailbox?.name
	}

	var body: some View {
		ModalScaffold(title: title, width: 380) {
			VStack(alignment: .leading, spacing: 12) {
				if isDelete, let mailbox {
					Text("Delete \"\(mailbox.name)\"?").font(Typography.body.weight(.medium))
					if let note = support?.deleteNote {
						Text(note).font(Typography.notice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
					}
				} else {
					VStack(alignment: .leading, spacing: 6) {
						Text("Name").font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
						TextField(noun.capitalized + " name", text: $name)
							.textFieldStyle(.card)
							.focused($nameFocused)
							.onSubmit(submit)
					}
				}
			}
		} footer: {
			HStack(spacing: 8) {
				Spacer()
				Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
				Button(actionTitle, action: submit)
					.buttonStyle(.pillProminent)
					.foregroundStyle(isDelete ? Color.red : Color.primary)
					.disabled(!canSubmit)
					.keyboardShortcut(.defaultAction)
			}
		}
		.onAppear {
			if case let .rename(box) = request.kind { name = box.name.components(separatedBy: " / ").last ?? box.name }
			nameFocused = true
		}
	}

	/// The change shows in the sidebar at once and the popup closes; the store reports a failure later.
	private func submit() {
		guard canSubmit else { return }
		switch request.kind {
		case let .create(parentID): store.createFolder(accountID: request.accountID, parentID: parentID, name: name)
		case let .rename(box): store.renameFolder(accountID: request.accountID, mailbox: box, name: name)
		case let .delete(box): store.deleteFolder(accountID: request.accountID, mailbox: box)
		}
		dismiss()
	}
}
