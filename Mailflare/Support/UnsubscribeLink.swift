import Foundation

/// Finds the unsubscribe link in a message body: the first link whose address or text says
/// "unsubscribe". The core does not expose the List-Unsubscribe header.
enum UnsubscribeLink {
	static func find(in html: String) -> URL? {
		let pattern = #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
		let text = html as NSString
		for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
			let href = text.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
			let label = text.substring(with: match.range(at: 2))
			guard href.lowercased().contains("unsubscribe") || label.lowercased().contains("unsubscribe"),
				let url = URL(string: href), ["http", "https", "mailto"].contains(url.scheme ?? "")
			else { continue }
			return url
		}
		return nil
	}
}
