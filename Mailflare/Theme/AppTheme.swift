import AppKit
import SwiftUI

/// The palette shared with PiCode: two flat greys in the dark appearance (a base and one step
/// above it), the system's own whites in the light one. Every colour resolves per appearance
/// through `NSColor(name:)`, so views carry no `colorScheme` checks.
enum AppTheme {
	/// The base the content sits on: #181818 dark.
	static let background = adaptive(dark: 0x181818, light: NSColor(white: 1, alpha: 1))
	/// One step above the base, for cards laid on it.
	static let elevated = adaptive(dark: 0x212121, light: NSColor(white: 0.98, alpha: 1))
	/// The boxed input: the compose box.
	static let composerFill = adaptive(dark: 0x343434, light: NSColor(white: 1, alpha: 1))
	static let composerStroke = Color(nsColor: NSColor(name: nil) { appearance in
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.04) : NSColor(white: 0, alpha: 0.10)
	})
	static let composerShadow = Color(nsColor: NSColor(name: nil) { appearance in
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.25) : NSColor(white: 0, alpha: 0.07)
	})
	/// The emphasised pill button: white on dark, near-black on light.
	static let prominentPillFill = adaptive(dark: 0xFFFFFF, light: NSColor(white: 0.1, alpha: 1))
	static let prominentPillText = adaptive(dark: 0x111111, light: NSColor(white: 1, alpha: 1))
	/// The selected row in lists, and the soft pill button's fill.
	static let railSelection = adaptive(dark: 0x444444, light: NSColor(white: 0.898, alpha: 1))
	/// Notices, summaries, chips and fields: a light borderless band.
	static let composerContextFill = adaptive(dark: 0x272727, light: NSColor(white: 0.96, alpha: 1))
	/// The hairline between panes and around cards.
	static let cardStroke = adaptive(dark: 0x3c3c3c, light: NSColor(white: 0.90, alpha: 1))
	/// The window's own chrome: the titlebar band, the rail and the sidebar sit on it. Translucent,
	/// so the window's vibrancy shows through (the container is transparent).
	static let chrome = translucent(dark: 0x333333, light: NSColor(white: 0.945, alpha: 1), alpha: 0.55)
	/// The outline around the main card and the account dropdown: none in the dark appearance,
	/// the hairline grey in the light one.
	static let outline = Color(nsColor: NSColor(name: nil) { appearance in
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.clear : NSColor(white: 0.90, alpha: 1)
	})
	/// A hovered row.
	static let rowHighlight = Color(nsColor: NSColor(name: nil) { appearance in
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.055)
	})

	static func translucent(dark: UInt32, light: NSColor, alpha: CGFloat) -> Color {
		Color(nsColor: NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
				? NSColor(rgb: dark).withAlphaComponent(alpha) : light.withAlphaComponent(alpha)
		})
	}

	static func adaptive(dark: UInt32, light: NSColor) -> Color {
		Color(nsColor: NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(rgb: dark) : light
		})
	}
}

extension NSColor {
	convenience init(rgb: UInt32) {
		self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
	}
}


/// The window's backdrop: the system's behind-window blur, tinted by `AppTheme.chrome`.
struct WindowVibrancy: NSViewRepresentable {
	func makeNSView(context: Context) -> NSVisualEffectView {
		let view = NSVisualEffectView()
		view.material = .sidebar
		view.blendingMode = .behindWindow
		view.state = .followsWindowActiveState
		return view
	}

	func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
