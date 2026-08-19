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

fileprivate func makeClient(for config: CouchConfig) -> CouchDBClient {
	CouchDBClient(
		config: .init(
			couchProtocol: config.couchProtocol,
			couchHost: config.host,
			couchPort: config.port,
			userName: config.user,
			userPassword: config.password,
			requestsTimeout: config.timeout
		)
	)
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

	/// How many view rows are fetched per request.
	///
	/// The `by_bundle` view emits whole documents, so an unpaged read grows without bound and
	/// eventually exceeds any body limit — at which point the watcher stops checking
	/// *everything*, with only a log line to say so.
	static let viewPageSize = 500

	/// Generous, because a page is already bounded by ``viewPageSize``.
	static let maxResponseBytes = 64 * 1024 * 1024

	private static let byBundleView = "_design/list/_view/by_bundle"
	private static let byChatView = "_design/list/_view/by_chat"

	private func view(
		uri: String,
		queryItems: [URLQueryItem]? = nil
	) async throws -> LenientRowsResponse<Subscription> {
		let (statusCode, body) = try await store.fetchView(uri: uri, queryItems: queryItems)

		// The library only throws for 401 and 404, so without this a 500 or a proxy error page
		// reaches the decoder and is reported as a model problem — or worse, as "no apps".
		try CouchStatus.validate(statusCode: statusCode)

		let decoded = try JSONDecoder().decode(LenientRowsResponse<Subscription>.self, from: body)

		if decoded.skippedRowCount > 0 {
			logger.error("Skipped \(decoded.skippedRowCount) unreadable subscription document(s) from \(uri).")
		}

		return decoded
	}

	/// Every document stored for a bundle ID.
	///
	/// Plural on purpose: the database does not enforce one document per app, and taking only
	/// the first is how a duplicate's subscribers became unreachable.
	private func subscriptions(forBundleID bundleID: String) async throws -> [Subscription] {
		try await view(
			uri: Self.byBundleView,
			queryItems: [URLQueryItem(name: "key", value: "\"\(bundleID)\"")]
		).values
	}

	public func search(byChatID chatID: Int64) async throws -> [Subscription] {
		try await view(
			uri: Self.byChatView,
			queryItems: [URLQueryItem(name: "key", value: "\(chatID)")]
		).values
	}

	// MARK: - Writing

	public func subscribeForNewVersions(_ result: SearchResult, forChatID chatID: Int64) async throws {
		try await resolvingConflicts {
			let existing = try await self.subscriptions(forBundleID: result.bundleID)
			let plan = SubscriptionPlanner.subscribe(result, chatID: chatID, existing: existing)

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
				try await self.deleteSubscription(duplicate)
				logger.info("Consolidated a duplicate subscription document for \(duplicate.bundleID).")
			}
		}
	}

	public func unsubscribeFromNewVersions(_ bundleID: String, forChatID chatID: Int64) async throws -> Subscription? {
		var removedFrom: Subscription?

		try await resolvingConflicts {
			let existing = try await self.subscriptions(forBundleID: bundleID)
			let plan = SubscriptionPlanner.unsubscribe(chatID: chatID, from: existing)

			for document in plan.updates {
				_ = try await self.store.update(document)
			}

			for document in plan.deletions {
				try await self.deleteSubscription(document)
			}

			removedFrom = plan.removedFrom
		}

		return removedFrom
	}

	public func deleteSubscription(_ subscription: Subscription) async throws {
		try await store.delete(subscription)
		logger.info("Subscription for \(subscription.bundleID) has been deleted from the database.")
	}

	/// Re-runs `work` when CouchDB rejects a write because another task got there first.
	///
	/// `DBManager` is an actor, but a read-modify-write suspends at every `await`, so two
	/// `/add` commands for one app can both see no existing document. Keying documents by
	/// bundle ID turns that into a 409 for the loser; re-reading then finds the winner's
	/// document and merges into it, rather than quietly creating a second one.
	private func resolvingConflicts(
		attempts: Int = 3,
		_ work: () async throws -> Void
	) async throws {
		for attempt in 1...attempts {
			do {
				try await work()
				return
			} catch let error as CouchDBClientError where error.isDocumentConflict && attempt < attempts {
				logger.info("Document conflict on attempt \(attempt) of \(attempts); re-reading.")
			}
		}
	}
}

// MARK: - Watcher methods
extension DBManager {
	public func getAllSubscriptions() async throws -> [Subscription] {
		var all = [Subscription]()
		var start: (key: String, id: String)?

		while true {
			// One row beyond the page: if it arrives, it is where the next page starts.
			var queryItems = [URLQueryItem(name: "limit", value: "\(Self.viewPageSize + 1)")]
			if let start {
				queryItems.append(URLQueryItem(name: "startkey", value: "\"\(start.key)\""))
				queryItems.append(URLQueryItem(name: "startkey_docid", value: start.id))
			}

			let response = try await view(uri: Self.byBundleView, queryItems: queryItems)

			all += response.rows.prefix(Self.viewPageSize).compactMap(\.value)

			// `startkey_docid` rather than `skip`, so duplicate keys spanning a page boundary
			// are handled and paging does not get quadratically slower as the corpus grows.
			guard response.rows.count > Self.viewPageSize,
				let overflow = response.rows.last,
				let key = overflow.key,
				let id = overflow.id
			else { break }

			start = (key, id)
		}

		return all
	}

	public func addNewVersion(_ version: String, forSubscription doc: Subscription) async throws {
		var subscription = doc
		subscription.version.append(version)
		while subscription.version.count > 5 {
			subscription.version.removeFirst()
		}

		_ = try await store.update(subscription)
		logger.info("New version \(version) has been added to subscription \(subscription.bundleID).")
	}
}
