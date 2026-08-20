//
//  TelegramDeliveryError.swift
//  ReleaseInformerBot
//

import Foundation

/// Why a Telegram send failed, in the terms the caller has to act on.
///
/// Lives in `Shared` because the classification is made by the HTTP client in the bot target
/// and acted on by the watcher in another. The three-way split is the point: "do not retry"
/// and "this chat is gone" are different claims, and only the second one justifies deleting a
/// subscriber. A rejected message or a revoked token fails every send too, and pruning on
/// either would empty the database over a formatting bug or an expired credential.
public enum TelegramDeliveryError: Error, Sendable {
	/// The chat itself will accept nothing ever again — blocked, deactivated, kicked, or gone.
	case chatUnreachable(reason: String)
	/// Retrying will not help, but the chat is fine.
	case permanent(reason: String)
	/// Worth another attempt.
	case temporary(reason: String)

	public var reason: String {
		switch self {
		case .chatUnreachable(let reason), .permanent(let reason), .temporary(let reason):
			return reason
		}
	}

	public var isWorthRetrying: Bool {
		if case .temporary = self { return true }
		return false
	}

	/// Whether the subscriber should be removed. Deliberately narrower than "permanent".
	public var isChatUnreachable: Bool {
		if case .chatUnreachable = self { return true }
		return false
	}
}

extension TelegramDeliveryError: CustomStringConvertible {
	// `BotError` renders as "<No description provided>" when interpolated, which is how the
	// retry log ended up saying nothing about what had failed.
	public var description: String { reason }
}
