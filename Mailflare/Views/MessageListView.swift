import SwiftUI
import MailflareCore

struct MessageListView: View {
	@Environment(MailStore.self) private var store
	@State private var isHoveringFilter = false

	var body: some View {
		VStack(spacing: 0) {
			header
				// Above the list, so the filter button's tooltip is not covered by it.
				.zIndex(1)
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1)
			list
		}
		.background(AppTheme.background)
	}

	/// The mailbox in view and how many messages it holds, on one row, with the unread filter.
	private var header: some View {
		HStack(alignment: .center, spacing: 8) {
			// One run of text, so the title and the count share a baseline and the pair is centred.
			(Text(store.title).font(.system(size: 15, weight: .semibold))
				+ Text("   ")
				+ Text(store.subtitle).font(Typography.meta).foregroundStyle(.secondary))
				.lineLimit(1)
			Spacer(minLength: 4)
			Button { store.unreadOnly.toggle() } label: {
				HIcon(.filter, size: 15)
					.frame(width: 26, height: 26)
					.foregroundStyle(store.unreadOnly ? Color.accentColor : Color.secondary)
					.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(store.unreadOnly ? AppTheme.railSelection : .clear))
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.onHover { isHoveringFilter = $0 }
			.titlebarTooltip(store.unreadOnly ? "Showing unread only" : "Filter unread messages", isHovering: isHoveringFilter)
			.accessibilityLabel(store.unreadOnly ? "Showing unread only" : "Filter unread messages")
		}
		.padding(.horizontal, 16)
		.frame(height: PaneHeader.height)
	}

	/// Every row has this height, so which rows are on screen follows from the scroll offset alone.
	static let rowHeight: CGFloat = 92
	/// Rows are kept for the visible page plus this many pages above and below it.
	private static let bufferPages = 2

	@State private var firstVisibleRow = 0
	@State private var viewportHeight: CGFloat = 600

	/// Only the rows near the viewport exist as views; the rest are replaced by spacers of the same
	/// height, so scrolling a long mailbox never builds (or keeps) thousands of rows.
	private var list: some View {
		ScrollViewReader { proxy in
			ScrollView {
				rows
			}
			.focusable()
			.focusEffectDisabled()
			.onMoveCommand { direction in
				guard let i = store.messages.firstIndex(where: { $0.id == store.selectedID }) else {
					if let first = store.messages.first { store.select(first.id) }
					return
				}
				let next = direction == .down ? i + 1 : (direction == .up ? i - 1 : i)
				guard store.messages.indices.contains(next) else { return }
				store.select(store.messages[next].id)
				proxy.scrollTo(store.messages[next].id)
			}
		}
		.overlay {
			if store.messages.isEmpty {
				if store.searchText.isEmpty {
					EmptyStateView(icon: .inbox, title: store.isSyncing ? "Syncing…" : "No Messages")
				} else {
					EmptyStateView(icon: .search, title: "No Results", message: "Nothing matches “\(store.searchText)”.")
				}
			}
		}
	}

	/// Called by the scroll observer whenever the list scrolls or is resized; moves the window of
	/// built rows so a row is a real view by the time it scrolls into sight.
	private func scrolled(offset: CGFloat, viewport: CGFloat) {
		let row = max(0, Int((offset / Self.rowHeight).rounded(.down)))
		if row != firstVisibleRow { firstVisibleRow = row }
		if abs(viewport - viewportHeight) > 1 { viewportHeight = viewport }
	}

	private var rows: some View {
		let messages = store.messages
		let count = messages.count
		let pageRows = max(1, Int((viewportHeight / Self.rowHeight).rounded(.up)))
		let first = min(firstVisibleRow, max(count - 1, 0))
		let start = max(0, first - Self.bufferPages * pageRows)
		let end = min(count, first + (Self.bufferPages + 1) * pageRows)
		return VStack(spacing: 0) {
			Color.clear.frame(height: CGFloat(start) * Self.rowHeight)
			if start < end {
				ForEach(Array(messages[start..<end].enumerated()), id: \.element.id) { offset, message in
					let index = start + offset
					let nextIsSelected = messages.indices.contains(index + 1) && messages[index + 1].id == store.selectedID
					let selected = message.id == store.selectedID
					MessageRow(
						message: message, isDraft: store.role(of: message) == "drafts", isSelected: selected,
						showsDivider: index < count - 1 && !selected && !nextIsSelected)
						.id(message.id)
						.onTapGesture { store.select(message.id) }
						.contextMenu { menu(for: message) }
						.onAppear { store.loadMoreIfNeeded(current: message) }
				}
			}
			Color.clear.frame(height: CGFloat(max(count - end, 0)) * Self.rowHeight)
		}
		.background(ScrollObserver { offset, viewport in scrolled(offset: offset, viewport: viewport) })
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private func menu(for m: MessageSummary) -> some View {
		Button("Reply") { store.reply(to: m.id, all: false) }
		Button("Forward") { store.forward(m.id) }
		Divider()
		Button(m.flagged ? "Remove Flag" : "Flag") { store.toggleFlag(m.id) }
		Button(m.seen ? "Mark as Unread" : "Mark as Read") { store.setRead(m.id, !m.seen) }
		Divider()
		Button("Archive") { store.archive(m.id) }
		Button("Move to Junk") { store.junk(m.id) }
		Button("Delete", role: .destructive) { store.trash(m.id) }
	}
}

/// One message. Its text is inset `textInset` from the left, the unread dot sits in that margin,
/// and a hairline closes it off from the next row.
struct MessageRow: View {
	/// Where a row's text starts: room on the left for the unread dot, and breathing space for read mail.
	static let textInset: CGFloat = 30

	let message: MessageSummary
	let isDraft: Bool
	let isSelected: Bool
	let showsDivider: Bool

	@State private var isHovering = false

	/// The first line: the sender (or a draft's recipients).
	private var title: String {
		let name = isDraft ? message.toDisplay : message.senderDisplay
		return name.trimmingCharacters(in: .whitespaces)
	}

	private var subject: String { message.subject.trimmingCharacters(in: .whitespaces) }

	/// "(No Subject)", dimmed and italic, where a subject should be.
	private var noSubject: some View {
		Text("(No Subject)").font(Typography.body.italic()).foregroundStyle(.tertiary).lineLimit(1)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				// With no sender, the subject (or its placeholder) takes the title's place.
				if title.isEmpty && !isDraft {
					if subject.isEmpty { noSubject } else { Text(subject).font(Typography.bodySemibold).lineLimit(1) }
				} else {
					Text(title.isEmpty ? "Draft" : title).font(Typography.bodySemibold).lineLimit(1)
				}
				Spacer(minLength: 4)
				if title.isEmpty && !isDraft {
					if message.hasAttachment { HIcon(.attachment, size: 13).foregroundStyle(.secondary) }
					if message.flagged { HIcon(.flag, size: 13).foregroundStyle(.orange) }
				}
				Text(MailDate.list(message.date))
					.font(Typography.meta).foregroundStyle(.secondary).lineLimit(1).fixedSize()
			}
			if !(title.isEmpty && !isDraft) {
				HStack(spacing: 4) {
					if subject.isEmpty { noSubject } else { Text(subject).font(Typography.body).lineLimit(1) }
					Spacer(minLength: 4)
					if message.hasAttachment { HIcon(.attachment, size: 13).foregroundStyle(.secondary) }
					if message.flagged { HIcon(.flag, size: 13).foregroundStyle(.orange) }
				}
			}
			if !message.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				Text(message.preview).font(Typography.notice).foregroundStyle(.secondary).lineLimit(2)
			}
		}
		.padding(.leading, MessageRow.textInset)
		.padding(.trailing, 16)
		.padding(.vertical, 9)
		.frame(maxWidth: .infinity, minHeight: MessageListView.rowHeight, maxHeight: MessageListView.rowHeight, alignment: .topLeading)
		.background(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.fill(isSelected ? AppTheme.railSelection : (isHovering ? AppTheme.rowHighlight : .clear))
				.padding(.horizontal, 6)
		)
		.overlay(alignment: .topLeading) {
			if !message.seen {
				Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.leading, MessageRow.textInset - 15).padding(.top, 16)
			}
		}
		.overlay(alignment: .bottom) {
			if showsDivider {
				Rectangle().fill(AppTheme.cardStroke.opacity(0.7)).frame(height: 1).padding(.leading, MessageRow.textInset).padding(.trailing, 16)
			}
		}
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}
