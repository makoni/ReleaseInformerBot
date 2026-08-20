//
//  TelegramFailure.swift
//  ReleaseInformerBot
//

import Foundation

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
	/// `nil` for failures that will not pass on their own — retrying those slowly is no better
	/// than retrying them quickly, and the caller should surface them immediately.
	static func backoff(status: UInt, body: Data) -> Duration? {
		if let retryAfter = retryAfter(in: body), retryAfter > 0 {
			return min(.seconds(retryAfter), maximumBackoff)
		}

		switch status {
		case 429, 500..<600:
			// No hint given, but these do pass; a few seconds is enough to stop a hot loop.
			return .seconds(5)
		case 401, 403:
			// A revoked or wrong token stays revoked. Still worth pacing, because the SDK
			// will re-poll regardless and would otherwise spin.
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

	private static func decode(_ body: Data) -> Body? {
		guard !body.isEmpty else { return nil }
		return try? JSONDecoder().decode(Body.self, from: body)
	}
}
