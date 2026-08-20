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
		// Telegram's own wording is the part worth pinning; the label around it is not.
		#expect(reason.contains("Too Many Requests: retry after 30"))
	}

	@Test("A described failure without parameters still carries Telegram's reason")
	func surfacesDescription() {
		let body = #"{"ok":false,"error_code":400,"description":"Bad Request: can't parse entities"}"#
		let reason = TelegramFailure.describe(status: 400, body: Data(body.utf8))

		#expect(reason.contains("400"))
		#expect(reason.contains("can't parse entities"))
	}

	/// Asserted in full: `describe` always begins with the status, so a `contains("502")` check
	/// could never fail and would not notice a half-decoded body appending junk.
	@Test("An unreadable body falls back to the status alone")
	func fallsBackToStatus() {
		#expect(
			TelegramFailure.describe(status: 502, body: Data("<html>bad gateway</html>".utf8))
				== "Telegram request failed with status 502"
		)
	}

	@Test("An empty body falls back to the status alone")
	func handlesEmptyBody() {
		#expect(TelegramFailure.describe(status: 500, body: Data()) == "Telegram request failed with status 500")
	}

	@Test("The retry delay is available on its own")
	func exposesRetryAfter() {
		#expect(TelegramFailure.retryAfter(in: Data(#"{"ok":false,"parameters":{"retry_after":7}}"#.utf8)) == 7)
		#expect(TelegramFailure.retryAfter(in: Data(#"{"ok":false}"#.utf8)) == nil)
	}

	/// The SDK's long-polling loop re-polls immediately on failure, so this is the only place
	/// that can stop a revoked token or a 429 becoming an unthrottled request loop.
	@Test("Telegram's own delay is honoured when it gives one")
	func honoursRetryAfter() {
		let body = Data(#"{"ok":false,"error_code":429,"parameters":{"retry_after":7}}"#.utf8)
		#expect(TelegramFailure.backoff(status: 429, body: body) == .seconds(7))
	}

	@Test("An absurd delay is capped rather than parking the bot")
	func capsRetryAfter() {
		let body = Data(#"{"ok":false,"error_code":429,"parameters":{"retry_after":86400}}"#.utf8)
		#expect(TelegramFailure.backoff(status: 429, body: body) == TelegramFailure.maximumBackoff)
	}

	@Test("Failures with no hint still get paced", arguments: [429, 500, 503])
	func pacesUnhintedFailures(status: Int) {
		let delay = TelegramFailure.backoff(status: UInt(status), body: Data())
		#expect(delay != nil)
		#expect(delay ?? .zero > .zero)
	}

	@Test("A revoked token is paced too, since the SDK will keep polling regardless")
	func pacesAuthFailures() {
		#expect(TelegramFailure.backoff(status: 401, body: Data()) != nil)
	}

	@Test("A failure that will not pass on its own is surfaced immediately")
	func doesNotPaceClientErrors() {
		#expect(TelegramFailure.backoff(status: 400, body: Data()) == nil)
		#expect(TelegramFailure.backoff(status: 404, body: Data()) == nil)
	}

	/// Observed in production: pacing a per-chat 403 stalled the serialized delivery queue for
	/// 30 seconds per blocked chat, which delayed every healthy chat queued behind it.
	@Test("A chat rejecting a message is not paced")
	func doesNotPaceRejectedChats() {
		let blocked = Data(#"{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}"#.utf8)
		#expect(TelegramFailure.backoff(status: 403, body: blocked) == nil)
	}

	@Test("A revoked token is still paced, since the SDK keeps polling regardless")
	func stillPacesTokenFailures() {
		#expect(TelegramFailure.backoff(status: 401, body: Data()) != nil)
	}
}

/// Retrying a chat that will never accept a message costs an API call and an error line on
/// every release, forever — and the retry loop had no way to tell that case apart.
@Suite("Telegram failure classification")
struct TelegramClassificationTests {
	private func body(_ code: Int, _ description: String) -> Data {
		Data(#"{"ok":false,"error_code":\#(code),"description":"\#(description)"}"#.utf8)
	}

	@Test("A chat that will never accept a message is permanent", arguments: [
		(403, "Forbidden: bot was blocked by the user"),
		(403, "Forbidden: user is deactivated"),
		(403, "Forbidden: bot was kicked from the group chat"),
		(400, "Bad Request: chat not found")
	])
	func classifiesUnreachableChats(status: Int, description: String) {
		let failure = TelegramFailure.classify(status: UInt(status), body: body(status, description))
		#expect(failure.isPermanent)
		#expect(failure.reason.contains(description))
	}

	@Test("A rejected message is permanent too, since it will not parse next time either")
	func classifiesRejectedMessages() {
		let failure = TelegramFailure.classify(status: 400, body: body(400, "Bad Request: can't parse entities"))
		#expect(failure.isPermanent)
	}

	@Test("Server-side trouble is temporary", arguments: [429, 500, 502, 503])
	func classifiesTransientFailures(status: Int) {
		#expect(!TelegramFailure.classify(status: UInt(status), body: Data()).isPermanent)
	}

	/// `BotError` interpolated as "<No description provided>", which is how the retry log ended
	/// up telling us nothing about why a send failed.
	@Test("The error says what went wrong when interpolated")
	func describesItself() {
		let failure = TelegramFailure.classify(status: 403, body: body(403, "Forbidden: user is deactivated"))
		#expect("\(failure)".contains("user is deactivated"))
		#expect(!"\(failure)".contains("No description provided"))
	}
}
