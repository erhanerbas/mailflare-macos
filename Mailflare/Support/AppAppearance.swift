import AppKit

/// The window theme chosen in Settings: follow the system, or always light or dark. It is set on
/// `NSApp`, so every window and every `AppTheme` color follows it.
enum AppAppearance: String, CaseIterable, Identifiable {
	case system, light, dark

	static let key = "appearance"

	var id: String { rawValue }

	var title: String {
		switch self {
		case .system: "System"
		case .light: "Light"
		case .dark: "Dark"
		}
	}

	static var saved: AppAppearance {
		UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
	}

	static func applySaved() { saved.apply() }

	func apply() {
		NSApplication.shared.appearance = switch self {
		case .system: nil
		case .light: NSAppearance(named: .aqua)
		case .dark: NSAppearance(named: .darkAqua)
		}
	}
}
