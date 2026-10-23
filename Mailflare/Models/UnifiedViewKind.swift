import SwiftUI

/// A cross-account view the sidebar's Unified section can list.
enum UnifiedViewKind: String, CaseIterable, Identifiable {
	case today, inbox, drafts, sent, starred, archive, spam, trash

	var id: String { rawValue }
	var title: String {
		switch self {
		case .today: "Today"
		case .inbox: "Inboxes"
		case .drafts: "Drafts"
		case .sent: "Sent"
		case .starred: "Starred"
		case .archive: "Archive"
		case .spam: "Spam"
		case .trash: "Trash"
		}
	}
	var icon: AppIcon {
		switch self {
		case .today: .smartMailbox
		case .inbox: .allInboxes
		case .drafts: .drafts
		case .sent: .sent
		case .starred: .flag
		case .archive: .archive
		case .spam: .junk
		case .trash: .trash
		}
	}
	var item: SidebarItem {
		switch self {
		case .today: .smartToday
		case .inbox: .allInboxes
		case .drafts: .allDrafts
		case .sent: .allSent
		case .starred: .flagged
		case .archive: .allArchive
		case .spam: .allJunk
		case .trash: .allTrash
		}
	}
	/// Folded under More unless the setting lists everything.
	var lessUsed: Bool { self == .archive || self == .spam || self == .trash }
}
