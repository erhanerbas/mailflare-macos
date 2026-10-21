import SwiftUI

/// One reading size for everything the user reads or types (rows, message content, inputs).
/// An explicit point size rather than a semantic style, because `.body`, `.callout` and
/// `.subheadline` resolve to three different sizes on macOS. Metadata (dates, badges) is a step down.
enum Typography {
	static let baseSize: CGFloat = 14
	static let body = Font.system(size: baseSize, weight: .regular)
	static let bodySemibold = Font.system(size: baseSize, weight: .semibold)
	static let notice = Font.system(size: baseSize - 1, weight: .regular)
	static let meta = Font.system(size: baseSize - 2, weight: .regular)
}
