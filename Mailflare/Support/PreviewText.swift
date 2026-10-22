import Foundation

/// List previews as plain text. Servers and the IMAP reader sometimes hand over a preview cut from
/// the HTML part, markup and all; this strips it. Results are cached because rows ask on every draw.
enum PreviewText {
	private static let cache = NSCache<NSString, NSString>()

	private static let blocks = try! NSRegularExpression(
		pattern: "<(style|script|head|title)\\b[^>]*>.*?</\\1\\s*>|<!--.*?-->", options: [.caseInsensitive, .dotMatchesLineSeparators])
	/// A tag, or a tag cut off by the preview's length limit.
	private static let tags = try! NSRegularExpression(pattern: "</?[a-zA-Z!][^>]*(>|$)")
	private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")
	private static let named: [String: String] = [
		"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "zwnj": "", "zwj": "", "shy": "",
		"ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®",
	]

	static func plain(_ text: String) -> String {
		guard text.contains("<") || text.contains("&") else { return text }
		if let hit = cache.object(forKey: text as NSString) { return hit as String }
		var result = text
		if result.contains("<") {
			result = replace(blocks, in: result, with: " ")
			result = replace(tags, in: result, with: " ")
		}
		if result.contains("&") { result = decodeEntities(result) }
		result = result.split(whereSeparator: { $0.isWhitespace || $0 == "\u{200C}" || $0 == "\u{200B}" }).joined(separator: " ")
		cache.setObject(result as NSString, forKey: text as NSString)
		return result
	}

	private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
		regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
	}

	private static func decodeEntities(_ text: String) -> String {
		var out = ""
		var last = text.startIndex
		for match in entity.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
			guard let range = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
			out += text[last..<range.lowerBound]
			let name = String(text[body])
			if name.hasPrefix("#") {
				let digits = name.dropFirst()
				let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
				out += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(text[range])
			} else {
				out += named[name.lowercased()] ?? String(text[range])
			}
			last = range.upperBound
		}
		return out + text[last...]
	}
}
