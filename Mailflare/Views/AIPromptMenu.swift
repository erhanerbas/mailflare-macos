import SwiftUI
import MailflareCore

/// The AI button at the start of the reply box's toolbar. It opens a list of prompts above the button,
/// its bottom edge on the button's top; choosing one rewrites the reply with it. The last row adds a
/// prompt of the user's own.
struct AIPromptMenu: View {
	@Environment(MailStore.self) private var store

	let controller: ComposerController
	/// The reply as it stands, as HTML.
	let html: String
	let message: MessageSummary
	var iconSize: CGFloat
	/// Shared with the reply box, which must not fold while the list is open or a rewrite is running.
	@Binding var isOpen: Bool
	@Binding var isRunning: Bool

	/// The popup for a new prompt (nil target) or an edited one.
	@State private var showEditor = false
	@State private var editTarget: AIPrompt?
	@State private var task: Task<Void, Never>?
	@State private var anchor: CGRect = .zero

	private var library: AIPromptLibrary { store.aiPrompts }

	var body: some View {
		TitlebarIconButton(
			icon: .sparkles, help: isRunning ? "Rewriting…" : "Rewrite with AI",
			isActive: isOpen, isEnabled: !isRunning, iconSize: iconSize, isLoading: isRunning
		) { withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() } }
		.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("mailflareRoot")) } action: { anchor = $0; if isOpen { present() } }
		// The list is drawn by the window's root view, so nothing can cover it.
		.onChange(of: isOpen) { _, open in if open { present() } else { store.overlayMenu = nil } }
		.onDisappear { store.overlayMenu = nil }
		.sheet(isPresented: $showEditor) { AIPromptEditor(editing: editTarget) }
	}

	private func present() {
		store.overlayMenu = MailStore.OverlayMenu(
			anchor: anchor,
			content: AnyView(AIPromptList(run: run, edit: openEditor)),
			dismiss: { withAnimation(.snappy(duration: 0.2)) { isOpen = false } })
	}

	private func openEditor(_ prompt: AIPrompt?) {
		withAnimation(.snappy(duration: 0.2)) { isOpen = false }
		editTarget = prompt
		showEditor = true
	}

	private func run(_ prompt: AIPrompt) {
		withAnimation(.snappy(duration: 0.2)) { isOpen = false }
		let text = PreviewText.plain(html).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !isRunning, !text.isEmpty else {
			if text.isEmpty { store.banner = "Write something in the reply first; AI rewrites what is there." }
			return
		}
		guard let client = store.ai.writerClient(providerID: prompt.providerID, model: prompt.model) else {
			store.banner = "Add an AI provider in Settings to rewrite replies."
			return
		}
		var draft = ComposeDraft()
		draft.subject = "Re: \(message.subject)"
		draft.to = message.fromEmail
		draft.body = html
		draft.quotedHTML = store.detail.flatMap { $0.summary.id == message.id ? $0.html : nil } ?? ""
		let instructions = store.ai.writerInstructions
		let instruction = "\(prompt.prompt)\nReturn the whole revised reply. Keep the same language unless asked to change it."
		isRunning = true
		task = Task {
			defer { isRunning = false }
			do {
				let result = try await AIWriter.write(client: client, prompt: instruction, draft: draft, instructions: instructions)
				guard !Task.isCancelled else { return }
				controller.replaceAll(html: result)
			} catch is CancellationError {
			} catch {
				store.banner = "AI couldn't rewrite your reply: \((error as? AIError)?.message ?? error.localizedDescription)"
			}
		}
	}
}

/// The popup that adds a rewrite prompt: its name, the instruction, and the model to run it on.
struct AIPromptEditor: View {
	@Environment(MailStore.self) private var store
	@Environment(\.dismiss) private var dismiss

	/// The prompt being edited; nil adds a new one.
	var editing: AIPrompt?

	@State private var name = ""
	@State private var prompt = ""
	/// "" follows AI Writer's model; otherwise "providerID|model".
	@State private var modelChoice = ""
	@FocusState private var nameFocused: Bool

	private var isValid: Bool {
		!name.trimmingCharacters(in: .whitespaces).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	var body: some View {
		ModalScaffold(title: editing == nil ? "New AI Prompt" : "Edit AI Prompt", width: 440) {
			VStack(alignment: .leading, spacing: 16) {
				VStack(alignment: .leading, spacing: 6) {
					label("Name")
					TextField("Make it firmer", text: $name)
						.textFieldStyle(.card)
						.focused($nameFocused)
				}
				VStack(alignment: .leading, spacing: 6) {
					label("Prompt")
					TextField("Rewrite the reply so it declines politely but firmly…", text: $prompt, axis: .vertical)
						.lineLimit(4...10)
						.textFieldStyle(.card)
				}
				VStack(alignment: .leading, spacing: 6) {
					label("AI model")
					Picker("", selection: $modelChoice) {
						Text("Same as AI Writer").tag("")
						ForEach(store.ai.readyProviders) { provider in
							ForEach(provider.choices, id: \.self) { model in
								Text(store.ai.readyProviders.count > 1 ? "\(provider.name) · \(model)" : model).tag("\(provider.id)|\(model)")
							}
						}
					}
					.labelsHidden()
					.pickerStyle(.menu)
				}
			}
		} footer: {
			HStack(spacing: 8) {
				Spacer()
				Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
				Button(editing == nil ? "Add" : "Save") { save() }.buttonStyle(.pillProminent).disabled(!isValid).keyboardShortcut(.defaultAction)
			}
		}
		.onAppear {
			nameFocused = true
			guard let editing else { return }
			name = editing.name
			prompt = editing.prompt
			if let provider = editing.providerID, let model = editing.model { modelChoice = "\(provider)|\(model)" }
		}
	}

	private func label(_ text: String) -> some View {
		Text(text).font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
	}

	private func save() {
		let parts = modelChoice.split(separator: "|", maxSplits: 1).map(String.init)
		var result = editing ?? AIPrompt(name: "", prompt: "")
		result.name = name.trimmingCharacters(in: .whitespaces)
		result.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		result.providerID = parts.count == 2 ? parts[0] : nil
		result.model = parts.count == 2 ? parts[1] : nil
		if editing == nil { store.aiPrompts.add(result) } else { store.aiPrompts.update(result) }
		dismiss()
	}
}

/// The prompts, as a dropdown card. Reads the library itself, so editing or deleting a prompt updates it.
private struct AIPromptList: View {
	@Environment(MailStore.self) private var store
	var run: (AIPrompt) -> Void
	var edit: (AIPrompt?) -> Void

	var body: some View {
		DropdownCard(width: 250, anchor: .bottomLeading) {
			if !store.ai.isConfigured {
				Text("Add an AI provider in Settings to rewrite replies.")
					.font(Typography.notice).foregroundStyle(.secondary)
					.padding(.horizontal, 10).padding(.vertical, 8)
					.fixedSize(horizontal: false, vertical: true)
			} else {
				DropdownLabel(title: "Rewrite reply")
				ForEach(store.aiPrompts.prompts) { prompt in
					DropdownRow(label: prompt.name, onDelete: { store.aiPrompts.remove(prompt.id) }, onEdit: { edit(prompt) }) { run(prompt) }
				}
			}
			DropdownDivider()
			DropdownRow(label: "Add your own prompt…", icon: .add) { edit(nil) }
		}
	}
}

/// Draws `MailStore.OverlayMenu` over the whole window: a click anywhere else dismisses it, and its
/// bottom edge sits just above the anchor.
struct OverlayMenuHost: View {
	let menu: MailStore.OverlayMenu
	@State private var height: CGFloat = 0

	var body: some View {
		ZStack(alignment: .topLeading) {
			Color.clear.contentShape(Rectangle()).onTapGesture(perform: menu.dismiss)
			menu.content
				.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
				.offset(x: max(8, menu.anchor.minX), y: menu.anchor.minY - height - 6)
				.opacity(height > 0 ? 1 : 0)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
