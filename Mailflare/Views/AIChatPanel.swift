import SwiftUI

/// The assistant, as a card on the window's trailing edge. The sparkles button in the title bar
/// opens and closes it; it only exists once an AI provider is set up.
struct AIChatPanel: View {
	static let width: CGFloat = 360

	@Environment(MailStore.self) private var store
	@State private var input = ""
	@State private var modelOpen = false
	@State private var modelQuery = ""
	/// The provider whose models the dropdown is showing, when there are several.
	@State private var modelProvider: String?
	@FocusState private var focused: Bool

	private var chat: AIChatModel { store.chat }
	private var isOpen: Bool { store.chatOpen }

	var body: some View {
		VStack(spacing: 0) {
			header
				.zIndex(10)
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
			conversation
			composer
		}
		.frame(width: Self.width)
		.background(AppTheme.background)
		.clipShape(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
		.onAppear { if isOpen { focused = true } }
		.task(id: store.currentAccountID) { chat.loadHistory(accountID: store.currentAccountID) }
		.onChange(of: isOpen) { _, open in if open { focused = true } else { modelOpen = false } }
		.onChange(of: modelOpen) { _, _ in modelQuery = ""; modelProvider = nil }
	}

	// MARK: Header

	private var header: some View {
		HStack(spacing: 8) {
			HIcon(.sparkles, size: 15).foregroundStyle(.secondary)
			Text("Assistant").font(.system(size: 15, weight: .semibold))
			Spacer(minLength: 8)
			modelMenu
			TitlebarIconButton(icon: .addCircle, help: "New chat", isEnabled: !chat.messages.isEmpty, tooltipTrailing: true) {
				chat.reset(); focused = true
			}
		}
		.padding(.horizontal, 16)
		.frame(height: PaneHeader.height)
	}

	/// The model in use, and a dropdown of every model of every configured provider.
	private var modelMenu: some View {
		Button { withAnimation(.snappy(duration: 0.2)) { modelOpen.toggle() } } label: {
			HStack(spacing: 5) {
				Text(store.ai.active?.model ?? "Model").font(Typography.meta.weight(.medium)).lineLimit(1).truncationMode(.middle)
				HIcon(.chevronDown, size: 11).rotationEffect(.degrees(modelOpen ? 180 : 0))
			}
			.foregroundStyle(modelOpen ? Color.primary : Color.secondary)
			.padding(.horizontal, 8).padding(.vertical, 5)
			.frame(maxWidth: 150)
			.background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(modelOpen ? AppTheme.rowHighlight : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.overlay(alignment: .topTrailing) {
			if modelOpen { modelDropdown.offset(y: 32) }
		}
		.clickAway(isActive: modelOpen) { withAnimation(.snappy(duration: 0.2)) { modelOpen = false } }
	}

	private func chooseModel(_ provider: AIProviderConfig, _ model: String) {
		store.ai.select(providerID: provider.id, model: model)
		withAnimation(.snappy(duration: 0.2)) { modelOpen = false }
	}

	private var modelDropdown: some View {
		// Everything the rows need is worked out once here, not per row.
		let q = modelQuery.trimmingCharacters(in: .whitespaces).lowercased()
		let activeKey = store.ai.active.map { "\($0.id)|\($0.model)" }
		let providers = store.ai.readyProviders
		// Several providers: pick one first, then its models. Searching looks through all of them.
		let drillProvider = providers.count > 1 ? providers.first { $0.id == modelProvider } : providers.first
		let showProviders = providers.count > 1 && drillProvider == nil && q.isEmpty
		let groups = providers
			.filter { q.isEmpty ? $0.id == drillProvider?.id : true }
			.map { (provider: $0, models: q.isEmpty ? $0.choices : $0.choices.filter { $0.lowercased().contains(q) }) }
			.filter { !$0.models.isEmpty }
		return DropdownCard(width: 260, anchor: .topTrailing) {
			if !showProviders {
				if providers.count > 1, q.isEmpty, let drillProvider {
					DropdownRow(label: drillProvider.name, icon: .arrowLeft) { withAnimation(.snappy(duration: 0.2)) { modelProvider = nil } }
					DropdownDivider()
				}
				DropdownSearchField(text: $modelQuery) {
					if let first = groups.first, let model = first.models.first { chooseModel(first.provider, model) }
				}
			}
			if showProviders {
				ForEach(providers) { provider in
					DropdownRow(label: provider.name, isSelected: provider.id == store.ai.active?.id, trailing: .chevronRight) {
						withAnimation(.snappy(duration: 0.2)) { modelProvider = provider.id }
					}
				}
			} else {
				// Lazy, like every long dropdown: only the rows near the viewport are built.
				DropdownScroll(target: q.isEmpty ? activeKey : nil) {
					if groups.isEmpty { DropdownNoResults() }
					ForEach(groups, id: \.provider.id) { group in
						if !q.isEmpty && providers.count > 1 { DropdownLabel(title: group.provider.name) }
						ForEach(group.models, id: \.self) { model in
							let key = "\(group.provider.id)|\(model)"
							DropdownRow(label: model, isSelected: key == activeKey) { chooseModel(group.provider, model) }
								.id(key)
						}
					}
				}
			}
			DropdownDivider()
			DropdownRow(label: "Manage Providers…", icon: .settings) {
				withAnimation(.snappy(duration: 0.2)) { modelOpen = false }
				store.settingsPage = .ai
			}
		}
	}

	// MARK: Conversation

	private var conversation: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 14) {
					if chat.messages.isEmpty { welcome }
					ForEach(chat.messages) { message in
						ChatMessageRow(message: message).id(message.id)
					}
					// While a request is unfinished there is always a running task or "Thinking…" in view.
					if chat.busy, chat.messages.last?.tools.contains(where: { $0.status == .running }) != true {
						HStack(spacing: 6) {
							ProgressView().controlSize(.mini).frame(width: 12, height: 12)
							Text("Thinking…").font(Typography.body).foregroundStyle(.secondary).lineSpacing(Typography.chatLineSpacing)
						}
					}
					Color.clear.frame(height: 1).id("bottom")
				}
				.padding(16)
			}
			.onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("bottom") }
			.onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom") } }
		}
	}

	private struct Prompt: Identifiable {
		let label: String, detail: String, prompt: String, icon: AppIcon
		var id: String { label }
	}

	/// Starters like the web assistant's: about the open email when there is one, else the mailbox.
	private var prompts: [Prompt] {
		if store.openEmailIDForAI != nil {
			return [
				Prompt(label: "Summarize this", detail: "Key points of the open thread", prompt: "Read this thread and summarize its key points.", icon: .summarize),
				Prompt(label: "Draft a reply", detail: "Write a reply for you to review", prompt: "Read this thread and draft a reply.", icon: .reply),
				Prompt(label: "List action items", detail: "What needs doing", prompt: "Read this thread and list the action items.", icon: .check),
			]
		}
		return [
			Prompt(label: "Summarize recent mail", detail: "What came in lately", prompt: "Summarize my recent email in this mailbox.", icon: .summarize),
			Prompt(label: "Reply to my latest email", detail: "Draft it for you to review", prompt: "Read my latest email and draft a reply.", icon: .reply),
			Prompt(label: "Find action items", detail: "Across recent mail", prompt: "Find action items in my recent email.", icon: .check),
		]
	}

	/// Rises and fades in when the panel opens, and back out when it closes; each block a beat later.
	private func entrance(_ step: Int) -> some ViewModifier {
		Entrance(isOpen: isOpen, step: step)
	}

	private var welcome: some View {
		VStack(alignment: .leading, spacing: 18) {
			VStack(alignment: .leading, spacing: 8) {
				Text("How can I help?").font(.system(size: 17, weight: .semibold))
				ForEach(Array(prompts.enumerated()), id: \.element.id) { index, item in
					Button { send(item.prompt) } label: {
						HStack(spacing: 10) {
							HIcon(item.icon, size: 16).foregroundStyle(.secondary).frame(width: 20)
							VStack(alignment: .leading, spacing: 1) {
								Text(item.label).font(Typography.bodySemibold)
								Text(item.detail).font(Typography.meta).foregroundStyle(.secondary)
							}
							Spacer(minLength: 0)
						}
						.padding(.horizontal, 12).padding(.vertical, 9)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.modifier(entrance(index))
				}
			}
			if !chat.history.isEmpty {
				VStack(alignment: .leading, spacing: 2) {
					Text("Recent conversations").font(Typography.meta.weight(.medium)).foregroundStyle(.secondary)
						.padding(.bottom, 4)
					ForEach(Array(chat.history.prefix(6).enumerated()), id: \.element.id) { index, saved in
						HistoryRow(chat: saved) { chat.open(saved) } onDelete: { chat.delete(saved) }
							.modifier(entrance(prompts.count + index))
					}
				}
			}
		}
		.padding(.bottom, 4)
	}

	// MARK: Input

	private var composer: some View {
		HStack(alignment: .bottom, spacing: 8) {
			TextField("Message the assistant", text: $input, axis: .vertical)
				.textFieldStyle(.plain).font(Typography.body)
				.lineLimit(1...6)
				.focused($focused)
				.onSubmit { send(input) }
				.padding(.vertical, 8)
			Button {
				if chat.busy { chat.stop() } else { send(input) }
			} label: {
				HIcon(chat.busy ? .cancel : .send, size: 15)
					.foregroundStyle(AppTheme.prominentPillText)
					.frame(width: 28, height: 28)
					.background(Circle().fill(AppTheme.prominentPillFill))
			}
			.buttonStyle(.plain)
			.disabled(!chat.busy && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			.opacity(!chat.busy && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
			.padding(.bottom, 6)
			.help(chat.busy ? "Stop" : "Send")
		}
		.padding(.horizontal, 12)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.padding(12)
	}

	private func send(_ text: String) {
		guard !chat.busy else { return }
		chat.send(text, store: store)
		input = ""
	}
}

/// Slides up and fades in when the panel opens (after the panel itself starts moving) and slides
/// down and fades out when it closes.
private struct Entrance: ViewModifier {
	var isOpen: Bool
	var step: Int
	/// A panel mounted already open (when it floats) still plays the entrance.
	@State private var appeared = false

	func body(content: Content) -> some View {
		let visible = isOpen && appeared
		content
			.opacity(visible ? 1 : 0)
			.offset(y: visible ? 0 : 24)
			.animation(visible ? .easeOut(duration: 0.35).delay(0.1 + 0.05 * Double(step)) : .easeIn(duration: 0.16), value: visible)
			.onAppear { appeared = true }
	}
}

private struct HistoryRow: View {
	var chat: SavedChat
	var open: () -> Void
	var onDelete: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: open) {
			HStack(spacing: 8) {
				VStack(alignment: .leading, spacing: 1) {
					Text(chat.title).font(Typography.body).lineLimit(1)
					Text(Self.formatter.localizedString(for: chat.updated, relativeTo: Date()))
						.font(Typography.meta).foregroundStyle(.secondary)
				}
				Spacer(minLength: 4)
				if isHovering {
					Button(action: onDelete) { HIcon(.trash, size: 13).foregroundStyle(.secondary) }
						.buttonStyle(.plain).help("Delete")
				}
			}
			.padding(.horizontal, 10).padding(.vertical, 6)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isHovering ? AppTheme.rowHighlight : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
	}

	private static let formatter: RelativeDateTimeFormatter = {
		let f = RelativeDateTimeFormatter()
		f.unitsStyle = .short
		return f
	}()
}

/// One message: the user's in a bubble, the assistant's as plain text with its tool activity above.
private struct ChatMessageRow: View {
	var message: ChatMessage

	var body: some View {
		switch message.role {
		case .user:
			Text(message.text).font(Typography.body).lineSpacing(Typography.chatLineSpacing).textSelection(.enabled)
				.padding(.horizontal, 12).padding(.vertical, 8)
				.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				.frame(maxWidth: .infinity, alignment: .trailing)
				.padding(.leading, 40)
				// Twice the 14pt gap the list puts between rows.
				.padding(.vertical, 14)
		case .assistant:
			VStack(alignment: .leading, spacing: 8) {
				ForEach(message.tools) { ToolRow(run: $0) }
				ForEach(Array(Self.segments(of: message.text).enumerated()), id: \.offset) { _, segment in
					if segment.isQuote {
						QuoteBlock(text: segment.text)
					} else {
						Text(Self.markdown(segment.text))
							.font(Typography.body)
							.lineSpacing(Typography.chatLineSpacing)
							.foregroundStyle(message.isError ? Color.orange : Color.primary)
							.textSelection(.enabled)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	/// The text split into prose and `>` quotes (drafted wording the model offers), in order.
	/// The marker is dropped from a quote's lines.
	private static func segments(of text: String) -> [(text: String, isQuote: Bool)] {
		var result: [(text: String, isQuote: Bool)] = []
		var lines: [String] = []
		var inQuote = false
		func flush() {
			var joined = lines.joined(separator: "\n")
			if inQuote { joined = joined.trimmingCharacters(in: .whitespacesAndNewlines) } else { joined = joined.trimmingCharacters(in: .newlines) }
			if !joined.trimmingCharacters(in: .whitespaces).isEmpty { result.append((joined, inQuote)) }
			lines = []
		}
		for line in text.components(separatedBy: "\n") {
			let trimmed = line.drop { $0 == " " }
			let quoted = trimmed.hasPrefix(">")
			if quoted != inQuote { flush(); inQuote = quoted }
			if quoted {
				var rest = trimmed.dropFirst()
				if rest.first == " " { rest = rest.dropFirst() }
				lines.append(String(rest))
			} else {
				lines.append(line)
			}
		}
		flush()
		return result
	}

	private static func markdown(_ text: String) -> AttributedString {
		(try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
	}
}

private struct ToolRow: View {
	@Environment(MailStore.self) private var store
	var run: ChatToolRun

	var body: some View {
		HStack(spacing: 8) {
			status
			if run.status == .done, let id = run.draftID {
				Button {
					if let saved = run.draft { store.openChatDraft(saved) } else { store.editDraft(id, title: run.name == "draft_reply" ? "Reply" : "New Message") }
				} label: {
					Text((run.draft?.isReply ?? (run.name == "draft_reply")) ? "Open reply" : "Open email")
						.font(Typography.meta.weight(.medium))
						.padding(.horizontal, 8).padding(.vertical, 2)
						.background(AppTheme.elevated, in: Capsule())
						.overlay(Capsule().stroke(AppTheme.outline, lineWidth: 1))
						.contentShape(Capsule())
				}
				.buttonStyle(.plain)
				.help("Open this draft in the composer")
			}
		}
	}

	private var status: some View {
		HStack(spacing: 6) {
			switch run.status {
			case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
			case .done: HIcon(.check, size: 12).foregroundStyle(.secondary).frame(width: 12, height: 12)
			case .failed: HIcon(.close, size: 12).foregroundStyle(.orange).frame(width: 12, height: 12)
			}
			Text(run.status == .failed ? "\(AIMailTools.activity(run.name, done: true)) failed" : AIMailTools.activity(run.name, done: run.status == .done))
				.font(Typography.body).foregroundStyle(.secondary).lineSpacing(Typography.chatLineSpacing)
		}
	}
}

/// Wording the assistant offers, set apart from its own prose, with a button to copy it.
private struct QuoteBlock: View {
	var text: String
	@State private var copied = false

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Text(text)
				.font(Typography.notice)
				.lineSpacing(Typography.chatLineSpacing - 1)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)
			Button {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(text, forType: .string)
				copied = true
				Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
			} label: {
				HIcon(copied ? .check : .copy, size: 13)
					.foregroundStyle(.secondary)
					.frame(width: 22, height: 22)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.help(copied ? "Copied" : "Copy")
		}
		.padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 10)
		.background(AppTheme.composerContextFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
	}
}
