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
public struct CouchDBDocumentStore: CouchDocumentStore {
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

	/// The views this store serves, named once so a rename cannot drift apart from the design
	/// document that defines them.
	public static let byBundleView = "by_bundle"
	public static let byChatView = "by_chat"

	public static func viewURI(_ view: String) -> String { "_design/list/_view/\(view)" }

	public func ensureSchema() async throws {
		do {
			if try await client.dbExists(db) {
				logger.info("Database \(db) exists.")
			} else {
				try await client.createDB(db)
				logger.info("Database \(db) created.")
			}
		} catch let error as CouchDBClientError {
			throw StoreError(error)
		}

		let designDocID = "_design/list"
		let designDoc = DesignDocument(
			_id: designDocID,
			language: "javascript",
			views: [
				Self.byBundleView: ["map": "function(doc) { emit(doc.bundle_id, doc); }"],
				Self.byChatView: [
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
			throw StoreError(error)
		}

		guard needsCreate else {
			logger.info("Design document already exists.")
			return
		}

		do {
			_ = try await client.insert(dbName: db, doc: designDoc)
		} catch let error as CouchDBClientError {
			throw StoreError(error)
		}
		logger.info("Design document created with by_bundle and by_chat views.")
	}

	/// A second gate on the response size.
	///
	/// Not the real ceiling: `couchdb-swift` has already collected the whole body by the time
	/// it hands the response back, capped at its own `maxResponseBytes` (10 MB by default, and
	/// as of 3.1.0 a `content-length` header can no longer raise it). So this bounds what we
	/// agree to decode, not what was read — and page sizes are chosen against that 10 MB.
	static let maxResponseBytes = 10 * 1024 * 1024

	public func fetchView(uri: String, queryItems: [URLQueryItem]?) async throws -> (statusCode: Int, body: Data) {
		do {
			let response = try await client.get(fromDB: db, uri: uri, queryItems: queryItems)
			let bytes = try await response.body.collect(upTo: Self.maxResponseBytes)
			return (Int(response.status.code), Data(bytes.readableBytesView))
		} catch let error as CouchDBClientError {
			throw StoreError(error)
		}
	}

	public func insert(_ document: Subscription) async throws -> Subscription {
		do {
			return try await client.insert(dbName: db, doc: document)
		} catch let error as CouchDBClientError {
			throw StoreError(error)
		}
	}

	public func update(_ document: Subscription) async throws -> Subscription {
		do {
			return try await client.update(dbName: db, doc: document)
		} catch let error as CouchDBClientError {
			throw StoreError(error)
		}
	}

	/// Interprets a failure from `delete`.
	///
	/// Thin now: couchdb-swift 3.1.0 throws `.conflictError` for a 409 and `.noData` for an
	/// empty body, so there is nothing left to guess at. Before that a delete conflict arrived
	/// as a `DecodingError` and had to be read as contention, which also swallowed a genuine
	/// 400 or 5xx — hence the pinned minimum of 3.1.0 in `Package.swift`. A decoding failure
	/// means what it says again: the response did not match the model.
	///
	/// A free function so the translation is testable; the call itself needs a live server.
	static func storeError(fromDeleteFailure error: any Error) -> StoreError {
		switch error {
		case let couch as CouchDBClientError:
			return StoreError(couch)
		case let store as StoreError:
			return store
		default:
			return .unexpectedResponse
		}
	}

	public func delete(_ document: Subscription) async throws {
		let response: CouchUpdateResponse
		do {
			response = try await client.delete(fromDb: db, doc: document)
		} catch {
			throw Self.storeError(fromDeleteFailure: error)
		}

		try Self.verify(response)
	}

	/// Belt and braces. The library throws `.noData` for an empty body as of 3.1.0, so this
	/// only catches a `2xx` that somehow reports `ok: false` — but the alternative is
	/// discarding the result entirely, which would read a failed delete as a success.
	static func verify(_ response: CouchUpdateResponse) throws {
		guard response.ok else {
			throw StoreError.unexpectedResponse
		}
	}
}
