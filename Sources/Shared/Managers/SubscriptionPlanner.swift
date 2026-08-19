//
//  SubscriptionPlanner.swift
//  ReleaseInformerBot
//

import Foundation

/// The writes needed to add a chat to an app's subscription.
public struct SubscribePlan: Sendable, Equatable {
	public var insert: Subscription?
	public var update: Subscription?
	/// Duplicate documents being folded into the one that is kept.
	public var deletions: [Subscription]
	public var alreadySubscribed: Bool
}

/// The writes needed to remove a chat from an app's subscription.
public struct UnsubscribePlan: Sendable, Equatable {
	public var updates: [Subscription]
	public var deletions: [Subscription]
	/// `nil` when this chat was not subscribed to the app at all.
	public var removedFrom: Subscription?
}

/// Works out what to write, given every document currently stored for one bundle ID.
///
/// Keeping the decisions here — rather than interleaved with the database calls — is what
/// makes them testable, and these are decisions that cost users their subscriptions when
/// they go wrong.
public enum SubscriptionPlanner {
	public static func subscribe(
		_ result: SearchResult,
		chatID: Int64,
		existing: [Subscription]
	) -> SubscribePlan {
		guard let keeper = existing.first else {
			// The document is keyed by bundle ID so that CouchDB, not luck, decides which of
			// two concurrent subscribers wins: the loser gets a 409 and re-reads.
			let subscription = Subscription(
				_id: result.bundleID,
				bundleID: result.bundleID,
				url: result.url,
				title: result.title,
				version: [result.version],
				chats: [chatID]
			)
			return SubscribePlan(insert: subscription, update: nil, deletions: [], alreadySubscribed: false)
		}

		let duplicates = Array(existing.dropFirst())

		// Nothing to do only when there is a single document and it already has this chat.
		// Duplicates are always worth healing, whoever asked.
		if duplicates.isEmpty && keeper.chats.contains(chatID) {
			return SubscribePlan(insert: nil, update: nil, deletions: [], alreadySubscribed: true)
		}

		var merged = keeper
		merged.chats.formUnion(duplicates.flatMap(\.chats))
		merged.chats.insert(chatID)

		return SubscribePlan(insert: nil, update: merged, deletions: duplicates, alreadySubscribed: false)
	}

	public static func unsubscribe(chatID: Int64, from existing: [Subscription]) -> UnsubscribePlan {
		var plan = UnsubscribePlan(updates: [], deletions: [], removedFrom: nil)

		for document in existing where document.chats.contains(chatID) {
			if plan.removedFrom == nil {
				plan.removedFrom = document
			}

			var remaining = document
			remaining.chats.remove(chatID)

			// The chat has to come out of *every* document: leaving it in a duplicate means
			// the user keeps getting notifications after `/del`.
			if remaining.chats.isEmpty {
				plan.deletions.append(document)
			} else {
				plan.updates.append(remaining)
			}
		}

		return plan
	}
}
