//
//  DBManagerTests.swift
//  ReleaseInformerBot
//

import CouchDBClient
import Foundation
import Testing

@testable import Shared

/// The errors the real client raises, so the retry path under test is the production one.
private enum StubCouchError {
	private static func couchError(_ error: String, reason: String) -> CouchDBError {
		// `CouchDBError` has no public initialiser; the library decodes it from the response.
		let json = "{\"error\":\"\(error)\",\"reason\":\"\(reason)\"}"
		return try! JSONDecoder().decode(CouchDBError.self, from: Data(json.utf8))
	}

	static let insertConflict = CouchDBClientError.insertError(
		error: couchError("conflict", reason: "Document update conflict.")
	)
	static let updateConflict = CouchDBClientError.updateError(
		error: couchError("conflict", reason: "Document update conflict.")
	)
	static let notFound = CouchDBClientError.notFound(
		error: couchError("not_found", reason: "missing")
	)
}

/// A stand-in for CouchDB with the behaviour that matters here: documents are keyed by `_id`,
/// an insert onto an existing key is a conflict, an update with a stale `_rev` is a conflict,
/// and views are returned in `(key, id)` order.
private actor StubCouchStore: CouchDocumentStore {
	private var documents = [String: Subscription]()
	private var revisionCounter = 0
	private var forcedStatus: Int?
	private var rawRows = [String]()

	private var barrierSize = 0
	private var waiting = [CheckedContinuation<Void, Never>]()

	private(set) var viewReads = 0
	private(set) var insertAttempts = 0

	init(_ documents: [Subscription] = []) {
		for document in documents {
			self.documents[document._id] = document
		}
	}

	// MARK: - Test controls

	var storedDocuments: [Subscription] {
		documents.values.sorted { $0._id < $1._id }
	}

	func forceStatus(_ code: Int) {
		forcedStatus = code
	}

	/// Adds a row the decoder cannot read, standing in for a document written by an older
	/// version of the bot.
	func addUnreadableRow() {
		rawRows.append(#"{"id":"bad","key":"bad.app","value":{"_id":"bad","bundle_id":"bad.app"}}"#)
	}

	/// Holds view reads until `count` of them have arrived, so a read-modify-write can be made
	/// to interleave on purpose.
	func holdViewReads(untilCount count: Int) {
		barrierSize = count
	}

	// MARK: - CouchDocumentStore

	func ensureSchema() async throws {}

	func fetchView(uri: String, queryItems: [URLQueryItem]?) async throws -> (statusCode: Int, body: Data) {
		viewReads += 1

		if let forcedStatus {
			return (forcedStatus, Data(#"{"error":"internal_server_error","reason":"boom"}"#.utf8))
		}

		let items = Dictionary(
			(queryItems ?? []).map { ($0.name, $0.value ?? "") },
			uniquingKeysWith: { first, _ in first }
		)

		var rows = documents.values.flatMap { document in
			viewKeys(for: document, uri: uri).map { (key: $0, id: document._id, document: document) }
		}

		if let key = items["key"] {
			let wanted = key.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
			rows = rows.filter { $0.key == wanted }
		}

		rows.sort { ($0.key, $0.id) < ($1.key, $1.id) }

		if let startKey = items["startkey"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) {
			let startID = items["startkey_docid"] ?? ""
			rows = rows.filter { ($0.key, $0.id) >= (startKey, startID) }
		}

		if let limit = items["limit"].flatMap(Int.init) {
			rows = Array(rows.prefix(limit))
		}

		// Encoded before waiting, so every held reader observes the same pre-write state —
		// which is what made the original race a race.
		let body = try encode(rows: rows)

		if barrierSize > 0 {
			await waitAtBarrier()
		}

		return (200, body)
	}

	func insert(_ document: Subscription) async throws -> Subscription {
		insertAttempts += 1

		guard documents[document._id] == nil else {
			throw StubCouchError.insertConflict
		}

		revisionCounter += 1
		let stored = document.updateRevision("\(revisionCounter)-stub")
		documents[document._id] = stored
		return stored
	}

	func update(_ document: Subscription) async throws -> Subscription {
		guard let current = documents[document._id] else { throw StubCouchError.notFound }
		guard current._rev == document._rev else { throw StubCouchError.updateConflict }

		revisionCounter += 1
		let stored = document.updateRevision("\(revisionCounter)-stub")
		documents[document._id] = stored
		return stored
	}

	func delete(_ document: Subscription) async throws {
		guard documents[document._id] != nil else { throw StubCouchError.notFound }
		documents[document._id] = nil
	}

	// MARK: - Internals

	/// `by_bundle` emits one row per document; `by_chat` emits one per subscribed chat, the
	/// same as the real design document.
	private func viewKeys(for document: Subscription, uri: String) -> [String] {
		uri.hasSuffix("by_chat")
			? document.chats.sorted().map(String.init)
			: [document.bundleID]
	}

	private func encode(rows: [(key: String, id: String, document: Subscription)]) throws -> Data {
		let encoder = JSONEncoder()
		let encoded = try rows.map { row in
			let value = String(decoding: try encoder.encode(row.document), as: UTF8.self)
			return "{\"id\":\"\(row.id)\",\"key\":\"\(row.key)\",\"value\":\(value)}"
		}
		let all = encoded + rawRows
		return Data("{\"total_rows\":\(all.count),\"offset\":0,\"rows\":[\(all.joined(separator: ","))]}".utf8)
	}

	private func waitAtBarrier() async {
		guard waiting.count + 1 < barrierSize else {
			barrierSize = 0
			let held = waiting
			waiting.removeAll()
			for continuation in held {
				continuation.resume()
			}
			return
		}

		await withCheckedContinuation { waiting.append($0) }
	}
}

@Suite("DBManager against a stubbed store")
struct DBManagerTests {
	private func result(_ bundleID: String, version: String = "1.0") -> SearchResult {
		SearchResult(
			title: "App",
			bundleID: bundleID,
			url: "https://example.com/\(bundleID)",
			version: version
		)
	}

	private func doc(_ id: String, bundleID: String = "a.b.c", chats: Set<Int64>) -> Subscription {
		Subscription(
			_id: id,
			_rev: "0-stub",
			bundleID: bundleID,
			url: "https://example.com",
			title: "MyApp",
			version: ["1.0"],
			chats: chats
		)
	}

	// MARK: - The concurrent-subscribe bug

	/// `DBManager` is an actor, but a read-modify-write suspends at every `await`, so two
	/// `/add` commands for one app could both see no existing document and both insert. The
	/// documents were keyed by a fresh UUID, so CouchDB had no way to object — leaving two
	/// documents where only the first is ever found: `/del` misses the other's subscribers
	/// while the watcher notifies everyone twice.
	@Test("Two chats subscribing to the same app at once produce a single document")
	func concurrentSubscribesProduceOneDocument() async throws {
		let store = StubCouchStore()
		let dbManager = DBManager(store: store)
		let app = result("a.b.c")

		// Hold both reads so each sees an empty view, exactly as the race did.
		await store.holdViewReads(untilCount: 2)

		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask { try await dbManager.subscribeForNewVersions(app, forChatID: 1) }
			group.addTask { try await dbManager.subscribeForNewVersions(app, forChatID: 2) }
			try await group.waitForAll()
		}

		let stored = await store.storedDocuments
		#expect(stored.count == 1)
		#expect(stored.first?.chats == [1, 2])
		// Both really did try to insert; CouchDB, not luck, decided the winner.
		#expect(await store.insertAttempts == 2)
	}

	// MARK: - Error responses

	/// The library only throws for 401 and 404, so a 500 used to reach the decoder. An error
	/// body has no `rows`, and reading it as an empty view would mean "this user has no
	/// subscriptions" — or, for the watcher, "there is nothing to check".
	@Test("A server error is reported as an error, not as an empty result")
	func serverErrorIsNotAnEmptyResult() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		await store.forceStatus(500)
		let dbManager = DBManager(store: store)

		await #expect(throws: StoreError.requestFailed(statusCode: 500)) {
			_ = try await dbManager.getAllSubscriptions()
		}
		await #expect(throws: StoreError.requestFailed(statusCode: 500)) {
			_ = try await dbManager.search(byChatID: 1)
		}
	}

	@Test("Bad credentials are reported as such")
	func unauthorizedIsReported() async throws {
		let store = StubCouchStore()
		await store.forceStatus(401)
		let dbManager = DBManager(store: store)

		await #expect(throws: StoreError.unauthorized) {
			_ = try await dbManager.getAllSubscriptions()
		}
	}

	// MARK: - Unreadable documents

	/// One malformed document used to break every read for every user: the watcher would log a
	/// decoding error each sweep and check nothing at all.
	@Test("An unreadable document costs only itself")
	func unreadableDocumentIsSkipped() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1]), doc("d.e.f", bundleID: "d.e.f", chats: [1])])
		await store.addUnreadableRow()
		let dbManager = DBManager(store: store)

		let all = try await dbManager.getAllSubscriptions()
		#expect(all.map(\.bundleID).sorted() == ["a.b.c", "d.e.f"])
	}

	@Test("A chat's subscriptions are found whichever position it holds in a document")
	func findsSubscriptionsByChat() async throws {
		let store = StubCouchStore([
			doc("a.b.c", chats: [1, 2, 3]),
			doc("d.e.f", bundleID: "d.e.f", chats: [3])
		])
		let dbManager = DBManager(store: store)

		#expect(try await dbManager.search(byChatID: 2).map(\.bundleID) == ["a.b.c"])
		#expect(try await dbManager.search(byChatID: 3).map(\.bundleID).sorted() == ["a.b.c", "d.e.f"])
		#expect(try await dbManager.search(byChatID: 42).isEmpty)
	}

	// MARK: - Duplicate healing

	@Test("Subscribing folds pre-existing duplicate documents into one")
	func subscribeConsolidatesDuplicates() async throws {
		let store = StubCouchStore([
			doc("uuid-1", chats: [1]),
			doc("uuid-2", chats: [2])
		])
		let dbManager = DBManager(store: store)

		try await dbManager.subscribeForNewVersions(result("a.b.c"), forChatID: 3)

		let stored = await store.storedDocuments
		#expect(stored.count == 1)
		#expect(stored.first?.chats == [1, 2, 3])
	}

	/// Removing the chat from only the first document left the user subscribed through the
	/// other one — they kept getting notifications after `/del`.
	@Test("Unsubscribing removes the chat from every duplicate")
	func unsubscribeClearsAllDuplicates() async throws {
		let store = StubCouchStore([
			doc("uuid-1", chats: [1, 2]),
			doc("uuid-2", chats: [1])
		])
		let dbManager = DBManager(store: store)

		let removed = try await dbManager.unsubscribeFromNewVersions("a.b.c", forChatID: 1)

		#expect(removed != nil)
		let stored = await store.storedDocuments
		#expect(stored.map(\._id) == ["uuid-1"])
		#expect(stored.first?.chats == [2])
	}

	@Test("Unsubscribing a chat that was never subscribed reports nothing and writes nothing")
	func unsubscribeStranger() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		let dbManager = DBManager(store: store)

		#expect(try await dbManager.unsubscribeFromNewVersions("a.b.c", forChatID: 99) == nil)
		#expect(await store.storedDocuments.first?.chats == [1])
	}

	@Test("Unsubscribing the last chat deletes the document")
	func unsubscribeLastChat() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		let dbManager = DBManager(store: store)

		#expect(try await dbManager.unsubscribeFromNewVersions("a.b.c", forChatID: 1) != nil)
		#expect(await store.storedDocuments.isEmpty)
	}

	// MARK: - Paging

	/// The `by_bundle` view emits whole documents, so an unpaged read eventually exceeds any
	/// body limit — and then the watcher stops checking everything at once.
	@Test("Every subscription is returned even when it takes several pages")
	func readsAllPages() async throws {
		let count = DBManager.viewPageSize * 2 + 7
		let documents = (0..<count).map {
			doc("id-\(String(format: "%05d", $0))", bundleID: "app.\(String(format: "%05d", $0))", chats: [1])
		}
		let store = StubCouchStore(documents)
		let dbManager = DBManager(store: store)

		let all = try await dbManager.getAllSubscriptions()

		#expect(all.count == count)
		#expect(Set(all.map(\.bundleID)).count == count)
		// Three pages, so three reads — not one oversized one.
		#expect(await store.viewReads == 3)
	}

	@Test("A single page is read exactly once")
	func readsOnePageOnce() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		let dbManager = DBManager(store: store)

		#expect(try await dbManager.getAllSubscriptions().count == 1)
		#expect(await store.viewReads == 1)
	}

	@Test("An empty database yields no subscriptions")
	func emptyDatabase() async throws {
		let dbManager = DBManager(store: StubCouchStore())
		#expect(try await dbManager.getAllSubscriptions().isEmpty)
	}

	// MARK: - Version recording

	@Test("Recording a version keeps the history capped")
	func versionHistoryIsCapped() async throws {
		var subscription = doc("a.b.c", chats: [1])
		subscription.version = ["1.0", "2.0", "3.0", "4.0", "5.0"]
		let store = StubCouchStore([subscription])
		let dbManager = DBManager(store: store)

		try await dbManager.addNewVersion("6.0", forSubscription: subscription)

		#expect(await store.storedDocuments.first?.version == ["2.0", "3.0", "4.0", "5.0", "6.0"])
	}
}
