import SwiftUI
import WebKit
import MailflareCore

struct ReaderView: View {
	@Environment(MailStore.self) private var store

	var body: some View {
		if store.multiSelection.count > 1 {
			EmptyStateView(icon: .inbox, title: "\(store.multiSelection.count) Messages Selected", message: "Right-click to archive, flag or delete them together.")
				.background(AppTheme.background)
		} else if let message = store.selectedMessage {
			MessageDetail(message: message).id(message.id)
		} else {
			EmptyStateView(icon: .inbox, title: "No Message Selected")
				.background(AppTheme.background)
		}
	}
}

private struct MessageDetail: View {
	@Environment(MailStore.self) private var store
	let message: MessageSummary
	@Environment(\.colorScheme) private var colorScheme
	@State private var showDetails = false
	/// The AI summary saved with this message, kept in the store so the toolbar button can make it.
	private var summary: String? { store.summaries[message.id] }
	/// Whether this sender's mail is re-colored for the dark window; the toolbar's colors button sets it.
	private var adapts: Bool { store.adaptColors }
	/// The Settings default; changing it re-derives `adapts` for the open message.
	@AppStorage(MessageAppearance.adaptKey) private var adaptByDefault = true

	/// The message body's height once laid out; the web view is sized to it so the header, the body
	/// and the attachments scroll together as one page.
	@State private var webHeight: CGFloat = 0
	/// Remote content the user allowed for this message alone, where the settings would block it.
	@State private var loadRemoteOnce = false
	@AppStorage(ReadingSettings.loadRemoteContentKey) private var loadRemoteContent = true

	init(message: MessageSummary) {
		self.message = message
	}

	/// The dark-only toggle shows when the body has no dark styles of its own to defer to.
	private func needsAdapting(_ html: String) -> Bool {
		colorScheme == .dark && !MessageAppearance.supportsDark(html)
	}

	private func mode(for html: String) -> MessageWebView.Mode {
		guard needsAdapting(html) else { return .asIs }
		return adapts ? .adapted : .original
	}

	private var isJunk: Bool { store.role(of: message) == "junk" }
	/// Remote images and styles load when Settings allow it, except in Junk. Where blocked (they can
	/// track opens), a button loads them for the one message.
	private var allowsRemote: Bool { (loadRemoteContent && !isJunk) || loadRemoteOnce }

	var body: some View {
		VStack(spacing: 0) {
			content
			// Held below the message as it scrolls; a draft is edited, not replied to.
			if store.role(of: message) != "drafts" { QuickReplyBox(message: message) }
		}
		.background(AppTheme.background)
		.task { store.loadSavedSummary(for: message.id) }
		.onChange(of: adaptByDefault) { _, _ in store.refreshAdaptColors() }
	}

	private var content: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				VStack(alignment: .leading, spacing: 12) {
					header
					if let summary { summaryCard(summary) }
					if let error = store.summaryError { Text(error).font(Typography.meta).foregroundStyle(.orange) }
				}
				.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

				if store.detail == nil { bodySkeleton }
				if let body = store.detail {
					if body.hasRemoteContent && !allowsRemote {
						remoteContentNotice
					}
					MessageWebView(html: body.html, mode: mode(for: body.html), allowsRemote: allowsRemote, contentHeight: $webHeight)
						.frame(height: max(webHeight, 40))
					if !body.attachments.isEmpty {
						Divider().overlay(AppTheme.cardStroke)
						ScrollView(.horizontal) {
							HStack(spacing: 8) {
								ForEach(body.attachments) { a in
									Button { store.save(a) } label: {
										HStack(spacing: 6) {
											HIcon(.attachment, size: 14)
											Text(a.displayName).font(Typography.notice).lineLimit(1)
											Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
												.font(Typography.meta).foregroundStyle(.secondary)
										}
										.noticeSurface(radius: 10)
									}
									.buttonStyle(.light).help("Save \(a.displayName)…")
								}
							}
							.padding(12)
						}
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	/// Stands in for the message while its body loads: four lines of text.
	private var bodySkeleton: some View {
		VStack(alignment: .leading, spacing: 9) {
			ForEach(Array([1.0, 0.96, 0.9, 0.55].enumerated()), id: \.offset) { _, fraction in
				GeometryReader { proxy in SkeletonBar(width: proxy.size.width * fraction, height: 13) }.frame(height: 13)
			}
		}
		.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 20)
		.accessibilityLabel("Loading message")
	}

	private var remoteContentNotice: some View {
		HStack(spacing: 10) {
			Text(isJunk ? "Remote content is blocked in Junk." : "Remote content is blocked.")
				.font(Typography.notice).foregroundStyle(.secondary)
			Spacer(minLength: 8)
			Button("Load Remote Content") { loadRemoteOnce = true }.buttonStyle(.pill)
		}
		.noticeSurface(radius: 12)
		.padding(.horizontal, 20).padding(.vertical, 4)
	}

	/// The saved AI summary, in a bordered container above the content.
	private func summaryCard(_ text: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				HIcon(.aiContent, size: 13)
				Text("Summary").font(Typography.meta.weight(.medium))
			}
			.foregroundStyle(.secondary)
			Text(text).font(Typography.body).textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(12)
		.background(AppTheme.composerContextFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.outline, lineWidth: 1))
	}

	/// The sender and recipients, each with their address beside their name.
	private var header: some View {
		let to = store.detail?.to ?? []
		let cc = store.detail?.cc ?? []
		return HStack(alignment: .top, spacing: 10) {
			Avatar(contact: message.sender)
			VStack(alignment: .leading, spacing: 3) {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					senderLine
					Spacer(minLength: 8)
					if store.role(of: message) == "drafts" {
						Button("Edit Draft") { store.editDraft(message.id) }.buttonStyle(.pill)
					}
					if message.hasAttachment { HIcon(.attachment, size: 13).foregroundStyle(.secondary) }
					if message.flagged { HIcon(.flag, size: 13).foregroundStyle(.orange) }
					Text(MailDate.full(message.date))
						.font(Typography.meta).foregroundStyle(.secondary).lineLimit(1).fixedSize()
				}
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					if store.detail == nil {
						// Recipients arrive with the body.
						SkeletonBar(width: 220, height: 10).padding(.vertical, 3)
					} else {
						Text(recipientLine(to: to, cc: cc))
							.font(Typography.notice).foregroundStyle(.secondary)
							.lineLimit(showDetails ? nil : 1).truncationMode(.tail)
							.textSelection(.enabled)
						// Right after the last recipient, not at the far edge.
						Button(showDetails ? "Hide" : "Details") { showDetails.toggle() }
							.buttonStyle(.light).font(Typography.notice).foregroundStyle(Color.accentColor)
							.fixedSize()
					}
					Spacer(minLength: 0)
				}
				if showDetails {
					VStack(alignment: .leading, spacing: 2) {
						Text("From: \(message.sender.formatted)")
						Text("Date: \(message.date.formatted(date: .complete, time: .shortened))")
					}
					.font(Typography.meta).foregroundStyle(.secondary).textSelection(.enabled)
				}
			}
		}
	}

	/// "Name  address", the name bold and the address quieter; just the address when there is no name.
	private var senderLine: some View {
		let name = message.senderDisplay
		let address = message.fromEmail
		let named = !name.isEmpty && name.lowercased() != address.lowercased()
		return (Text(named ? name : address).font(Typography.bodySemibold)
			+ Text(named ? "  \(address)" : "").font(Typography.notice).foregroundStyle(.secondary))
			.lineLimit(1).truncationMode(.tail).textSelection(.enabled)
	}

	/// "To: Name <address>, …" and "Cc: …", every recipient with its address.
	private func recipientLine(to: [EmailAddress], cc: [EmailAddress]) -> String {
		var s = "To: " + to.map(\.formatted).joined(separator: ", ")
		if !cc.isEmpty { s += "   Cc: " + cc.map(\.formatted).joined(separator: ", ") }
		return s
	}
}

struct Avatar: View {
	let contact: EmailAddress
	var size: CGFloat = 32

	var body: some View {
		Text(contact.initials)
			.font(.system(size: size * 0.38, weight: .semibold))
			.foregroundStyle(.primary)
			.frame(width: size, height: size)
			.background(AppTheme.railSelection, in: Circle())
	}
}

/// A web view that never scrolls on its own: scroll gestures go to the scroll view around it, and
/// it reports its content's height so it can be sized to show all of it.
private final class PassthroughWebView: WKWebView {
	override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// Renders mail HTML with JavaScript off. Remote images, styles and fonts load only when
/// `allowsRemote` is set; otherwise a CSP blocks every remote load. (The height is read
/// with a script the app runs itself; that is not the page's JavaScript, which stays off.)
struct MessageWebView: NSViewRepresentable {
	/// `asIs` follows the app theme (light mode, or mail with its own dark styles); `adapted` runs
	/// `MessageAppearance`'s re-coloring; `original` shows the sender's light design on a white page.
	enum Mode { case asIs, adapted, original }

	let html: String
	let mode: Mode
	var allowsRemote = false
	@Binding var contentHeight: CGFloat

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.defaultWebpagePreferences.allowsContentJavaScript = false
		config.userContentController.addUserScript(MessageAppearance.userScript)
		let view = PassthroughWebView(frame: .zero, configuration: config)
		view.navigationDelegate = context.coordinator
		view.setValue(false, forKey: "drawsBackground")
		view.postsFrameChangedNotifications = true
		context.coordinator.observe(view)
		return view
	}

	func updateNSView(_ view: WKWebView, context: Context) {
		let height = $contentHeight
		context.coordinator.onHeight = { h in if abs(height.wrappedValue - h) > 0.5 { height.wrappedValue = h } }
		let key = "\(mode)\u{0}\(allowsRemote)\u{0}\(html)"
		guard context.coordinator.loaded != key else { return }
		context.coordinator.loaded = key
		let csp = allowsRemote
			? "default-src 'none'; img-src data: cid: http: https:; style-src 'unsafe-inline' http: https:; font-src data: http: https:; media-src http: https:"
			: "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
		// Adapted pages stay hidden until the script has re-colored them, so they never flash light.
		let htmlTag = mode == .adapted ? #"<html data-adapt="1" style="visibility:hidden">"# : "<html>"
		let scheme = mode == .original ? "light" : "light dark"
		let paper = mode == .original ? "html{background:#fff}" : ""
		let doc = """
		<!doctype html>\(htmlTag)<head><meta charset="utf-8">
		<meta http-equiv="Content-Security-Policy" content="\(csp)">
		<meta name="color-scheme" content="\(scheme)">
		<style>html,body{margin:0;padding:0}\(paper)
		#c{font:14px -apple-system,system-ui;padding:16px 20px;word-wrap:break-word}
		img{max-width:100%;height:auto}pre{font-family:inherit}</style></head><body><div id="c">\(html)</div></body></html>
		"""
		view.loadHTMLString(doc, baseURL: nil)
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	final class Coordinator: NSObject, WKNavigationDelegate {
		var loaded = ""
		var onHeight: (CGFloat) -> Void = { _ in }
		private var lastWidth: CGFloat = 0
		private var observer: NSObjectProtocol?

		/// A new width reflows the text, so the height is read again.
		func observe(_ view: WKWebView) {
			observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
				guard let self, let view, abs(view.frame.width - self.lastWidth) > 0.5 else { return }
				self.lastWidth = view.frame.width
				self.measure(view)
			}
		}

		deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

		/// Re-coloring has run by now; the page is shown even if it failed, then measured.
		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			webView.evaluateJavaScript("document.documentElement.style.removeProperty('visibility')", in: nil, in: .defaultClient) { _ in }
			measure(webView)
		}

		/// The wrapper's own height, which does not stretch to the view's, so it can shrink again.
		func measure(_ view: WKWebView) {
			view.evaluateJavaScript("(document.getElementById('c') || document.body).offsetHeight") { [weak self] result, _ in
				guard let height = (result as? NSNumber)?.doubleValue, height > 0 else { return }
				DispatchQueue.main.async { self?.onHeight(CGFloat(height.rounded(.up))) }
			}
		}

		func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
			if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
				NSWorkspace.shared.open(url)
				return .cancel
			}
			return action.navigationType == .other ? .allow : .cancel
		}
	}
}
