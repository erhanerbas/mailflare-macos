import Foundation
import Observation

/// A saved instruction that rewrites the reply being written: "make it concise", or the user's own.
struct AIPrompt: Identifiable, Codable, Equatable {
	var id = UUID().uuidString
	var name: String
	var prompt: String
	/// The model to run it on; nil follows AI Writer's.
	var providerID: String?
	var model: String?
}

/// The rewrite prompts, kept in UserDefaults. The first launch starts them from `defaults`; after that
/// they are the user's to edit, delete or add to.
@MainActor
@Observable
final class AIPromptLibrary {
	static let defaults: [AIPrompt] = [
		AIPrompt(id: "builtin.polite", name: "Make it polite",
				 prompt: "Rewrite the draft in a polite, courteous tone. Keep its meaning, facts and length about the same."),
		AIPrompt(id: "builtin.professional", name: "Professional tone",
				 prompt: "Rewrite the draft in a professional, businesslike tone. Keep its meaning and facts."),
		AIPrompt(id: "builtin.concise", name: "Make it more concise",
				 prompt: "Make the draft shorter and to the point. Remove filler and repetition, and keep every fact and request."),
		AIPrompt(id: "builtin.friendly", name: "Make it friendlier",
				 prompt: "Rewrite the draft in a warm, friendly, approachable tone. Keep its meaning and facts."),
		AIPrompt(id: "builtin.grammar", name: "Fix spelling and grammar",
				 prompt: "Correct spelling, grammar and punctuation only. Do not change the wording, tone or meaning otherwise."),
		AIPrompt(id: "builtin.simple", name: "Use simpler words",
				 prompt: "Rewrite the draft in plain, simple language that is easy to read. Keep its meaning and facts."),
	]

	private(set) var prompts: [AIPrompt]
	private static let defaultsKey = "ai.replyPrompts"

	init() {
		prompts = UserDefaults.standard.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([AIPrompt].self, from: $0) } ?? Self.defaults
	}

	func add(_ prompt: AIPrompt) {
		prompts.append(prompt)
		persist()
	}

	func update(_ prompt: AIPrompt) {
		guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
		prompts[index] = prompt
		persist()
	}

	func remove(_ id: String) {
		prompts.removeAll { $0.id == id }
		persist()
	}

	private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(prompts), forKey: Self.defaultsKey) }
}
