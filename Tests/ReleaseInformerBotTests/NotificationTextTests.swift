//
//  NotificationTextTests.swift
//  ReleaseInformerBot
//

import Foundation
import Testing

@testable import ReleaseWatcher
@testable import Shared

@Suite("Notification text")
struct NotificationTextTests {
	private func result(releaseNotes: String?) -> SearchResult {
		SearchResult(
			title: "MyApp",
			bundleID: "com.my.app",
			url: "https://example.com/app",
			version: "2.1",
			releaseNotes: releaseNotes
		)
	}

	@Test("The message carries the app, version, URL and bundle ID")
	func includesAppDetails() {
		let text = ReleaseWatcher.notificationText(for: result(releaseNotes: nil))
		#expect(text.contains("<b>MyApp</b>"))
		#expect(text.contains("Version: <b>2.1</b>"))
		#expect(text.contains("https://example.com/app"))
		#expect(text.contains("com.my.app"))
	}

	@Test("Release notes are included when present")
	func includesReleaseNotes() {
		let text = ReleaseWatcher.notificationText(for: result(releaseNotes: "· Fixed a crash"))
		#expect(text.contains("<b>Release Notes:</b>"))
		#expect(text.contains("· Fixed a crash"))
	}

	@Test("The release notes section is omitted when there are none")
	func omitsMissingReleaseNotes() {
		let text = ReleaseWatcher.notificationText(for: result(releaseNotes: nil))
		#expect(!text.contains("Release Notes"))
	}

	/// Telegram rejects the whole message with a 400 when it sees stray markup, and the
	/// version has already been recorded by then — so an unescaped `&` costs the user that
	/// release announcement permanently.
	@Test("Markup characters in release notes are escaped")
	func escapesReleaseNotes() {
		let text = ReleaseWatcher.notificationText(for: result(releaseNotes: "works if x < y & z > 0"))
		#expect(text.contains("works if x &lt; y &amp; z &gt; 0"))
		#expect(!text.contains("x < y"))
	}

	@Test("Markup characters in the app title are escaped")
	func escapesTitle() {
		let escaped = ReleaseWatcher.notificationText(
			for: SearchResult(
				title: "Barnes & Noble <Reader>",
				bundleID: "com.bn.reader",
				url: "https://example.com",
				version: "1.0"
			)
		)
		#expect(escaped.contains("Barnes &amp; Noble &lt;Reader&gt;"))
	}

	/// Escaping expands `&` fivefold, so notes comfortably under Telegram's limit can cross it
	/// once escaped. An over-long message is rejected with a 400 — and because the version has
	/// already been recorded, that release is never announced again.
	@Test("A message is kept inside Telegram's length limit")
	func staysWithinTelegramLimit() {
		let notes = String(repeating: "&", count: 5000)
		let text = ReleaseWatcher.notificationText(for: result(releaseNotes: notes))

		#expect(text.count <= ReleaseWatcher.maxMessageLength)
		#expect(text.contains("<b>MyApp</b>"))
		#expect(text.contains("Release Notes"))
	}

	@Test("Truncation does not cut an HTML entity in half")
	func truncatesWholeEntities() {
		let text = ReleaseWatcher.notificationText(for: result(releaseNotes: String(repeating: "<", count: 5000)))

		#expect(text.count <= ReleaseWatcher.maxMessageLength)
		// Everything after the header must be complete `&lt;` entities plus the ellipsis.
		let body = text.components(separatedBy: "<b>Release Notes:</b>\n").last ?? ""
		#expect(!body.replacingOccurrences(of: "&lt;", with: "").contains("&"))
	}

	@Test("Notes that already fit are not touched")
	func leavesShortNotesAlone() {
		let text = ReleaseWatcher.notificationText(for: result(releaseNotes: "· Fixed a crash"))
		#expect(text.contains("· Fixed a crash"))
		#expect(!text.contains("…"))
	}

	@Test("The bold tags the bot adds itself are left intact")
	func keepsIntentionalMarkup() {
		let text = ReleaseWatcher.notificationText(for: result(releaseNotes: "<3"))
		#expect(text.hasPrefix("<b>New Version Released!</b>"))
		#expect(text.contains("<b>MyApp</b>"))
		#expect(text.contains("&lt;3"))
	}
}
