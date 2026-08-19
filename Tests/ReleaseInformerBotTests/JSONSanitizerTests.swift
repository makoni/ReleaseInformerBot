//
//  JSONSanitizerTests.swift
//  ReleaseInformerBot
//

import Foundation
import Testing

@testable import Shared

/// Apple's release notes arrive with raw control characters inside JSON string literals,
/// which `JSONDecoder` rejects outright. Since lookups are batched, one malformed app would
/// otherwise take every other app in the same request down with it — so these tests assert
/// on what actually matters: the repaired payload decodes, and the text survives intact.
@Suite("JSON sanitizing")
struct JSONSanitizerTests {
	private struct Payload: Decodable {
		let notes: String
	}

	private func decodeNotes(fromRawJSON json: String) throws -> String {
		let repaired = JSONSanitizer.repairingControlCharacters(in: json)
		return try JSONDecoder().decode(Payload.self, from: Data(repaired.utf8)).notes
	}

	@Test("A raw newline inside a string is repaired")
	func repairsRawNewline() throws {
		#expect(try decodeNotes(fromRawJSON: "{\"notes\": \"first\nsecond\"}") == "first\nsecond")
	}

	@Test("Raw tabs and carriage returns are repaired")
	func repairsTabAndCarriageReturn() throws {
		#expect(try decodeNotes(fromRawJSON: "{\"notes\": \"a\tb\rc\"}") == "a\tb\rc")
	}

	@Test("A raw CRLF is repaired")
	func repairsCRLF() throws {
		// Swift treats CRLF as a single Character, so anything iterating by Character
		// silently misses it.
		#expect(try decodeNotes(fromRawJSON: "{\"notes\": \"a\r\nb\"}") == "a\r\nb")
	}

	@Test("Control characters with no shorthand escape are repaired", arguments: [
		"\u{0B}", "\u{0C}", "\u{01}", "\u{1F}"
	])
	func repairsOtherControlCharacters(control: String) throws {
		let notes = try decodeNotes(fromRawJSON: "{\"notes\": \"a\(control)b\"}")
		#expect(notes == "a\(control)b")
	}

	@Test("A string ending in an escaped backslash does not desynchronise the parser")
	func handlesTrailingEscapedBackslash() throws {
		// The JSON below holds `discount 50\` followed by a second key. A sanitizer that
		// cannot tell an escaped backslash from an escaping one loses track of where the
		// string ends and corrupts everything after it.
		let json = "{\"notes\": \"discount 50\\\\\", \"other\": \"x\ny\"}"
		let repaired = JSONSanitizer.repairingControlCharacters(in: json)

		struct Both: Decodable {
			let notes: String
			let other: String
		}
		let decoded = try JSONDecoder().decode(Both.self, from: Data(repaired.utf8))
		#expect(decoded.notes == "discount 50\\")
		#expect(decoded.other == "x\ny")
	}

	@Test("An escaped quote does not end the string early")
	func handlesEscapedQuote() throws {
		let notes = try decodeNotes(fromRawJSON: "{\"notes\": \"say \\\"hi\\\"\nbye\"}")
		#expect(notes == "say \"hi\"\nbye")
	}

	@Test("Existing valid escape sequences are left alone")
	func preservesValidEscapes() throws {
		#expect(try decodeNotes(fromRawJSON: "{\"notes\": \"a\\nb\\tc\"}") == "a\nb\tc")
		#expect(try decodeNotes(fromRawJSON: "{\"notes\": \"\\u00e9\"}") == "é")
	}

	@Test("A non-breaking space inside a string is preserved rather than rewritten")
	func preservesNonBreakingSpace() throws {
		// It is legal JSON and it is what Apple wrote; silently turning it into a plain
		// space means the notification text differs from the App Store.
		#expect(try decodeNotes(fromRawJSON: "{\"notes\": \"5\u{00A0}GB\"}") == "5\u{00A0}GB")
	}

	@Test("Already-valid JSON is passed through unchanged")
	func leavesValidJSONAlone() {
		let json = "{\"notes\":\"nothing to fix\",\"count\":3}"
		#expect(JSONSanitizer.repairingControlCharacters(in: json) == json)
	}

	@Test("Emoji and other multi-scalar text survive")
	func preservesEmoji() throws {
		#expect(try decodeNotes(fromRawJSON: "{\"notes\": \"done 👍🏽\nok\"}") == "done 👍🏽\nok")
	}

	@Test("A realistic multi-app payload with one malformed entry still decodes")
	func repairsBatchWithOneBadEntry() throws {
		// The regression that batching introduced: one bad app must not poison the batch.
		let json = """
		{"resultCount":2,"results":[\
		{"trackCensoredName":"Good","bundleId":"a.b.c","trackViewUrl":"https://x","version":"1.0"},\
		{"trackCensoredName":"Bad","bundleId":"d.e.f","trackViewUrl":"https://y","version":"2.0",\
		"releaseNotes":"line one\u{0B}line two"}]}
		"""
		let repaired = JSONSanitizer.repairingControlCharacters(in: json)
		let decoded = try JSONDecoder().decode(SearchResultResponse.self, from: Data(repaired.utf8))
		#expect(decoded.results.count == 2)
		#expect(decoded.results[1].releaseNotes == "line one\u{0B}line two")
	}
}

@Suite("Telegram HTML escaping")
struct TelegramHTMLTests {
	@Test("Ampersands are escaped")
	func escapesAmpersand() {
		#expect("Barnes & Noble".escapedForTelegramHTML == "Barnes &amp; Noble")
	}

	@Test("Angle brackets are escaped")
	func escapesAngleBrackets() {
		#expect("<3".escapedForTelegramHTML == "&lt;3")
		#expect("if x > y".escapedForTelegramHTML == "if x &gt; y")
		#expect("a <b> c".escapedForTelegramHTML == "a &lt;b&gt; c")
	}

	@Test("Escaping is not applied twice")
	func doesNotDoubleEscape() {
		// `&` must be handled before `<` and `>`, otherwise the entities they produce get
		// mangled into `&amp;lt;`.
		#expect("<".escapedForTelegramHTML == "&lt;")
		#expect("&lt;".escapedForTelegramHTML == "&amp;lt;")
	}

	@Test("Text with no metacharacters is unchanged")
	func leavesPlainTextAlone() {
		#expect("· Fixed a crash".escapedForTelegramHTML == "· Fixed a crash")
	}

	@Test("Quotes are left alone since they are only special in attributes")
	func leavesQuotesAlone() {
		#expect("say \"hi\"".escapedForTelegramHTML == "say \"hi\"")
	}
}
