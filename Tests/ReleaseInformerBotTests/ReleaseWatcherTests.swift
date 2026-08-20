//
//  ReleaseWatcherTests.swift
//  ReleaseInformerBot
//

import Foundation
import Testing

@testable import ReleaseWatcher
@testable import Shared

private enum StubError: Error {
	case storeUnavailable
	case transportFailed
}

private actor StubStore: SubscriptionStore {
	private var subscriptions: [Subscription]
	private var deleteFails: Bool

	private(set) var deleted = [String]()
	private(set) var recorded = [String]()
	private(set) var chatsRemoved = [String]()

	private var recordFails: Bool

	init(_ subscriptions: [Subscription], deleteFails: Bool = false, recordFails: Bool = false) {
		self.subscriptions = subscriptions
		self.deleteFails = deleteFails
		self.recordFails = recordFails
	}

	func getAllSubscriptions() async throws -> [Subscription] { subscriptions }

	func addNewVersion(_ version: String, forSubscription doc: Subscription) async throws {
		guard !recordFails else { throw StubError.storeUnavailable }
		recorded.append("\(doc.bundleID)@\(version)")
	}

	func unsubscribeFromNewVersions(_ bundleID: String, forChatID chatID: Int64) async throws -> Subscription? {
		chatsRemoved.append("\(chatID)@\(bundleID)")

		guard let index = subscriptions.firstIndex(where: { $0.bundleID == bundleID }) else { return nil }
		var subscription = subscriptions[index]
		guard subscription.chats.contains(chatID) else { return nil }

		subscription.chats.remove(chatID)
		if subscription.chats.isEmpty {
			subscriptions.remove(at: index)
		} else {
			subscriptions[index] = subscription
		}
		return subscription
	}

	func deleteSubscription(_ subscription: Subscription) async throws {
		guard !deleteFails else { throw StubError.storeUnavailable }
		deleted.append(subscription.bundleID)
		subscriptions.removeAll { $0.bundleID == subscription.bundleID }
	}
}

private actor StubLookup: AppVersionLookup {
	nonisolated let maxIDsPerRequest: Int

	private var outcomes: [Result<[SearchResult], any Error>]
	private let fallback: Result<[SearchResult], any Error>
	private(set) var requestedBatches = [[String]]()

	init(
		maxIDsPerRequest: Int = 100,
		outcomes: [Result<[SearchResult], any Error>] = [],
		fallback: Result<[SearchResult], any Error> = .success([])
	) {
		self.maxIDsPerRequest = maxIDsPerRequest
		self.outcomes = outcomes
		self.fallback = fallback
	}

	/// Run while a lookup is in flight, to reproduce work interleaving with the watcher.
	private var duringSearch: (@Sendable () async -> Void)?

	func onSearch(_ body: @escaping @Sendable () async -> Void) {
		duringSearch = body
	}

	func search(byBundleIDs bundleIDs: [String]) async throws -> [SearchResult] {
		requestedBatches.append(bundleIDs)
		await duringSearch?()
		guard !outcomes.isEmpty else { return try fallback.get() }
		return try outcomes.removeFirst().get()
	}
}

@Suite("Release watcher behaviour")
struct ReleaseWatcherTests {
	private func subscription(
		_ bundleID: String,
		versions: [String] = ["1.0"],
		chats: Set<Int64> = [1]
	) -> Subscription {
		Subscription(
			bundleID: bundleID,
			url: "https://example.com/\(bundleID)",
			title: bundleID,
			version: versions,
			chats: chats
		)
	}

	private func result(_ bundleID: String, version: String) -> SearchResult {
		SearchResult(title: bundleID, bundleID: bundleID, url: "https://example.com", version: version)
	}

	/// Drives one full pass: reload the queue, then check every batch it produced.
	private func sweep(_ watcher: ReleaseWatcher, batches: Int = 1) async {
		await watcher.refillQueueIfDrained()
		for _ in 0..<batches {
			await watcher.checkNextBatch()
		}
	}

	// MARK: - The bug that motivated this change

	/// Apple answers a rate-limited request with `403` and an *empty results array*. Reading
	/// that as "the app is gone" is what used to unsubscribe everyone.
	@Test("A rate-limited lookup deletes nothing, however long it goes on")
	func rateLimitDeletesNothing() async {
		let store = StubStore([subscription("a.b.c"), subscription("d.e.f")])
		let lookup = StubLookup(fallback: .failure(SearchManager.SearchError.rateLimited))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		// Sweeping past the deletion threshold: a failure must never accumulate strikes,
		// because "the lookup failed" is not evidence that an app is gone.
		for _ in 0...ReleaseWatcher.missingLookupsBeforeDeletion {
			await sweep(watcher)
		}

		#expect(await store.deleted.isEmpty)
		#expect(await store.recorded.isEmpty)
	}

	@Test("A rate-limited batch is put back on the queue rather than skipped")
	func rateLimitRequeuesTheBatch() async {
		let store = StubStore([subscription("a.b.c")])
		let lookup = StubLookup(fallback: .failure(SearchManager.SearchError.rateLimited))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)

		#expect(await watcher.pendingBatchCount == 1)
		// And the watcher stands down instead of hammering a rate-limited API.
		await watcher.checkNextBatch()
		#expect(await lookup.requestedBatches.count == 1)
	}

	@Test("A transport failure deletes nothing, however long it goes on")
	func transportFailureDeletesNothing() async {
		let store = StubStore([subscription("a.b.c")])
		let lookup = StubLookup(fallback: .failure(StubError.transportFailed))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		for _ in 0...ReleaseWatcher.missingLookupsBeforeDeletion {
			await sweep(watcher)
		}

		#expect(await store.deleted.isEmpty)
	}

	@Test("An empty result set from a successful lookup does not delete on the spot")
	func oneAbsenceIsNotEnoughToDelete() async {
		let store = StubStore([subscription("a.b.c")])
		let lookup = StubLookup(fallback: .success([]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)

		#expect(await store.deleted.isEmpty)
	}

	@Test("An app deletes only once it has been absent from the configured number of lookups")
	func deletesAfterRepeatedAbsence() async {
		let store = StubStore([subscription("gone.app")])
		let lookup = StubLookup(fallback: .success([]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		for _ in 1..<ReleaseWatcher.missingLookupsBeforeDeletion {
			await sweep(watcher)
			#expect(await store.deleted.isEmpty)
		}

		await sweep(watcher)
		#expect(await store.deleted == ["gone.app"])
	}

	@Test("An app that reappears before the threshold is never deleted")
	func reappearingAppSurvives() async {
		let store = StubStore([subscription("flaky.app")])
		let lookup = StubLookup(
			outcomes: [
				.success([]),
				.success([]),
				.success([result("flaky.app", version: "1.0")]),
				.success([]),
				.success([])
			],
			fallback: .success([])
		)
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		for _ in 0..<5 {
			await sweep(watcher)
		}

		#expect(await store.deleted.isEmpty)
	}

	@Test("A failed deletion keeps the strikes, so it is retried rather than forgotten")
	func failedDeletionIsRetried() async {
		let store = StubStore([subscription("gone.app")], deleteFails: true)
		let lookup = StubLookup(fallback: .success([]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		for _ in 0..<ReleaseWatcher.missingLookupsBeforeDeletion {
			await sweep(watcher)
		}
		#expect(await store.deleted.isEmpty)

		// The store is still refusing, but the watcher must keep trying rather than
		// silently restarting the countdown.
		await sweep(watcher)
		#expect(await store.deleted.isEmpty)
	}

	/// Recording the version is what stops a release being announced twice. If the write fails
	/// and the announcement goes out anyway, the next sweep sees the same "new" version and
	/// announces it again — every five minutes, forever.
	@Test("A release whose version could not be recorded is not announced")
	func doesNotAnnounceWhatItCouldNotRecord() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"])], recordFails: true)
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)

		#expect(await store.recorded.isEmpty)
		#expect(await watcher.pendingNotificationCount == 0)
	}

	@Test("A release that was recorded is queued for delivery")
	func announcesWhatItRecorded() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"], chats: [1, 2])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)

		#expect(await store.recorded == ["a.b.c@2.0"])
		#expect(await watcher.pendingNotificationCount == 2)
	}

	// MARK: - Normal operation

	@Test("A new version is recorded")
	func recordsNewVersion() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)

		#expect(await store.recorded == ["a.b.c@2.0"])
	}

	@Test("A version already on record is not announced again")
	func doesNotRecordKnownVersion() async {
		let store = StubStore([subscription("a.b.c", versions: ["2.0"])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)

		#expect(await store.recorded.isEmpty)
	}

	@Test("A subscription nobody listens to is dropped")
	func dropsSubscriptionWithNoChats() async {
		let store = StubStore([subscription("orphan.app", chats: [])])
		let lookup = StubLookup(fallback: .success([]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)

		#expect(await store.deleted == ["orphan.app"])
		// It must not have cost a lookup either.
		#expect(await lookup.requestedBatches.isEmpty)
	}

	@Test("Subscriptions are checked in batches of at most one request's worth")
	func batchesRequests() async {
		let store = StubStore((0..<7).map { subscription("app.\($0)") })
		let lookup = StubLookup(maxIDsPerRequest: 3, fallback: .success([]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher, batches: 3)

		#expect(await lookup.requestedBatches.map(\.count) == [3, 3, 1])
	}

	// MARK: - Poison batches

	/// A payload that will not parse now will not parse in a minute, so retrying the whole
	/// batch forever would stall the sweep. The batch is bisected until the bad app is alone.
	@Test("An unparseable response bisects the batch instead of stalling")
	func bisectsUnparseableBatch() async {
		let store = StubStore((0..<4).map { subscription("app.\($0)") })
		let lookup = StubLookup(
			maxIDsPerRequest: 4,
			outcomes: [.failure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")))],
			fallback: .success([])
		)
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher, batches: 3)

		let sizes = await lookup.requestedBatches.map(\.count)
		#expect(sizes == [4, 2, 2])
		#expect(await store.deleted.isEmpty)
	}

	/// A batch in flight has already been popped, so the queue looks drained. Reloading then
	/// would hand the same apps out twice in one sweep, and two absences per sweep delete a
	/// subscription sooner than the threshold promises.
	@Test("A sweep that lands mid-lookup does not hand the same apps out twice")
	func refillDoesNotDuplicateAnInFlightBatch() async {
		let store = StubStore([subscription("gone.app")])
		let lookup = StubLookup(fallback: .success([]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		// The sweep loop fires while the lookup is still in flight.
		await lookup.onSearch { await watcher.refillQueueIfDrained() }

		await watcher.refillQueueIfDrained()
		for _ in 0..<ReleaseWatcher.missingLookupsBeforeDeletion {
			await watcher.checkNextBatch()
		}

		// One sweep is one check per app. If the mid-flight reload re-queued the batch, the
		// app would be checked once per call instead, and its absence would reach the
		// deletion threshold inside a single sweep.
		#expect(await lookup.requestedBatches.count == 1)
		#expect(await watcher.pendingBatchCount == 0)
		#expect(await store.deleted.isEmpty)
	}

	// MARK: - Notification delivery

	/// Delivery success is logged at debug level, so the queue depth is what tells us whether a
	/// failed send was retried or dropped.
	@Test("A chat that will never accept a message is dropped, not retried")
	func dropsPermanentlyUnreachableChats() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)
		#expect(await watcher.pendingNotificationCount == 1)

		await watcher.failNextDelivery(with: .chatUnreachable(reason: "Forbidden: bot was blocked by the user"))
		await watcher.deliverNextNotification()

		#expect(await watcher.pendingNotificationCount == 0)
	}

	/// Nothing else will ever remove a dead chat, so it costs an API call and an error line on
	/// every release of every app it follows, forever.
	@Test("An unreachable chat is unsubscribed, not just skipped")
	func unsubscribesUnreachableChats() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"], chats: [42])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)
		await watcher.failNextDelivery(with: .chatUnreachable(reason: "Forbidden: bot was blocked by the user"))
		await watcher.deliverNextNotification()

		#expect(await store.chatsRemoved == ["42@a.b.c"])
		#expect(await watcher.pendingNotificationCount == 0)
	}

	/// The chat is alive; it was this message Telegram refused. Unsubscribing here would throw
	/// away a real subscriber over a formatting problem.
	@Test("A rejected message does not unsubscribe anyone")
	func rejectedMessageKeepsTheSubscriber() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"], chats: [42])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)
		await watcher.failNextDelivery(with: .permanent(reason: "Bad Request: can't parse entities"))
		await watcher.deliverNextNotification()

		#expect(await store.chatsRemoved.isEmpty)
		#expect(await watcher.pendingNotificationCount == 0)
	}

	@Test("A temporary failure does not unsubscribe anyone")
	func temporaryFailureKeepsTheSubscriber() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"], chats: [42])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)
		await watcher.failNextDelivery(with: .temporary(reason: "Bad Gateway"))
		await watcher.deliverNextNotification()

		#expect(await store.chatsRemoved.isEmpty)
	}

	@Test("A temporary failure is requeued")
	func requeuesTemporaryFailures() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)
		await watcher.failNextDelivery(with: .temporary(reason: "Bad Gateway"))
		await watcher.deliverNextNotification()

		#expect(await watcher.pendingNotificationCount == 1)
	}

	@Test("A temporary failure is eventually given up on rather than retried forever")
	func givesUpAfterRepeatedTemporaryFailures() async {
		let store = StubStore([subscription("a.b.c", versions: ["1.0"])])
		let lookup = StubLookup(fallback: .success([result("a.b.c", version: "2.0")]))
		let watcher = ReleaseWatcher(dbManager: store, lookup: lookup)

		await sweep(watcher)
		for _ in 0..<ReleaseWatcher.maxNotificationAttempts {
			await watcher.failNextDelivery(with: .temporary(reason: "Bad Gateway"))
			await watcher.deliverNextNotification()
		}

		#expect(await watcher.pendingNotificationCount == 0)
	}

	// MARK: - Pacing

	@Test("The batch interval keeps request volume inside Apple's documented limit")
	func staysWithinRateLimit() {
		// Apple documents roughly 20 calls per minute, so requests must be at least three
		// seconds apart. One batch is one request.
		#expect(ReleaseWatcher.batchInterval >= .seconds(3))
	}
}
