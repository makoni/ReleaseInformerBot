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
