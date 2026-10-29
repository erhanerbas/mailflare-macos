import AppKit
import SwiftUI
import MailflareCore

/// A contact's profile, opened from the reader's header: picture, name and description.
///
/// Mailflare servers have no contact endpoint a device key can use (see `ContactProfiles`), so all three
/// are kept on this Mac. The picture shown otherwise is the sender's Gravatar, or their initial.
struct ContactEditor: View {
	@Environment(MailStore.self) private var store
	@Environment(\.dismiss) private var dismiss

	let contact: EmailAddress

	@State private var name = ""
	@State private var note = ""
	@State private var message: String?

	private var key: String { AvatarCache.contactKey(contact.email) }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 14) {
				SenderAvatar(email: contact.email, name: name.isEmpty ? contact.display : name, size: 64)
				VStack(alignment: .leading, spacing: 6) {
					Text(contact.email).font(Typography.notice).foregroundStyle(.secondary).textSelection(.enabled)
					HStack(spacing: 8) {
						Button("Choose Picture…") { choosePicture() }.buttonStyle(.pill)
						// `images` is what the view observes; the file says whether the picture is ours.
						if store.avatars.images[key] != nil, store.avatars.hasLocal(key) {
							Button("Remove") { removePicture() }.buttonStyle(.pill)
						}
					}
				}
			}
			VStack(alignment: .leading, spacing: 4) {
				Text("Name").font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
				TextField(contact.display, text: $name)
					.textFieldStyle(.roundedBorder)
			}
			VStack(alignment: .leading, spacing: 4) {
				Text("Description").font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
				TextField("Company, role, how you know them…", text: $note, axis: .vertical)
					.lineLimit(3...6)
					.textFieldStyle(.roundedBorder)
			}
			if let message { Text(message).font(Typography.meta).foregroundStyle(.orange) }
			HStack {
				Text("Saved on this Mac.").font(Typography.meta).foregroundStyle(.tertiary)
				Spacer()
				Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
				Button("Save") { save() }.buttonStyle(.pillProminent).keyboardShortcut(.defaultAction)
			}
		}
		.padding(16)
		.frame(width: 340)
		.onAppear {
			name = store.contacts.name(for: contact.email) ?? ""
			note = store.contacts.note(for: contact.email)
		}
	}

	private func save() {
		store.contacts.save(email: contact.email, name: name, note: note)
		dismiss()
	}

	/// A picture chosen here is applied at once, like the one on the account settings page.
	private func choosePicture() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.image]
		panel.allowsMultipleSelection = false
		panel.message = "Choose a picture for \(contact.display)"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		message = store.avatars.setLocal(key: key, from: url) ? nil : "That file couldn't be read as a picture."
	}

	/// Back to the Gravatar (or the initial) once the chosen picture is dropped.
	private func removePicture() {
		store.avatars.removeLocal(key: key)
		store.avatars.loadContact(email: contact.email)
	}
}
