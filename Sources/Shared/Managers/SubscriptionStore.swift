//
//  SubscriptionStore.swift
//  ReleaseInformerBot
//

import Foundation

/// The storage the release watcher depends on.
///
/// Existing as a protocol is what lets the watcher's delete-and-notify decisions be tested
/// without a database — those are the decisions where being wrong costs users their
/// subscriptions, so they are the ones that most need covering.
public protocol SubscriptionStore: Sendable {
	func getAllSubscriptions() async throws -> [Subscription]
	func addNewVersion(_ version: String, forSubscription doc: Subscription) async throws
	func deleteSubscription(_ subscription: Subscription) async throws

	/// Removes one chat from an app's subscription, deleting the document if it was the last.
	///
	/// Used to prune a chat Telegram says is gone. Reuses the same path as `/del`, so duplicate
	/// documents are handled and no subscriber is left behind in one of them.
	@discardableResult
	func unsubscribeFromNewVersions(_ bundleID: String, forChatID chatID: Int64) async throws -> Subscription?
}

extension DBManager: SubscriptionStore {}
