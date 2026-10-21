import Foundation

/// The headline facts of a raw message, as the web app's "Original Message" dialog lists them.
struct MessageSourceSummary {
	struct Authentication {
		var status: String
		var detail: String?
		var passed: Bool { status == "PASS" }
		var text: String { detail.map { "\(status) \($0)" } ?? status }
	}

	var messageID: String?
	var createdAt: String?
	var from: String?
	var to: String?
	var subject: String?
	var spf: Authentication?
	var dkim: Authentication?
	var dmarc: Authentication?

	init(source: String) {
		let headers = Self.headers(of: source)
		messageID = headers["message-id"]?.first
		from = headers["from"]?.first
		to = headers["to"]?.first
		subject = headers["subject"]?.first
		let rawDate = headers["date"]?.first
		if let rawDate, let sent = Self.parseDate(rawDate) {
			let when = sent.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
			createdAt = Self.deliveryDuration(headers, sentAt: sent).map { "\(when) (\($0))" } ?? when
		} else {
			createdAt = rawDate
		}
		spf = Self.authentication(headers, "spf")
		dkim = Self.authentication(headers, "dkim")
		dmarc = Self.authentication(headers, "dmarc")
	}

	// MARK: Parsing

	/// Header names (lower-cased) to their values, folded lines joined, in the order they appear.
	private static func headers(of source: String) -> [String: [String]] {
		let split = source.range(of: "\r\n\r\n") ?? source.range(of: "\n\n")
		let block = split.map { String(source[..<$0.lowerBound]) } ?? source
		var result: [String: [String]] = [:]
		var current: String?
		for line in block.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
			if let first = line.first, first == " " || first == "\t", let name = current {
				if var values = result[name], !values.isEmpty {
					values[values.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
					result[name] = values
				}
				continue
			}
			guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { current = nil; continue }
			let name = line[..<colon].lowercased()
			current = name
			result[name, default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
		}
		return result
	}

	private static func parseDate(_ text: String) -> Date? {
		let cleaned = text.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
			formatter.dateFormat = format
			if let date = formatter.date(from: cleaned) { return date }
		}
		return ISO8601DateFormatter().date(from: cleaned)
	}

	/// "Delivered after 3 seconds": the time between the Date header and the top Received stamp.
	private static func deliveryDuration(_ headers: [String: [String]], sentAt: Date) -> String? {
		guard let received = headers["received"]?.first, let semicolon = received.lastIndex(of: ";"),
			let deliveredAt = parseDate(String(received[received.index(after: semicolon)...]))
		else { return nil }
		let seconds = Int(deliveredAt.timeIntervalSince(sentAt).rounded())
		guard seconds >= 0 else { return nil }
		func unit(_ n: Int, _ word: String) -> String { "Delivered after \(n) \(word)\(n == 1 ? "" : "s")" }
		if seconds < 60 { return unit(seconds, "second") }
		let minutes = Int((Double(seconds) / 60).rounded())
		if minutes < 60 { return unit(minutes, "minute") }
		let hours = Int((Double(minutes) / 60).rounded())
		if hours < 48 { return unit(hours, "hour") }
		return unit(Int((Double(hours) / 24).rounded()), "day")
	}

	private static func authentication(_ headers: [String: [String]], _ method: String) -> Authentication? {
		func match(_ pattern: String, in text: String?) -> String? {
			guard let text, let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
			let found = String(text[range])
			guard let equals = found.firstIndex(of: "=") else { return found }
			return String(found[found.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
		}
		let resultHeader = headers["authentication-results"]?.first { $0.range(of: "(^|[;\\s])\(method)\\s*=", options: [.regularExpression, .caseInsensitive]) != nil }
		let spfHeader = headers["received-spf"]?.first
		let result = match("(^|[;\\s])\(method)\\s*=\\s*[a-z]+", in: resultHeader)
			?? (method == "spf" ? spfHeader.flatMap { $0.split(separator: " ").first.map(String.init) } : nil)
		guard let result else { return nil }
		let status = result.uppercased()
		guard status == "PASS" else { return Authentication(status: status, detail: nil) }
		let section = resultHeader?.components(separatedBy: ";").first { $0.range(of: "(^|\\s)\(method)\\s*=", options: [.regularExpression, .caseInsensitive]) != nil } ?? ""
		switch method {
		case "spf":
			let ip = match(#"client-ip\s*=\s*[^\s;)]+"#, in: section) ?? match(#"client-ip\s*=\s*[^\s;)]+"#, in: spfHeader)
			return Authentication(status: status, detail: ip.map { "with IP \($0)" })
		case "dkim":
			let domain = match(#"header\.d\s*=\s*[^\s;)]+"#, in: section)
				?? match(#"(^|;)\s*d\s*=\s*[^\s;)]+"#, in: headers["dkim-signature"]?.first)
			return Authentication(status: status, detail: domain.map { "with domain \($0)" })
		default:
			return Authentication(status: status, detail: nil)
		}
	}
}
