//
//  ReleaseWatcher.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 18.04.2025.
//

import Foundation
import Shared
import Logging
import SwiftTelegramBot

fileprivate let logger = Logger(label: "ReleaseWatcher")

public actor ReleaseWatcher {
	/// How often the subscription list is reloaded from the database.
	static let sweepInterval: Duration = .seconds(60 * 5)

	/// The gap between batched lookups.
	///
	/// A batch covers up to `lookup.maxIDsPerRequest` apps, so one request every five
	/// seconds is 12 a minute — inside the roughly 20 per minute Apple tolerates, with
	/// headroom left for `/search` from users — while still checking 1,200 apps a minute.
	/// Because the loop sleeps *after* each step rather than on a timer, this is a real gap
	/// between requests even when a lookup runs long.
	static let batchInterval: Duration = .seconds(5)

	/// The gap between delivered notifications.
	static let notificationInterval: Duration = .seconds(1)

	/// How long to stand down after a lookup fails for a reason that might pass.
	static let lookupBackoff: Duration = .seconds(60)

	/// Consecutive lookups an app must be absent from before its subscription is dropped.
	static let missingLookupsBeforeDeletion = 3

	/// How many times a single notification is retried before it is given up on.
	static let maxNotificationAttempts = 3

	private struct PendingNotification: Sendable {
		let chatID: Int64
		let text: String
		let bundleID: String
		var attempts = 0
	}

	private let dbManager: any SubscriptionStore
	private let lookup: any AppVersionLookup
	private let clock = ContinuousClock()

	private var loops = [Task<Void, Never>]()
	private var isRefilling = false
	private var isCheckingBatch = false

	/// Subscriptions still to check this sweep, pre-grouped so one batch is one request.
	private var pendingBatches = [[Subscription]]()
	private var pendingNotifications = [PendingNotification]()
	private var missingApps = MissingAppTracker(threshold: missingLookupsBeforeDeletion)
	private var resumeLookupsAt: ContinuousClock.Instant?
	private var nextDeliveryFailure: TelegramDeliveryError?

	/// Held strongly on purpose: `TGBot` never references the watcher, so there is no cycle
	/// to break, and a weak reference here would turn the SDK's own retain habits into
	/// notifications silently stopping.
	public var tgBot: TGBot?

	public init(
		dbManager: any SubscriptionStore = DBManager(),
		lookup: any AppVersionLookup = SearchManager()
	) {
		self.dbManager = dbManager
		self.lookup = lookup
	}

	public func setBot(_ bot: TGBot?) {
		self.tgBot = bot
	}

	/// Starts the three loops. Calling it again while running does nothing.
	public func start() {
		guard loops.isEmpty else {
			logger.info("Watcher already running.")
			return
		}

		loops = [
			Task { [weak self] in
				while !Task.isCancelled {
					guard let self else { return }
					await self.refillQueueIfDrained()
					guard await Self.pause(for: Self.sweepInterval) else { return }
				}
			},
			Task { [weak self] in
				while !Task.isCancelled {
					guard let self else { return }
					await self.checkNextBatch()
					guard await Self.pause(for: Self.batchInterval) else { return }
				}
			},
			Task { [weak self] in
				while !Task.isCancelled {
					guard let self else { return }
					await self.deliverNextNotification()
					guard await Self.pause(for: Self.notificationInterval) else { return }
				}
			}
		]
	}

	public func stop() {
		for loop in loops {
			loop.cancel()
		}
		loops.removeAll()
	}

	/// Sleeps, reporting `false` if the task was cancelled while waiting.
	private static func pause(for duration: Duration) async -> Bool {
		do {
			try await Task.sleep(for: duration)
			return true
		} catch {
			return false
		}
	}

	/// Batches still waiting to be checked. Exposed so tests can tell a requeued batch from
	/// a dropped one.
	var pendingBatchCount: Int { pendingBatches.count }

	/// Notifications queued for delivery, so tests can tell an announcement that was made from
	/// one that was correctly withheld.
	var pendingNotificationCount: Int { pendingNotifications.count }

	// MARK: - Sweeping

	func refillQueueIfDrained() async {
		guard pendingBatches.isEmpty else { return }
		// A batch that is mid-flight has already been popped, so the queue looks drained
		// while it is still being checked. Reloading now would hand the same apps out
		// twice in one sweep — and double-counted absences delete a subscription early.
		guard !isCheckingBatch else { return }
		guard !isRefilling else {
			logger.info("Already reloading subscriptions. Skipping this cycle.")
			return
		}
		isRefilling = true
		defer { isRefilling = false }

		do {
			let subscriptions = try await dbManager.getAllSubscriptions()
			pendingBatches = subscriptions.chunked(into: lookup.maxIDsPerRequest)
			logger.info("Number of subscriptions to check: \(subscriptions.count) in \(pendingBatches.count) batches.")
		} catch {
			logger.error("An error occurred while reloading subscriptions: \(error)")
		}
	}

	// MARK: - Checking

	func checkNextBatch() async {
		if let resumeAt = resumeLookupsAt {
			guard clock.now >= resumeAt else { return }
			resumeLookupsAt = nil
		}

		guard !pendingBatches.isEmpty else { return }

		isCheckingBatch = true
		defer { isCheckingBatch = false }

		let batch = pendingBatches.removeFirst()

		var live = [Subscription]()
		for subscription in batch {
			if subscription.chats.isEmpty {
				_ = await deleteSubscription(subscription, reason: "it has no active chats")
			} else {
				live.append(subscription)
			}
		}

		guard !live.isEmpty else { return }

		logger.info("Checking \(live.count) subscriptions in one lookup.")

		let results: [SearchResult]
		do {
			results = try await lookup.search(byBundleIDs: live.map(\.bundleID))
		} catch {
			handleLookupFailure(error, batch: live)
			return
		}

		let absent = ReleaseDiff.missing(in: live, results: results).map(\.bundleID)
		let doomed = Set(missingApps.record(missing: absent, present: results.map(\.bundleID)))

		for subscription in live where doomed.contains(subscription.bundleID) {
			if await deleteSubscription(subscription, reason: "it was not found in the App Store") {
				missingApps.forget(subscription.bundleID)
			}
		}

		for update in ReleaseDiff.updates(for: live, results: results) {
			await recordAndAnnounce(update)
		}
	}

	/// Decides what a failed lookup means for the batch that triggered it.
	///
	/// Nothing is ever deleted here: a failed request says nothing about whether these apps
	/// still exist, which is the whole reason subscriptions used to vanish on a rate limit.
	private func handleLookupFailure(_ error: any Error, batch: [Subscription]) {
		let isWorthRetrying: Bool
		switch error {
		case let searchError as SearchManager.SearchError:
			isWorthRetrying = searchError.isTransient
		case is DecodingError:
			isWorthRetrying = false
		default:
			// Transport-level trouble; the payload itself is not implicated.
			isWorthRetrying = true
		}

		guard !isWorthRetrying else {
			pendingBatches.insert(batch, at: 0)
			resumeLookupsAt = clock.now.advanced(by: Self.lookupBackoff)
			logger.error("Lookup failed for \(batch.count) subscriptions: \(error). Retrying after backoff.")
			return
		}

		// A payload that will not parse now will not parse in a minute either, so retrying
		// the whole batch would stall the sweep indefinitely. Bisect instead: within a few
		// requests the offending app is alone in its batch and only it gets skipped.
		guard batch.count > 1 else {
			logger.error(
				"Skipping \(batch[0].bundleID) this sweep — its lookup response could not be read: \(error)"
			)
			return
		}

		let half = batch.count / 2
		pendingBatches.insert(contentsOf: [Array(batch[..<half]), Array(batch[half...])], at: 0)
		logger.error("Could not read the lookup response for \(batch.count) subscriptions: \(error). Bisecting.")
	}

	private func recordAndAnnounce(_ update: VersionUpdate) async {
		let bundleID = update.subscription.bundleID
		logger.info("New version \(update.result.version) found for \(bundleID) - \(update.subscription.title).")

		do {
			try await dbManager.addNewVersion(update.result.version, forSubscription: update.subscription)
		} catch {
			// Announcing without recording would re-notify on every sweep from here on.
			logger.error("Failed to record version \(update.result.version) for \(bundleID): \(error)")
			return
		}

		let text = Self.notificationText(for: update.result)
		for chat in update.subscription.chats.sorted() {
			pendingNotifications.append(
				PendingNotification(chatID: chat, text: text, bundleID: bundleID)
			)
		}
	}

	/// Reports whether the subscription is now gone from the database.
	private func deleteSubscription(_ subscription: Subscription, reason: String) async -> Bool {
		do {
			try await dbManager.deleteSubscription(subscription)
			logger.info("Deleted subscription for \(subscription.bundleID) as \(reason).")
			return true
		} catch {
			logger.error("Failed to delete subscription for \(subscription.bundleID): \(error)")
			return false
		}
	}

	// MARK: - Notifying

	/// Makes the next delivery fail, so the retry-versus-drop decision can be exercised
	/// without a live Telegram connection.
	func failNextDelivery(with error: TelegramDeliveryError) {
		nextDeliveryFailure = error
	}

	func deliverNextNotification() async {
		guard !pendingNotifications.isEmpty else { return }

		if let injected = nextDeliveryFailure {
			nextDeliveryFailure = nil
			var notification = pendingNotifications.removeFirst()
			await handleDeliveryFailure(injected, for: &notification)
			return
		}

		guard let bot = tgBot else {
			logger.warning("No Telegram bot available; holding \(pendingNotifications.count) notifications.")
			return
		}

		var notification = pendingNotifications.removeFirst()

		do {
			try await bot.sendMessage(
				params: .init(chatId: .chat(notification.chatID), text: notification.text, parseMode: .html)
			)
			logger.debug("Notification sent to chat: \(notification.chatID)")
		} catch {
			await handleDeliveryFailure(error, for: &notification)
		}
	}

	private func handleDeliveryFailure(_ error: any Error, for notification: inout PendingNotification) async {
		let delivery = error as? TelegramDeliveryError

		// Nothing else ever removes a chat Telegram says is gone, so it would keep costing an
		// API call and an error line on every release of every app it follows.
		if delivery?.isChatUnreachable == true {
			logger.error(
				"""
				Unsubscribing chat \(notification.chatID) from \(notification.bundleID) — \
				Telegram will not deliver to it: \(delivery?.reason ?? "")
				"""
			)

			do {
				try await dbManager.unsubscribeFromNewVersions(notification.bundleID, forChatID: notification.chatID)
			} catch {
				// Worth another go next time the chat comes up; the notification is dropped
				// either way, since it cannot be delivered.
				logger.error("Failed to unsubscribe chat \(notification.chatID) from \(notification.bundleID): \(error)")
			}
			return
		}

		if delivery?.isWorthRetrying == false {
			logger.error(
				"""
				Dropping the \(notification.bundleID) notification for chat \
				\(notification.chatID) — it will not be accepted: \(delivery?.reason ?? "")
				"""
			)
			return
		}

		notification.attempts += 1

		guard notification.attempts < Self.maxNotificationAttempts else {
			logger.error(
				"""
				Giving up on the \(notification.bundleID) notification for chat \
				\(notification.chatID) after \(notification.attempts) attempts: \(error)
				"""
			)
			return
		}

		// The version is already recorded, so dropping this would lose the release announcement
		// for good. Retry behind everything else that is waiting.
		logger.error(
			"""
			Attempt \(notification.attempts) to notify chat \(notification.chatID) about \
			\(notification.bundleID) failed; requeueing: \(error)
			"""
		)
		pendingNotifications.append(notification)
	}

	/// Telegram rejects a message longer than this outright.
	static let maxMessageLength = 4096

	static func notificationText(for result: SearchResult) -> String {
		var text = "<b>New Version Released!</b>\n\n"
		text += "<b>\(result.title.escapedForTelegramHTML)</b>\n"
		text += "Version: <b>\(result.version.escapedForTelegramHTML)</b>\n"
		text += "URL: \(result.url.escapedForTelegramHTML)\n"
		text += "<b>Bundle ID:</b> \(result.bundleID.escapedForTelegramHTML)\n\n"

		guard let releaseNotes = result.releaseNotes else { return text }

		// Escaping expands `&` fivefold, so notes well under the limit can cross it once
		// escaped — and an over-long message is a 400, which costs the announcement for good
		// because the version has already been recorded.
		let header = "<b>Release Notes:</b>\n"
		let ellipsis = "…"
		let budget = Self.maxMessageLength - text.count - header.count - "\n\n".count

		guard budget > ellipsis.count else { return text }

		let escaped = releaseNotes.escapedForTelegramHTML
		guard escaped.count > budget else { return text + header + escaped + "\n\n" }

		// Accumulated one source character at a time. Trimming the escaped string by length
		// would cut an entity in half — `&lt;` becoming `&l` — which Telegram rejects just as
		// firmly as the over-long message did.
		var notes = ""
		let limit = budget - ellipsis.count
		for character in releaseNotes {
			let piece = String(character).escapedForTelegramHTML
			guard notes.count + piece.count <= limit else { break }
			notes += piece
		}

		return text + header + notes + ellipsis + "\n\n"
	}
}
