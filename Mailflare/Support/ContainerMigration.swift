import Foundation

/// Mailflare used to run in the App Sandbox, which kept its data under
/// `~/Library/Containers/<bundle id>/Data`. It no longer does (the sandbox would stop it from
/// replacing itself on update), so on first launch outside it the mail cache and preferences are
/// copied out of the old container. The container itself is left alone.
enum ContainerMigration {
	private static let doneKey = "migratedFromSandboxContainer"

	static func run() {
		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: doneKey), let bundleID = Bundle.main.bundleIdentifier else { return }
		defer { defaults.set(true, forKey: doneKey) }
		let fm = FileManager.default
		let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
		let container = library.appendingPathComponent("Containers/\(bundleID)/Data/Library", isDirectory: true)
		guard fm.fileExists(atPath: container.path) else { return }

		let oldData = container.appendingPathComponent("Application Support/Mailflare", isDirectory: true)
		let newData = library.appendingPathComponent("Application Support/Mailflare", isDirectory: true)
		if fm.fileExists(atPath: oldData.path), !fm.fileExists(atPath: newData.path) {
			try? fm.createDirectory(at: newData.deletingLastPathComponent(), withIntermediateDirectories: true)
			try? fm.copyItem(at: oldData, to: newData)
		}

		let oldPrefs = container.appendingPathComponent("Preferences/\(bundleID).plist")
		if let values = NSDictionary(contentsOf: oldPrefs) as? [String: Any] {
			for (key, value) in values where defaults.object(forKey: key) == nil {
				defaults.set(value, forKey: key)
			}
		}
	}
}
