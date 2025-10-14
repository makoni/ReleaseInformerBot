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

// Codable struct for CouchDB design document
fileprivate struct DesignDocument: CouchDBRepresentable {
	let _id: String
	let language: String
	let views: [String: [String: String]]
	// Optionally add _rev if you want to support updates
	var _rev: String?

	func updateRevision(_ newRevision: String) -> DesignDocument {
		return DesignDocument(_id: _id, language: language, views: views, _rev: newRevision)
	}
}

public actor DBManager {
	private let db = "release_bot"
	private let couchDBClient: CouchDBClient

	public init(couchConfig: CouchConfig = CouchConfig()) {
		self.couchDBClient = makeClient(for: couchConfig)
	}

	/// Sets up the CouchDB database and required design documents.
	public func setupIfNeed() async throws {
		// 1. Check if DB exists using dbExists
		let dbExists = try await couchDBClient.dbExists(db)
		if !dbExists {
			try await couchDBClient.createDB(db)
			logger.info("Database \(db) created.")
		} else {
			logger.info("Database \(db) exists.")
		}

		// 3. Check and create design document for by_bundle and by_chat
		let designDocID = "_design/list"
		let byBundleViewMap = "function(doc) { emit(doc.bundle_id, doc); }"
		let byChatViewMap = "function(doc) { for (var i=0; i<doc.chats.length; i++) { emit(doc.chats[i], doc); } }"
		let designDoc = DesignDocument(
			_id: designDocID,
			language: "javascript",
			views: [
				"by_bundle": ["map": byBundleViewMap],
				"by_chat": ["map": byChatViewMap]
			]
		)

		var needsCreate = false
		do {
			let _: DesignDocument = try await couchDBClient.get(fromDB: db, uri: designDocID)
		} catch let error as CouchDBClientError {
			switch error {
			case .notFound:
				needsCreate = true
			default:
				logger.error("Unexpected error while checking design document: \(error.localizedDescription)")
				throw error
			}
		} catch {
			throw error
		}

		if needsCreate {
			_ = try await couchDBClient.insert(dbName: db, doc: designDoc)
			logger.info("Design document created with by_bundle and by_chat views.")
		} else {
			logger.info("Design document already exists.")
		}
	}

	public func subscribeForNewVersions(_ result: SearchResult, forChatID chatID: Int64) async throws {
		// Update existing subscription
		if var subscription = try await self.searchByBundleID(result.bundleID) {
			if !subscription.chats.contains(chatID) {
				subscription.chats.insert(chatID)
				_ = try await couchDBClient.update(dbName: db, doc: subscription)
			}
			return
		}

		// Add a new subscription
		let subscription = Subscription(
			bundleID: result.bundleID,
			url: result.url,
			title: result.title,
			version: [result.version],
			chats: [chatID]
		)
		_ = try await couchDBClient.insert(dbName: db, doc: subscription)
		logger.info("Subscription for \(result.bundleID) has been added to the database.")
	}

	public func unsubscribeFromNewVersions(_ bundleID: String, forChatID chatID: Int64) async throws -> Subscription? {
		guard var subscription = try await self.searchByBundleID(bundleID) else { return nil }

		if subscription.chats.contains(chatID) {
			subscription.chats.remove(chatID)

			if !subscription.chats.isEmpty {
				subscription = try await couchDBClient.update(dbName: db, doc: subscription)
			} else {
				try await deleteSubscription(subscription)
			}
		}

		return subscription
	}

	public func deleteSubscription(_ subscription: Subscription) async throws {
		_ = try await couchDBClient.delete(fromDb: db, doc: subscription)
		logger.info("Subscription for \(subscription.bundleID) has been deleted from the database.")
	}

	private func searchByBundleID(_ bundleID: String) async throws -> Subscription? {
		let response = try await couchDBClient.get(
			fromDB: db,
			uri: "_design/list/_view/by_bundle",
			queryItems: [
				URLQueryItem(name: "key", value: "\"\(bundleID)\"")
			]
		)

		let expectedBytes =
			response.headers
			.first(name: "content-length")
			.flatMap(Int.init) ?? 1024 * 1024 * 10
		var bytes = try await response.body.collect(upTo: expectedBytes)

		guard let data = bytes.readData(length: bytes.readableBytes) else {
			logger.error("Failed to read response data.")
			return nil
		}

		let decoder = JSONDecoder()
		let subscriptions = try decoder.decode(
			RowsResponse<Subscription>.self,
			from: data
		).rows.map({ $0.value })

		return subscriptions.first
	}

	public func search(byChatID chatID: Int64) async throws -> [Subscription] {
		let response = try await couchDBClient.get(
			fromDB: db,
			uri: "_design/list/_view/by_chat",
			queryItems: [
				URLQueryItem(name: "key", value: "\(chatID)")
			]
		)

		let expectedBytes =
			response.headers
			.first(name: "content-length")
			.flatMap(Int.init) ?? 1024 * 1024 * 10
		var bytes = try await response.body.collect(upTo: expectedBytes)

		guard let data = bytes.readData(length: bytes.readableBytes) else {
			logger.error("Failed to read response data.")
			return []
		}

		let decoder = JSONDecoder()
		let subscriptions = try decoder.decode(
			RowsResponse<Subscription>.self,
			from: data
		).rows.map({ $0.value })

		return subscriptions
	}
}

// MARK: - Watcher methods
extension DBManager {
	public func getAllSubscriptions() async throws -> [Subscription] {
		let response = try await couchDBClient.get(
			fromDB: db,
			uri: "_design/list/_view/by_bundle"
		)

		let expectedBytes =
			response.headers
			.first(name: "content-length")
			.flatMap(Int.init) ?? 1024 * 1024 * 10
		var bytes = try await response.body.collect(upTo: expectedBytes)

		guard let data = bytes.readData(length: bytes.readableBytes) else {
			logger.error("Failed to read response data.")
			return []
		}

		let decoder = JSONDecoder()
		let decoded = try decoder.decode(
			RowsResponse<Subscription>.self,
			from: data
		)

		return decoded.rows.map({ $0.value })
	}

	public func addNewVersion(_ version: String, forSubscription doc: Subscription) async throws {
		var subscription = doc
		subscription.version.append(version)
		while subscription.version.count > 5 {
			subscription.version.removeFirst()
		}

		_ = try await couchDBClient.update(dbName: db, doc: subscription)
		logger.info("New version \(version) has been added to subscription \(subscription.bundleID).")
	}
}
