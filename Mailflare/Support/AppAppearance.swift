import AppKit

/// The window theme chosen in Settings: follow the system, or always light or dark. `glass` is the
/// dark window (black, transparent chrome) with white columns: the list, reader and assistant. It is set on
/// `NSApp`, so every window and every `AppTheme` color follows it.
enum AppAppearance: String, CaseIterable, Identifiable {
	case system, light, dark, glass

	static let key = "appearance"

	var id: String { rawValue }

	var title: String {
		switch self {
		case .system: "System"
		case .light: "Light"
		case .dark: "Dark"
		case .glass: "Dark Glass"
		}
	}

	static var saved: AppAppearance {
		UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
	}

	/// Whether the list, reader and assistant columns are drawn in the light scheme inside a dark window.
	var lightColumns: Bool { self == .glass }

	static func applySaved() { saved.apply() }

	func apply() {
		NSApplication.shared.appearance = switch self {
		case .system: nil
		case .light: NSAppearance(named: .aqua)
		case .dark, .glass: NSAppearance(named: .darkAqua)
		}
	}
}
