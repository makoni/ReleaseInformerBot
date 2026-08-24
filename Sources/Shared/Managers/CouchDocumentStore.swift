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
				requestsTimeout: config.timeout,
				maxResponseBytes: Self.maxResponseBytes
			)
		)
	}

	/// The views this store serves, named once so a rename cannot drift apart from the design
	/// document that defines them.
	public static let byBundleView = "by_bundle"
	public static let byChatView = "by_chat"

	public static func viewURI(_ view: String) -> String { "_design/list/_view/\(view)" }

	public func ensureSchema() async throws {
		try await translatingErrors {
			if try await client.dbExists(db) {
				logger.info("Database \(db) exists.")
			} else {
				try await client.createDB(db)
				logger.info("Database \(db) created.")
			}
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
		} catch {
			logger.error("Unexpected error while checking design document: \(error)")
			throw Self.storeError(from: error)
		}

		guard needsCreate else {
			logger.info("Design document already exists.")
			return
		}

		try await translatingErrors { _ = try await client.insert(dbName: db, doc: designDoc) }
		logger.info("Design document created with by_bundle and by_chat views.")
	}

	/// The largest response body we will buffer.
	///
	/// Handed to the library as well, so its bound and ours are the same number rather than
	/// two constants kept in step by hand. The library collects the body before returning it,
	/// so the local `collect` below can only ever see something already within this limit —
	/// and `DBManager.viewPageSize` is sized against it.
	static let maxResponseBytes = 10 * 1024 * 1024

	public func fetchView(uri: String, queryItems: [URLQueryItem]?) async throws -> (statusCode: Int, body: Data) {
		try await translatingErrors {
			let response = try await client.get(fromDB: db, uri: uri, queryItems: queryItems)
			let bytes = try await response.body.collect(upTo: Self.maxResponseBytes)
			return (Int(response.status.code), Data(bytes.readableBytesView))
		}
	}

	public func insert(_ document: Subscription) async throws -> Subscription {
		try await translatingErrors { try await client.insert(dbName: db, doc: document) }
	}

	public func update(_ document: Subscription) async throws -> Subscription {
		try await translatingErrors { try await client.update(dbName: db, doc: document) }
	}

	/// Runs `work`, translating anything it throws into a ``StoreError``.
	///
	/// Every operation goes through this so the store speaks one vocabulary. Catching only
	/// `CouchDBClientError` was not enough: the library propagates a raw `DecodingError` when a
	/// body parses as neither its model nor a CouchDB error — a reverse proxy's HTML error page,
	/// say — and its size limit surfaces as `NIOTooManyBytesError`. Both used to escape
	/// untranslated, which is the leak `StoreError` exists to close.
	func translatingErrors<T>(_ work: () async throws -> T) async throws -> T {
		do {
			return try await work()
		} catch let cancellation as CancellationError {
			// Not a database fault. Mapping it would log a server error on every graceful
			// shutdown and hide the cancellation from the caller.
			throw cancellation
		} catch {
			throw Self.storeError(from: error)
		}
	}

	/// Interprets a failure from the client.
	///
	/// Thin now: couchdb-swift 3.1.0 throws `.conflictError` for a 409 and `.noData` for an
	/// empty body, so there is little left to infer. Before that a delete conflict arrived as a
	/// `DecodingError` and had to be read as contention, which also swallowed genuine 400, 412
	/// and 5xx responses — hence the pinned minimum of 3.1.0 in `Package.swift`. A decoding
	/// failure means what it says again: the response did not match the model.
	///
	/// One edge remains: 3.1.0 checks for an empty body *before* it checks the status, so a 409
	/// that arrives with no body still surfaces as `.noData` rather than as a conflict, and is
	/// therefore not retried.
	static func storeError(from error: any Error) -> StoreError {
		switch error {
		case let couch as CouchDBClientError:
			return StoreError(couch)
		default:
			return .unexpectedResponse
		}
	}

	public func delete(_ document: Subscription) async throws {
		let response = try await translatingErrors { try await client.delete(fromDb: db, doc: document) }
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
