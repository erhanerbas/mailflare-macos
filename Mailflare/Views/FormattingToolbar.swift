import SwiftUI

/// The rich-text tools over a `ComposerEditor`: text styles, lists and quote, link, clear, undo and
/// redo, then whatever the host adds at the far end. Shared by the composer and the reader's reply box.
struct FormattingToolbar<Trailing: View>: View {
	let controller: ComposerController
	/// Glyph size of the tools; the reply box uses smaller ones.
	var iconSize: CGFloat = RailMetrics.iconSize
	@ViewBuilder var trailing: Trailing
	/// A host's own tool at the near end, before Bold (the reply box puts AI rewrites here).
	var leading: AnyView? = nil

	@State private var linkOpen = false
	@State private var linkURL = ""

	var body: some View {
		let f = controller.formats
		HStack(spacing: 2) {
			if let leading {
				leading
				divider
			}
			TitlebarIconButton(icon: .bold, help: "Bold (⌘B)", isActive: f.bold, iconSize: iconSize) { controller.bold() }
			TitlebarIconButton(icon: .italic, help: "Italic (⌘I)", isActive: f.italic, iconSize: iconSize) { controller.italic() }
			TitlebarIconButton(icon: .underline, help: "Underline (⌘U)", isActive: f.underline, iconSize: iconSize) { controller.underline() }
			TitlebarIconButton(icon: .strikethrough, help: "Strikethrough", isActive: f.strike, iconSize: iconSize) { controller.strikethrough() }
			divider
			TitlebarIconButton(icon: .bulletList, help: "Bulleted list", isActive: f.bulletList, iconSize: iconSize) { controller.bulletList() }
			TitlebarIconButton(icon: .numberList, help: "Numbered list", isActive: f.numberList, iconSize: iconSize) { controller.numberList() }
			TitlebarIconButton(icon: .quote, help: "Quote", isActive: f.quote, iconSize: iconSize) { controller.quote() }
			divider
			TitlebarIconButton(icon: .link, help: "Insert link (⌘K)", iconSize: iconSize) { openLink() }
				.popover(isPresented: $linkOpen, arrowEdge: .top) { linkField }
			TitlebarIconButton(icon: .clearFormat, help: "Clear formatting", iconSize: iconSize) { controller.clearFormatting() }
			divider
			TitlebarIconButton(icon: .undo, help: "Undo (⌘Z)", isEnabled: controller.canUndo, iconSize: iconSize) { controller.undo() }
			TitlebarIconButton(icon: .redo, help: "Redo (⇧⌘Z)", isEnabled: controller.canRedo, iconSize: iconSize) { controller.redo() }
			Spacer()
			trailing
		}
		.onChange(of: controller.linkRequested) { _, requested in
			if requested { controller.linkRequested = false; openLink() }
		}
	}

	func withLeading<V: View>(_ view: V) -> Self {
		var copy = self
		copy.leading = AnyView(view)
		return copy
	}

	private var divider: some View {
		Rectangle().fill(AppTheme.composerStroke).frame(width: 1, height: 16).padding(.horizontal, 6)
	}

	private var linkField: some View {
		HStack(spacing: 8) {
			TextField("https://", text: $linkURL)
				.textFieldStyle(.plain).font(Typography.body).frame(width: 220)
				.onSubmit(applyLink)
			Button("Apply", action: applyLink).buttonStyle(.pill)
		}
		.padding(12)
	}

	private func openLink() {
		controller.rememberSelection()
		linkURL = ""
		linkOpen = true
	}

	private func applyLink() {
		linkOpen = false
		controller.insertLink(linkURL)
	}
}

extension FormattingToolbar where Trailing == EmptyView {
	init(controller: ComposerController, iconSize: CGFloat = RailMetrics.iconSize) {
		self.init(controller: controller, iconSize: iconSize) { EmptyView() }
	}
}
