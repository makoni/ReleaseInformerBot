//
//  TelegramDeliveryError.swift
//  ReleaseInformerBot
//

import Foundation

/// Why a Telegram API call failed, in the only terms the caller needs: try again, or don't.
///
/// Lives in `Shared` because the classification is made by the HTTP client in the bot target
/// and acted on by the watcher in another — and getting it wrong is expensive. A chat that has
/// blocked the bot rejects every future message, so retrying it burns an API call and writes
/// an error line on every release, forever.
public enum TelegramDeliveryError: Error, Sendable {
	/// Retrying will not help: the chat is gone, blocked or deactivated, or Telegram rejected
	/// this particular message.
	case permanent(reason: String)
	/// Worth another attempt.
	case temporary(reason: String)

	public var reason: String {
		switch self {
		case .permanent(let reason), .temporary(let reason): return reason
		}
	}

	public var isPermanent: Bool {
		if case .permanent = self { return true }
		return false
	}
}

extension TelegramDeliveryError: CustomStringConvertible {
	// `BotError` renders as "<No description provided>" when interpolated, which is how the
	// retry log ended up saying nothing useful.
	public var description: String { reason }
}
