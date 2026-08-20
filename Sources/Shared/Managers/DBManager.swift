//
//  DBManager.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import Foundation
import CouchDBClient
import Logging

fileprivate let logger = Logger(label: "DBManager")

public struct CouchConfig: Sendable {
	public var couchProtocol: CouchDBClient.CouchDBProtocol
	public var host: String
	public var port: Int
	public var user: String
	public var password: String
	public var timeout: Int64

	public init(
		couchProtocol: CouchDBClient.CouchDBProtocol = .http,
		host: String = "127.0.0.1",
		port: Int = 5984,
		user: String = "admin",
		password: String = ProcessInfo.processInfo.environment["COUCHDB_PASS"] ?? "",
		timeout: Int64 = 30
	) {
		self.couchProtocol = couchProtocol
		self.host = host
		self.port = port
		self.user = user
		self.password = password
		self.timeout = timeout
	}
}

public extension CouchConfig {
	static func makeProtocol(_ value: String) -> CouchDBClient.CouchDBProtocol {
		CouchDBClient.CouchDBProtocol(rawValue: value.lowercased()) ?? .http
	}
}

public actor DBManager {
	private static let dbName = "release_bot"

	private let store: any CouchDocumentStore

	public init(couchConfig: CouchConfig = CouchConfig()) {
		self.store = CouchDBDocumentStore(db: Self.dbName, config: couchConfig)
	}

	/// Used by tests to drive the read-modify-write logic without a database.
	init(store: any CouchDocumentStore) {
		self.store = store
	}

	/// Sets up the CouchDB database and required design documents.
	public func setupIfNeed() async throws {
		try await store.ensureSchema()
	}

	// MARK: - Reading

	/// Rows fetched per view request.
	///
	/// Sized against the 10 MB `couchdb-swift` will collect, not against anything larger: the
	/// views emit whole documents, and a single popular app's document carries every
	/// subscriber's chat ID, so a page of 500 could exceed that on its own. An unpaged read
	/// eventually fails outright, and then the watcher stops checking *everything*.
	static let viewPageSize = 100

	private static let byBundleURI = CouchDBDocumentStore.viewURI(CouchDBDocumentStore.byBundleView)
	private static let byChatURI = CouchDBDocumentStore.viewURI(CouchDBDocumentStore.byChatView)

	private func view(
		uri: String,
		queryItems: [URLQueryItem]? = nil
	) async throws -> LenientRowsResponse<Subscription> {
		let (statusCode, body) = try await store.fetchView(uri: uri, queryItems: queryItems)

		try CouchStatus.validate(statusCode: statusCode)

		let decoded = try JSONDecoder().decode(LenientRowsResponse<Subscription>.self, from: body)

		if !decoded.skippedRowIDs.isEmpty {
			logger.error(
				"Skipped unreadable subscription document(s) from \(uri): \(decoded.skippedRowIDs.joined(separator: ", "))"
			)
		}

		return decoded
	}

	/// Every document stored for a bundle ID.
	///
	/// Plural on purpose: the database does not enforce one document per app, and taking only
	/// the first is how a duplicate's subscribers became unreachable.
	private func subscriptions(forBundleID bundleID: String) async throws -> [Subscription] {
		try await view(uri: Self.byBundleURI, queryItems: ViewQuery.rows(matching: .string(bundleID))).values
	}

	public func search(byChatID chatID: Int64) async throws -> [Subscription] {
		try await view(uri: Self.byChatURI, queryItems: ViewQuery.rows(matching: .number(chatID))).values
	}

	// MARK: - Writing

	/// Whether `/add` actually changed anything.
	public enum SubscribeOutcome: Sendable, Equatable {
		case subscribed
		case alreadySubscribed
	}

	@discardableResult
	public func subscribeForNewVersions(
		_ result: SearchResult,
		forChatID chatID: Int64
	) async throws -> SubscribeOutcome {
		var outcome = SubscribeOutcome.subscribed

		try await resolvingConflicts {
			let existing = try await self.subscriptions(forBundleID: result.bundleID)
			let plan = SubscriptionPlanner.subscribe(result, chatID: chatID, existing: existing)

			outcome = plan.alreadySubscribed ? .alreadySubscribed : .subscribed

			// The keeper is written before the duplicates go, so an interruption can only
			// leave extra documents behind — never lose a subscriber.
			if let update = plan.update {
				_ = try await self.store.update(update)
			}

			if let insert = plan.insert {
				_ = try await self.store.insert(insert)
				logger.info("Subscription for \(insert.bundleID) has been added to the database.")
			}

			for duplicate in plan.deletions {
				try await self.store.delete(duplicate)
				logger.info("Consolidated a duplicate subscription document for \(duplicate.bundleID).")
			}
		}

		return outcome
	}

	public func unsubscribeFromNewVersions(_ bundleID: String, forChatID chatID: Int64) async throws -> Subscription? {
		var removedFrom: Subscription?

		try await resolvingConflicts {
			let existing = try await self.subscriptions(forBundleID: bundleID)
			let plan = SubscriptionPlanner.unsubscribe(chatID: chatID, from: existing)

			// Kept from the first attempt that saw the chat: a retry after a partial write may
			// legitimately find nothing left to remove, and reporting that as "not found"
			// would deny a `/del` that already took effect.
			if removedFrom == nil {
				removedFrom = plan.removedFrom
			}

			for document in plan.updates {
				_ = try await self.store.update(document)
			}

			for document in plan.deletions {
				try await self.store.delete(document)
			}
		}

		return removedFrom
	}

	public func deleteSubscription(_ subscription: Subscription) async throws {
		try await store.delete(subscription)
		logger.info("Subscription for \(subscription.bundleID) has been deleted from the database.")
	}

	/// Re-runs `work` when the store reports that someone else wrote first.
	///
	/// `DBManager` is an actor, but a read-modify-write suspends at every `await`, so two
	/// `/add` commands for one app can both see no existing document. Keying documents by
	/// bundle ID turns that into a conflict for the loser; re-reading then finds the winner's
	/// document and merges into it, rather than quietly creating a second one.
	private func resolvingConflicts(
		attempts: Int = 3,
		_ work: () async throws -> Void
	) async throws {
		// The final attempt sits outside the loop so its failure is rethrown structurally,
		// rather than depending on a `where` clause to fall through.
		for attempt in 1..<max(1, attempts) {
			do {
				return try await work()
			} catch StoreError.conflict {
				logger.info("Document conflict on attempt \(attempt) of \(attempts); re-reading.")
			}
		}

		try await work()
	}
}

// MARK: - Watcher methods
extension DBManager {
	public func getAllSubscriptions() async throws -> [Subscription] {
		var all = [Subscription]()
		var cursor: ViewCursor?

		while true {
			let response = try await view(
				uri: Self.byBundleURI,
				queryItems: ViewQuery.page(size: Self.viewPageSize, after: cursor)
			)

			all += response.rows.prefix(Self.viewPageSize).compactMap(\.value)

			guard response.rows.count > Self.viewPageSize else { break }

			guard let next = response.rows.last?.cursor else {
				// A row whose key or id could not be read cannot be resumed from. Stopping
				// here is a partial sweep, so say so rather than looking like a clean finish.
				logger.error("Stopped paging \(Self.byBundleURI) early: the next page's cursor is unreadable.")
				break
			}

			// Without this a key that fails to round-trip — or a lost `startkey_docid` —
			// re-reads the same page forever, and the watcher spins instead of sweeping.
			guard next != cursor else {
				logger.error("Stopped paging \(Self.byBundleURI) early: the cursor stopped advancing at \(next.documentID).")
				break
			}

			cursor = next
		}

		return all
	}

	/// Appends a version to a subscription's history.
	///
	/// Re-reads inside the retry rather than trusting the document passed in: the watcher hands
	/// over a `Subscription` loaded when the sweep started, which may be many batches old, and
	/// a `/add` landing in between bumps its `_rev`. This is the most frequent write in the
	/// system, so losing it to a conflict costs an announcement every time it happens.
	public func addNewVersion(_ version: String, forSubscription doc: Subscription) async throws {
		try await resolvingConflicts {
			let existing = try await self.subscriptions(forBundleID: doc.bundleID)

			guard var subscription = existing.first(where: { $0._id == doc._id }) ?? existing.first else {
				throw StoreError.notFound
			}

			// Another task may have recorded it while this one waited.
			guard !subscription.version.contains(version) else {
				logger.info("Version \(version) already recorded for \(subscription.bundleID).")
				return
			}

			subscription.title = doc.title
			subscription.url = doc.url
			subscription.version.append(version)
			while subscription.version.count > 5 {
				subscription.version.removeFirst()
			}

			_ = try await self.store.update(subscription)
			logger.info("New version \(version) has been added to subscription \(subscription.bundleID).")
		}
	}
}
