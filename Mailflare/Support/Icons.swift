import SwiftUI
import Hugeicons

/// Every glyph in the app comes from Hugeicons; this maps UI roles to icon assets.
enum AppIcon: String {
	case sidebar, filter, compose, reply, replyAll, forward, archive, trash, junk, folder, flag
	case moreDown, search, allInboxes, vip, remind, drafts, sent, smartMailbox, inbox
	case attachment, summarize, aiContent, chevronRight, chevronDown, clock, close, send, add, addCircle, check, signOut, appearance, settings, info, more, bell
	case crown, arrowLeft, sparkles, edit, colors, download, copy, label, unsubscribe, block, sourceCode, cancel, minimize, bold, italic, underline, strikethrough, bulletList, numberList, quote, link, clearFormat, undo, redo, support, markRead, markUnread, unflag
	case notificationOff, calendar, cart, money, person, work, travel, home, bookmark, parcel

	var asset: HugeiconsAsset {
		switch self {
		case .sidebar: Hugeicons.sidebarLeft
		case .filter: Hugeicons.filterMail
		case .compose: Hugeicons.edit02
		case .reply: Hugeicons.linkBackward
		case .replyAll: Hugeicons.mailReplyAll01
		case .forward: Hugeicons.linkForward
		case .archive: Hugeicons.archive02
		case .trash: Hugeicons.delete02
		case .junk: Hugeicons.spam
		case .folder: Hugeicons.folder01
		case .flag: Hugeicons.flag01
		case .moreDown: Hugeicons.arrowDown01
		case .search: Hugeicons.search01
		case .allInboxes: Hugeicons.mailbox01
		case .vip: Hugeicons.star
		case .remind: Hugeicons.clock01
		case .drafts: Hugeicons.file02
		case .sent: Hugeicons.sent
		case .smartMailbox: Hugeicons.haze
		case .inbox: Hugeicons.inbox
		case .attachment: Hugeicons.attachment01
		case .summarize: Hugeicons.sparkles
		case .aiContent: Hugeicons.aiContentGenerator01
		case .chevronRight: Hugeicons.arrowRight01
		case .chevronDown: Hugeicons.arrowDown01
		case .clock: Hugeicons.alarmClock
		case .close: Hugeicons.cancel01
		case .send: Hugeicons.mailSend01
		case .add: Hugeicons.add01
		case .addCircle: Hugeicons.addCircle
		case .check: Hugeicons.tick02
		case .signOut: Hugeicons.logout01
		case .appearance: Hugeicons.sun03
		case .settings: Hugeicons.settings02
		case .info: Hugeicons.informationCircle
		case .more: Hugeicons.moreHorizontal
		case .bell: Hugeicons.notification01
		case .label: Hugeicons.tag01
		case .unsubscribe: Hugeicons.mailRemove01
		case .block: Hugeicons.userBlock01
		case .sourceCode: Hugeicons.sourceCode
		case .cancel: Hugeicons.cancel01
		case .minimize: Hugeicons.minusSign
		case .bold: Hugeicons.textBold
		case .italic: Hugeicons.textItalic
		case .underline: Hugeicons.textUnderline
		case .strikethrough: Hugeicons.textStrikethrough
		case .bulletList: Hugeicons.leftToRightListBullet
		case .numberList: Hugeicons.leftToRightListNumber
		case .arrowLeft: Hugeicons.arrowLeft02
		case .edit: Hugeicons.edit02
		case .download: Hugeicons.download01
		case .copy: Hugeicons.copy01
		case .colors: Hugeicons.colors
		case .sparkles: Hugeicons.sparkles
		case .crown: Hugeicons.crown
		case .quote: Hugeicons.quoteDown
		case .link: Hugeicons.link01
		case .clearFormat: Hugeicons.textClear
		case .undo: Hugeicons.undo03
		case .redo: Hugeicons.redo03
		case .support: Hugeicons.customerSupport
		case .markRead: Hugeicons.mailOpen01
		case .markUnread: Hugeicons.mail01
		case .unflag: Hugeicons.flag02
		case .notificationOff: Hugeicons.notificationBlock01
		case .calendar: Hugeicons.calendar01
		case .cart: Hugeicons.shoppingCart01
		case .money: Hugeicons.dollarCircle
		case .person: Hugeicons.user
		case .work: Hugeicons.briefcase01
		case .travel: Hugeicons.airplane01
		case .home: Hugeicons.home01
		case .bookmark: Hugeicons.bookmark01
		case .parcel: Hugeicons.package
		}
	}
}

struct HIcon: View {
	let icon: AppIcon
	var size: CGFloat = 16

	init(_ icon: AppIcon, size: CGFloat = 16) {
		self.icon = icon
		self.size = size
	}

	var body: some View {
		icon.asset.image()
			.resizable()
			.renderingMode(.template)
			.scaledToFit()
			.frame(width: size, height: size)
	}
}
