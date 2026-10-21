import AppKit
import Foundation
import Observation
import Security

/// Updates Mailflare from the GitHub releases of `repository`. Each release carries a zip
/// ("Mailflare v1.2.0.zip") holding Mailflare.app; its version comes from the release tag.
/// Installing downloads the zip next to the running app, checks that the new app is signed by the
/// same developer, swaps it in place and relaunches.
@MainActor
@Observable
final class AppUpdater {
	struct Release: Equatable {
		let version: String
		let zipURL: URL
		let pageURL: URL?
	}

	enum Phase: Equatable {
		case idle
		case downloading
		case installing
		case failed(String)
	}

	static let repository = "hieunc229/mailflare-macos"
	private static let checkInterval: Duration = .seconds(6 * 60 * 60)

	/// The newer release, once a check found one.
	private(set) var available: Release?
	private(set) var phase: Phase = .idle

	static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

	// MARK: Checking

	/// Checks at launch and then every few hours while the app runs.
	func checkPeriodically() async {
		while !Task.isCancelled {
			if ReadingSettings.autoCheckUpdates { await check(userInitiated: false) }
			try? await Task.sleep(for: Self.checkInterval)
		}
	}

	/// Looks up the latest release. A check the user asked for reports when there is nothing new.
	func check(userInitiated: Bool = true) async {
		do {
			let release = try await Self.latestRelease()
			if let release, Self.isVersion(release.version, newerThan: Self.currentVersion) {
				available = release
			} else {
				available = nil
				if userInitiated { alert("Mailflare is up to date", "Version \(Self.currentVersion) is the latest.") }
			}
		} catch {
			if userInitiated { alert("Could not check for updates", error.localizedDescription) }
		}
	}

	private static func latestRelease() async throws -> Release? {
		var url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
		#if DEBUG
		// Debug builds can read a local feed to try an update without publishing a release.
		if let feed = ProcessInfo.processInfo.environment["MAILFLARE_UPDATE_FEED"], let local = URL(string: feed) { url = local }
		#endif
		var request = URLRequest(url: url)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("Mailflare/\(currentVersion)", forHTTPHeaderField: "User-Agent")
		request.cachePolicy = .reloadIgnoringLocalCacheData
		let (data, response) = try await URLSession.shared.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		// No published release yet.
		if status == 404 { return nil }
		guard status == 200 else { throw UpdateError("GitHub answered with status \(status).") }

		struct Payload: Decodable {
			struct Asset: Decodable {
				let name: String
				let browser_download_url: URL
			}
			let tag_name: String
			let name: String?
			let html_url: URL?
			let draft: Bool
			let prerelease: Bool
			let assets: [Asset]
		}
		let payload = try JSONDecoder().decode(Payload.self, from: data)
		guard !payload.draft, !payload.prerelease,
			let zip = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
			let version = version(in: payload.tag_name) ?? payload.name.flatMap(version(in:)) ?? version(in: zip.name)
		else { return nil }
		return Release(version: version, zipURL: zip.browser_download_url, pageURL: payload.html_url)
	}

	/// The first dotted number in a tag or file name: "v1.2.0" and "Mailflare.v1.2.0.zip" give "1.2.0".
	nonisolated static func version(in text: String) -> String? {
		guard let range = text.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return nil }
		return String(text[range])
	}

	nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
		let x = a.split(separator: ".").map { Int($0) ?? 0 }
		let y = b.split(separator: ".").map { Int($0) ?? 0 }
		for i in 0..<max(x.count, y.count) {
			let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
			if l != r { return l > r }
		}
		return false
	}

	// MARK: Installing

	/// Downloads the available release, replaces the running app with it and relaunches.
	func install() async {
		guard let release = available, phase != .downloading, phase != .installing else { return }
		let appURL = Bundle.main.bundleURL
		do {
			guard !appURL.path.contains("/AppTranslocation/") else {
				throw UpdateError("Move Mailflare to the Applications folder, open it from there, then update.")
			}
			guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
				throw UpdateError("Mailflare can't write to \(appURL.deletingLastPathComponent().path).")
			}
			phase = .downloading
			// A scratch folder on the app's own volume, so the final swap is a rename.
			let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
			defer { try? FileManager.default.removeItem(at: work) }
			let (download, response) = try await URLSession.shared.download(from: release.zipURL)
			guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
			let zip = work.appendingPathComponent("update.zip")
			try FileManager.default.moveItem(at: download, to: zip)

			phase = .installing
			let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
			try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
			let newApp = try Self.findApp(in: unpacked)
			try Self.verify(newApp)
			// Downloads made by the app are not quarantined, but clear it in case the zip carried it.
			try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
			_ = try FileManager.default.replaceItemAt(appURL, withItemAt: newApp)
			relaunch(appURL)
		} catch {
			phase = .failed(error.localizedDescription)
		}
	}

	private static func findApp(in folder: URL) throws -> URL {
		let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
		if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
		// A zip made from a folder holding the app.
		for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
			if let app = try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) {
				return app
			}
		}
		throw UpdateError("The update doesn't contain Mailflare.app.")
	}

	/// The new app must be the same app (bundle identifier) and satisfy the running app's
	/// designated requirement, i.e. be signed by the same developer.
	private static func verify(_ app: URL) throws {
		guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
			throw UpdateError("The update is not Mailflare.")
		}
		var selfCode: SecCode?
		var selfStatic: SecStaticCode?
		var requirement: SecRequirement?
		var staticCode: SecStaticCode?
		guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
			SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
			SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
			SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
			SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), requirement) == errSecSuccess
		else { throw UpdateError("The update's code signature doesn't match this copy of Mailflare.") }
	}

	/// Opens the new copy once this process has exited, then quits.
	private func relaunch(_ appURL: URL) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", appURL.path]
		try? process.run()
		NSApp.terminate(nil)
	}

	private static func run(_ tool: String, _ arguments: [String]) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			let process = Process()
			process.executableURL = URL(fileURLWithPath: tool)
			process.arguments = arguments
			process.terminationHandler = { p in
				if p.terminationStatus == 0 { continuation.resume() } else {
					continuation.resume(throwing: UpdateError("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus)).")) }
			}
			do { try process.run() } catch { continuation.resume(throwing: error) }
		}
	}

	private func alert(_ title: String, _ message: String) {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = message
		alert.runModal()
	}
}

struct UpdateError: LocalizedError {
	let errorDescription: String?
	init(_ message: String) { errorDescription = message }
}
