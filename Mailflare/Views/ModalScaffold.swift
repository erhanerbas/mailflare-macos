import SwiftUI
import AppKit

enum ModalMetrics {
	/// Room a sheet may take: the app window's height at 90%, so it never outgrows it.
	static var maxHeight: CGFloat {
		let window = (NSApp.mainWindow ?? NSApp.keyWindow)?.frame.height ?? 740
		return max(280, window * 0.9)
	}
}

/// The fade that lets scrolled content slide under a footer: the modal's background, clear at the top.
struct ModalFade: View {
	var body: some View {
		LinearGradient(colors: [AppTheme.background.opacity(0), AppTheme.background], startPoint: .top, endPoint: .bottom)
			.allowsHitTesting(false)
	}
}

/// A sheet frame: a title bar, content, and a footer. It is as tall as its content, up to 90% of the
/// app window; taller content scrolls under a footer pinned to the bottom over a fade.
struct ModalScaffold<Content: View, Footer: View>: View {
	var title: String
	var width: CGFloat = 420
	@ViewBuilder var content: Content
	@ViewBuilder var footer: Footer

	@Environment(\.dismiss) private var dismiss

	private var header: some View {
		VStack(spacing: 0) {
			HStack {
				Text(title).font(Typography.bodySemibold).frame(maxWidth: .infinity, alignment: .leading)
				TitlebarIconButton(icon: .cancel, help: "Close") { dismiss() }
			}
			.padding(.horizontal, 12).padding(.leading, 4).padding(.vertical, 10)
			Rectangle().fill(AppTheme.cardStroke).frame(height: 1).padding(.horizontal, 16)
		}
	}

	var body: some View {
		ViewThatFits(in: .vertical) {
			VStack(spacing: 0) {
				header
				content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
				footer.padding(.horizontal, 16).padding(.bottom, 16)
			}
			VStack(spacing: 0) {
				header
				ScrollView {
					content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
				}
				.safeAreaInset(edge: .bottom, spacing: 0) {
					footer
						.padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 8)
						.frame(maxWidth: .infinity)
						.background(AppTheme.background)
						.overlay(alignment: .top) { ModalFade().frame(height: 24).offset(y: -24) }
				}
			}
		}
		.frame(width: width)
		.frame(maxHeight: ModalMetrics.maxHeight)
		.background(AppTheme.background)
	}
}
