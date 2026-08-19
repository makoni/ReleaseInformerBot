//
//  CouchDocumentStore.swift
//  ReleaseInformerBot
//

import CouchDBClient
import Foundation
import Logging

/// The CouchDB operations ``DBManager`` performs.
///
/// A seam rather than a direct dependency, because `DBManager`'s read-modify-write steps are
/// where a mistake costs users their subscriptions — a duplicate document that hides
/// subscribers, or an error response mistaken for "no subscriptions". Those need tests, and
/// tests need something other than a live database.
public protocol CouchDocumentStore: Sendable {
	/// Creates the database and its design documents if they are missing.
	func ensureSchema() async throws

	/// Reads a view, returning the raw status and body so the caller can decide what a
	/// non-success status means.
	func fetchView(uri: String, queryItems: [URLQueryItem]?) async throws -> (statusCode: Int, body: Data)

	func insert(_ document: Subscription) async throws -> Subscription
	func update(_ document: Subscription) async throws -> Subscription
	func delete(_ document: Subscription) async throws
}

// Codable struct for CouchDB design document
private struct DesignDocument: CouchDBRepresentable {
	let _id: String
	let language: String
	let views: [String: [String: String]]
	var _rev: String?

	func updateRevision(_ newRevision: String) -> DesignDocument {
		DesignDocument(_id: _id, language: language, views: views, _rev: newRevision)
	}
}

/// Talks to a real CouchDB server.
public actor CouchDBDocumentStore: CouchDocumentStore {
	private let db: String
	private let client: CouchDBClient
	private let logger = Logger(label: "CouchDBDocumentStore")

	public init(db: String, config: CouchConfig) {
		self.db = db
		self.client = CouchDBClient(
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

	public func ensureSchema() async throws {
		if try await client.dbExists(db) {
			logger.info("Database \(db) exists.")
		} else {
			try await client.createDB(db)
			logger.info("Database \(db) created.")
		}

		let designDocID = "_design/list"
		let designDoc = DesignDocument(
			_id: designDocID,
			language: "javascript",
			views: [
				"by_bundle": ["map": "function(doc) { emit(doc.bundle_id, doc); }"],
				"by_chat": [
					"map": "function(doc) { for (var i=0; i<doc.chats.length; i++) { emit(doc.chats[i], doc); } }"
				]
			]
		)

		var needsCreate = false
		do {
			let _: DesignDocument = try await client.get(fromDB: db, uri: designDocID)
		} catch CouchDBClientError.notFound {
			needsCreate = true
		} catch let error as CouchDBClientError {
			logger.error("Unexpected error while checking design document: \(error.localizedDescription)")
			throw error
		}

		guard needsCreate else {
			logger.info("Design document already exists.")
			return
		}

		_ = try await client.insert(dbName: db, doc: designDoc)
		logger.info("Design document created with by_bundle and by_chat views.")
	}

	public func fetchView(uri: String, queryItems: [URLQueryItem]?) async throws -> (statusCode: Int, body: Data) {
		let response = try await client.get(fromDB: db, uri: uri, queryItems: queryItems)

		let expectedBytes =
			response.headers
			.first(name: "content-length")
			.flatMap(Int.init) ?? DBManager.maxResponseBytes
		let bytes = try await response.body.collect(upTo: max(expectedBytes, DBManager.maxResponseBytes))

		return (Int(response.status.code), Data(bytes.readableBytesView))
	}

	public func insert(_ document: Subscription) async throws -> Subscription {
		try await client.insert(dbName: db, doc: document)
	}

	public func update(_ document: Subscription) async throws -> Subscription {
		try await client.update(dbName: db, doc: document)
	}

	public func delete(_ document: Subscription) async throws {
		_ = try await client.delete(fromDb: db, doc: document)
	}
}
