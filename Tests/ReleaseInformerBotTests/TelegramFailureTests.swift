//
//  TelegramFailureTests.swift
//  ReleaseInformerBot
//

import Foundation
import Testing

@testable import ReleaseInformerBot

/// The client used to discard the body on a non-200 and report only the status, throwing away
/// the one actionable part of a Telegram 429 — how long to wait.
@Suite("Telegram failure reporting")
struct TelegramFailureTests {
	@Test("A rate-limit response surfaces the retry delay")
	func surfacesRetryAfter() {
		let body = """
		{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 30",\
		"parameters":{"retry_after":30}}
		"""
		let reason = TelegramFailure.describe(status: 429, body: Data(body.utf8))

		#expect(reason.contains("429"))
		#expect(reason.contains("retry after 30"))
		#expect(reason.contains("retry_after: 30"))
	}

	@Test("A described failure without parameters still carries Telegram's reason")
	func surfacesDescription() {
		let body = #"{"ok":false,"error_code":400,"description":"Bad Request: can't parse entities"}"#
		let reason = TelegramFailure.describe(status: 400, body: Data(body.utf8))

		#expect(reason.contains("400"))
		#expect(reason.contains("can't parse entities"))
	}

	@Test("An unreadable body falls back to the status alone")
	func fallsBackToStatus() {
		let reason = TelegramFailure.describe(status: 502, body: Data("<html>bad gateway</html>".utf8))
		#expect(reason.contains("502"))
	}

	@Test("An empty body falls back to the status alone")
	func handlesEmptyBody() {
		let reason = TelegramFailure.describe(status: 500, body: Data())
		#expect(reason.contains("500"))
	}

	@Test("The retry delay is available on its own for callers that can act on it")
	func exposesRetryAfter() {
		let body = #"{"ok":false,"error_code":429,"parameters":{"retry_after":7}}"#
		#expect(TelegramFailure.retryAfter(in: Data(body.utf8)) == 7)
		#expect(TelegramFailure.retryAfter(in: Data(#"{"ok":false}"#.utf8)) == nil)
	}
}
