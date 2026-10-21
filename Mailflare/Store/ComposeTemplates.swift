import Foundation
import Observation

/// Reusable message bodies, kept on this Mac. (The web composer's templates are server records that
/// need a browser session, which the mail API key used here cannot reach.)
@MainActor
@Observable
final class ComposeTemplates {
	struct Template: Codable, Identifiable, Equatable {
		var id = UUID()
		var title: String
		var html: String
	}

	private(set) var items: [Template] = []

	private static var file: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Mailflare/templates.json")
	}

	init() {
		if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([Template].self, from: data) { items = saved }
	}

	func add(title: String, html: String) {
		let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { return }
		items.insert(Template(title: String(name.prefix(200)), html: html), at: 0)
		save()
	}

	func remove(_ id: UUID) {
		items.removeAll { $0.id == id }
		save()
	}

	private func save() {
		try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
		if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.file, options: .atomic) }
	}
}
