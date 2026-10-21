import SwiftUI
import MailflareCore

/// The "Original Message" popup: the message's details, taken from its headers, and the full source.
struct OriginalMessageView: View {
	@Environment(MailStore.self) private var store
	@Environment(\.dismiss) private var dismiss
	let message: MessageSummary

	@State private var phase = Phase.loading
	@State private var copied = false
	@State private var height: CGFloat = OriginalMessageView.fittingHeight()

	private enum Phase {
		case loading
		case failed(String)
		case loaded(source: String, path: String, summary: MessageSourceSummary)
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				VStack(alignment: .leading, spacing: 2) {
					Text("Original Message").font(Typography.bodySemibold)
					Text("Message details and full source, including headers and MIME body.")
						.font(Typography.meta).foregroundStyle(.secondary)
				}
				Spacer()
				TitlebarIconButton(icon: .cancel, help: "Close") { dismiss() }
			}
			.padding(.horizontal, 12).padding(.leading, 4).padding(.vertical, 10)
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.horizontal, 16)

			switch phase {
			case .loading:
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text("Loading source…").font(Typography.body).foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			case .failed(let reason):
				Text(reason).font(Typography.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
					.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
			case .loaded(let source, let path, let summary):
				VStack(spacing: 14) {
					details(summary)
					HStack {
						Button { download(path) } label: { HStack(spacing: 5) { HIcon(.attachment, size: 13); Text("Download Original") } }
							.buttonStyle(.pill)
						Spacer()
						Button { copy(source) } label: { HStack(spacing: 5) { HIcon(copied ? .check : .drafts, size: 13); Text(copied ? "Copied" : "Copy to clipboard") } }
							.buttonStyle(.pillProminent)
					}
					SourceTextView(text: source)
						.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
						.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				}
				.padding(16)
			}
		}
		.frame(width: 760, height: height)
		.background(AppTheme.background)
		.task(id: message.id) { await load() }
	}

	/// The headline rows, one bordered group with a rule between rows.
	private func details(_ s: MessageSourceSummary) -> some View {
		VStack(spacing: 0) {
			row("Message ID", s.messageID, tint: s.messageID != nil ? .green : nil)
			rule
			row("Created at", s.createdAt)
			rule
			row("From", s.from)
			rule
			row("To", s.to)
			rule
			row("Subject", s.subject)
			rule
			authRow("SPF", s.spf)
			rule
			authRow("DKIM", s.dkim)
			rule
			authRow("DMARC", s.dmarc)
		}
		.padding(.horizontal, 14)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
	}

	private var rule: some View { Rectangle().fill(AppTheme.cardStroke).frame(height: 1) }

	private func row(_ title: String, _ value: String?, tint: Color? = nil) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 16) {
			Text(title).font(Typography.notice.weight(.medium)).frame(width: 100, alignment: .leading)
			Text(value?.isEmpty == false ? value! : "Unavailable")
				.font(Typography.notice)
				.foregroundStyle(value?.isEmpty == false ? (tint ?? Color.primary) : Color.secondary)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(.vertical, 8)
	}

	private func authRow(_ title: String, _ result: MessageSourceSummary.Authentication?) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 16) {
			Text(title).font(Typography.notice.weight(.medium)).frame(width: 100, alignment: .leading)
			HStack(spacing: 6) {
				if result?.passed == true { HIcon(.check, size: 13).foregroundStyle(.green) }
				Text(result?.text ?? "No result in message headers").font(Typography.notice)
					.foregroundStyle(result == nil ? Color.secondary : Color.primary)
					.textSelection(.enabled)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(.vertical, 8)
	}

	private func load() async {
		phase = .loading
		copied = false
		do {
			let loaded = try await store.loadOriginal(message.id)
			phase = .loaded(source: loaded.source, path: loaded.path, summary: MessageSourceSummary(source: loaded.source))
		} catch {
			phase = .failed("Unable to load original message. \(describe(error))")
		}
	}

	private func copy(_ source: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(source, forType: .string)
		copied = true
		Task {
			try? await Task.sleep(for: .seconds(2))
			copied = false
		}
	}

	private func download(_ path: String) {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "original-\(message.id).eml"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		try? FileManager.default.removeItem(at: url)
		do { try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url) } catch { store.banner = describe(error) }
	}

	private static func fittingHeight() -> CGFloat {
		let window = (NSApp.mainWindow ?? NSApp.keyWindow)?.frame.height ?? 740
		return min(720, max(460, window - 80))
	}
}

/// The raw source: monospaced, selectable, scrolling both ways and never wrapped, so long header
/// lines stay as they are. A text view rather than `Text`, which would struggle with a large message.
private struct SourceTextView: NSViewRepresentable {
	let text: String

	func makeNSView(context: Context) -> NSScrollView {
		let scroll = NSTextView.scrollableTextView()
		scroll.drawsBackground = false
		scroll.hasHorizontalScroller = true
		guard let view = scroll.documentView as? NSTextView else { return scroll }
		view.isEditable = false
		view.isSelectable = true
		view.drawsBackground = false
		view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		view.textColor = .labelColor
		view.textContainerInset = NSSize(width: 10, height: 10)
		view.isHorizontallyResizable = true
		view.textContainer?.widthTracksTextView = false
		view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
		view.string = text
		return scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
		view.string = text
	}
}
