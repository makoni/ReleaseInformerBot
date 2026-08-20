//
//  TelegramFailure.swift
//  ReleaseInformerBot
//

import Foundation
import Shared

/// Reads Telegram's error payload.
///
/// A non-200 used to be reported as just the status code, with the body discarded — throwing
/// away the only actionable part of a `429`, which is how long Telegram wants us to wait.
enum TelegramFailure {
	private struct Body: Decodable {
		struct Parameters: Decodable {
			let retryAfter: Int?

			private enum CodingKeys: String, CodingKey {
				case retryAfter = "retry_after"
			}
		}

		let description: String?
		let errorCode: Int?
		let parameters: Parameters?

		private enum CodingKeys: String, CodingKey {
			case description
			case errorCode = "error_code"
			case parameters
		}
	}

	/// How long Telegram asked us to wait, when it said.
	static func retryAfter(in body: Data) -> Int? {
		decode(body)?.parameters?.retryAfter
	}

	/// The largest delay we will honour, so a hostile or mistaken `retry_after` cannot park
	/// the bot for hours.
	static let maximumBackoff: Duration = .seconds(60)

	/// How long to wait before letting a failure propagate.
	///
	/// `nil` for anything the caller should see at once. In particular a `403` is *not* paced:
	/// it is how Telegram reports that one chat has blocked the bot or been deactivated, and
	/// the delivery queue is serialized — so pausing on it delays every healthy chat behind it.
	static func backoff(status: UInt, body: Data) -> Duration? {
		if let retryAfter = retryAfter(in: body), retryAfter > 0 {
			return min(.seconds(retryAfter), maximumBackoff)
		}

		switch status {
		case 429, 500..<600:
			// No hint given, but these do pass; a few seconds is enough to stop a hot loop.
			return .seconds(5)
		case 401:
			// A revoked token stays revoked, but the SDK's long-polling loop re-polls
			// regardless, so this is the only place that can keep it from spinning.
			return .seconds(30)
		default:
			return nil
		}
	}

	/// A log-worthy description of a failed Telegram call.
	static func describe(status: UInt, body: Data) -> String {
		var parts = ["Telegram request failed with status \(status)"]

		if let decoded = decode(body) {
			if let code = decoded.errorCode {
				parts.append("error_code: \(code)")
			}
			if let description = decoded.description {
				parts.append(description)
			}
			if let retryAfter = decoded.parameters?.retryAfter {
				parts.append("retry_after: \(retryAfter)")
			}
		}

		return parts.joined(separator: " — ")
	}

	/// Whether the caller should try again, and whether the chat is worth keeping.
	///
	/// A `403` on a send is always about the chat: Telegram uses it for blocked, deactivated,
	/// kicked and non-member. A `400` is about the request, except for the one description that
	/// means the chat is gone. Everything else stays retryable, because guessing wrong in that
	/// direction only costs a retry, while guessing wrong the other way deletes a subscriber.
	static func classify(status: UInt, body: Data) -> TelegramDeliveryError {
		let reason = describe(status: status, body: body)
		let description = decode(body)?.description ?? ""

		switch status {
		case 403:
			return .chatUnreachable(reason: reason)
		case 400 where description.localizedCaseInsensitiveContains("chat not found"):
			return .chatUnreachable(reason: reason)
		case 400, 401, 404:
			// A malformed message stays malformed, and a revoked token fails every send — but
			// neither says anything about this particular chat.
			return .permanent(reason: reason)
		default:
			return .temporary(reason: reason)
		}
	}

	private static func decode(_ body: Data) -> Body? {
		guard !body.isEmpty else { return nil }
		return try? JSONDecoder().decode(Body.self, from: body)
	}
}
