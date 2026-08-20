//
//  DBManagerTests.swift
//  ReleaseInformerBot
//

import Foundation
import Testing

@testable import Shared

private actor StubCouchStore: CouchDocumentStore {
	private var documents = [String: Subscription]()
	private var revisionCounter = 0
	private var forcedStatus: Int?
	private var unreadable = [String: String]()

	private var barrierSize = 0
	private var waiting = [CheckedContinuation<Void, Never>]()

	private var alwaysConflict = false
	private var deleteFails = false
	private var beforeFirstDelete: (@Sendable () async -> Void)?

	private(set) var viewReads = 0
	private(set) var insertAttempts = 0
	private(set) var deleteAttempts = 0
	private(set) var queriesSeen = [[URLQueryItem]]()

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

	/// Makes every write conflict, so retry exhaustion becomes reachable.
	func alwaysConflictOnWrite() {
		alwaysConflict = true
	}

	func failDeletes() {
		deleteFails = true
	}

	/// Moves every stored revision on, so the next write from a document read earlier hits a
	/// conflict — the way a concurrent `/add` or `/del` would.
	func bumpRevisions() {
		revisionCounter += 1
		for (id, document) in documents {
			documents[id] = document.updateRevision("\(revisionCounter)-bumped")
		}
	}

	/// Stores a document the decoder cannot read, standing in for one written by an older
	/// version of the bot. It participates in ordering and paging like any other row.
	func addUnreadableDocument(id: String, bundleID: String) {
		unreadable[id] = bundleID
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

		queriesSeen.append(queryItems ?? [])

		// A view URI that is not one of the two design-document views is a 404, so a renamed
		// view or a typo cannot pass unnoticed.
		guard uri == CouchDBDocumentStore.viewURI(CouchDBDocumentStore.byBundleView)
			|| uri == CouchDBDocumentStore.viewURI(CouchDBDocumentStore.byChatView)
		else {
			return (404, Data(#"{"error":"not_found","reason":"missing_named_view"}"#.utf8))
		}

		let items = Dictionary(
			(queryItems ?? []).map { ($0.name, $0.value ?? "") },
			uniquingKeysWith: { first, _ in first }
		)

		var rows = documents.values.flatMap { document in
			viewKeys(for: document, uri: uri).map { (key: $0, id: document._id, document: document) }
		}
		var brokenRows = unreadable.map { (key: $0.value, id: $0.key) }

		// CouchDB requires keys as JSON literals and answers 400 otherwise; accepting a bare
		// string here would bless a request that fails in production.
		func parsed(_ raw: String) -> String? {
			guard let data = try? JSONSerialization.jsonObject(with: Data("[\(raw)]".utf8)),
				let array = data as? [Any],
				let first = array.first
			else { return nil }
			if let text = first as? String { return text }
			if let number = first as? NSNumber { return "\(number.int64Value)" }
			return nil
		}

		if let raw = items["key"] {
			guard let wanted = parsed(raw) else {
				return (400, Data(#"{"error":"bad_request","reason":"invalid UTF-8 JSON"}"#.utf8))
			}
			rows = rows.filter { $0.key == wanted }
		}

		rows.sort { ($0.key, $0.id) < ($1.key, $1.id) }

        if let raw = items["startkey"] {
			guard let startKey = parsed(raw) else {
				return (400, Data(#"{"error":"bad_request","reason":"invalid UTF-8 JSON"}"#.utf8))
			}
			let startID = items["startkey_docid"] ?? ""
			rows = rows.filter { ($0.key, $0.id) >= (startKey, startID) }
		}

		// Merged and sorted with the rest, then trimmed together, so an unreadable row can be
		// the one a page boundary lands on.
		var merged: [(key: String, id: String, document: Subscription?)] =
			rows.map { (key: $0.key, id: $0.id, document: Optional($0.document)) }
			+ brokenRows.map { (key: $0.key, id: $0.id, document: nil) }
		merged.sort { ($0.key, $0.id) < ($1.key, $1.id) }
		brokenRows = []

		if let limit = items["limit"].flatMap(Int.init) {
			merged = Array(merged.prefix(limit))
		}

		// Encoded before waiting, so every held reader observes the same pre-write state —
		// which is what made the original race a race.
		let body = try encode(rows: merged, numericKeys: uri.hasSuffix(CouchDBDocumentStore.byChatView))

		if barrierSize > 0 {
			await waitAtBarrier()
		}

		return (200, body)
	}

	func insert(_ document: Subscription) async throws -> Subscription {
		insertAttempts += 1

		if alwaysConflict { throw StoreError.conflict }

		guard documents[document._id] == nil else {
			throw StoreError.conflict
		}

		revisionCounter += 1
		let stored = document.updateRevision("\(revisionCounter)-stub")
		documents[document._id] = stored
		return stored
	}

	func update(_ document: Subscription) async throws -> Subscription {
		if alwaysConflict { throw StoreError.conflict }

		guard let current = documents[document._id] else { throw StoreError.notFound }
		guard current._rev == document._rev else { throw StoreError.conflict }

		revisionCounter += 1
		let stored = document.updateRevision("\(revisionCounter)-stub")
		documents[document._id] = stored
		return stored
	}

	func onFirstDelete(_ body: @escaping @Sendable () async -> Void) {
		beforeFirstDelete = body
	}

	func delete(_ document: Subscription) async throws {
		deleteAttempts += 1

		if let hook = beforeFirstDelete {
			beforeFirstDelete = nil
			await hook()
		}

		if deleteFails {
			throw StoreError.unexpectedResponse
		}

		guard let current = documents[document._id] else { throw StoreError.notFound }
		// Real CouchDB rejects a stale-rev DELETE. Ignoring `_rev` here is what let a broken
		// delete-conflict path pass the suite.
		guard current._rev == document._rev else { throw StoreError.conflict }

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

	private func encode(rows: [(key: String, id: String, document: Subscription?)], numericKeys: Bool) throws -> Data {
		let encoder = JSONEncoder()
		let encoded = try rows.map { row in
			let value = try row.document.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
				?? "{\"_id\":\"\(row.id)\",\"bundle_id\":\"\(row.key)\"}"
			// `by_chat` emits a number, and the production decoder has to cope with both.
			let key = numericKeys ? row.key : "\"\(row.key)\""
			return "{\"id\":\"\(row.id)\",\"key\":\(key),\"value\":\(value)}"
		}
		return Data("{\"total_rows\":\(encoded.count),\"offset\":0,\"rows\":[\(encoded.joined(separator: ","))]}".utf8)
	}

	private func waitAtBarrier() async {
		guard waiting.count + 1 < barrierSize else {
			releaseBarrier()
			return
		}

		// Released after a deadline as well as on arrival: if a change makes this path take
		// fewer view reads, the test should fail on its assertions rather than hang the whole
		// suite with no diagnostic.
		let deadline = Task { [weak self] in
			try? await Task.sleep(for: .seconds(2))
			await self?.releaseBarrier()
		}
		await withCheckedContinuation { waiting.append($0) }
		deadline.cancel()
	}

	private func releaseBarrier() {
		barrierSize = 0
		let held = waiting
		waiting.removeAll()
		for continuation in held {
			continuation.resume()
		}
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
		await store.addUnreadableDocument(id: "bad", bundleID: "bad.app")
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

	// MARK: - Paging with duplicate keys

	/// `startkey` alone cannot advance through a run of documents that share a key, and
	/// `by_bundle` emits `doc.bundle_id`, which the database does not force to be unique.
	/// Without `startkey_docid` this re-reads the same page forever and the watcher spins
	/// instead of sweeping.
	@Test("Paging advances through documents that all share one key")
	func pagesThroughDuplicateKeys() async throws {
		let count = DBManager.viewPageSize * 2 + 2
		let documents = (0..<count).map {
			doc("id-\(String(format: "%05d", $0))", bundleID: "same.app", chats: [1])
		}
		let store = StubCouchStore(documents)
		let dbManager = DBManager(store: store)

		let all = try await dbManager.getAllSubscriptions()

		#expect(all.count == count)
		#expect(Set(all.map(\._id)).count == count)
	}

	@Test("An unreadable document at a page boundary does not stall the sweep")
	func unreadableRowAtPageBoundary() async throws {
		let documents = (0..<DBManager.viewPageSize).map {
			doc("id-\(String(format: "%05d", $0))", bundleID: "app.\(String(format: "%05d", $0))", chats: [1])
		}
		let store = StubCouchStore(documents)
		// Sorts last, so it becomes the overflow row that the next page would resume from.
		await store.addUnreadableDocument(id: "zzz", bundleID: "zzz.app")
		let dbManager = DBManager(store: store)

		let all = try await dbManager.getAllSubscriptions()
		#expect(all.count == DBManager.viewPageSize)
	}

	// MARK: - Write conflicts

	/// The common production race: the document already exists, so two writers read the same
	/// `_rev` and the loser gets a conflict on update rather than on insert.
	@Test("An update conflict is retried and both chats survive")
	func updateConflictIsRetried() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		let dbManager = DBManager(store: store)
		let app = result("a.b.c")

        await store.holdViewReads(untilCount: 2)

		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask { _ = try await dbManager.subscribeForNewVersions(app, forChatID: 2) }
			group.addTask { _ = try await dbManager.subscribeForNewVersions(app, forChatID: 3) }
			try await group.waitForAll()
		}

		let stored = await store.storedDocuments
		#expect(stored.count == 1)
		#expect(stored.first?.chats == [1, 2, 3])
	}

	@Test("A conflict that never clears is surfaced rather than reported as success")
	func retryExhaustionThrows() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		await store.alwaysConflictOnWrite()
		let dbManager = DBManager(store: store)

		await #expect(throws: StoreError.conflict) {
			_ = try await dbManager.subscribeForNewVersions(result("a.b.c"), forChatID: 2)
		}
	}

	/// The keeper is written before any duplicate is deleted, so a failure here may leave an
	/// extra document — but never lose a subscriber.
	@Test("A delete that fails while consolidating keeps every chat")
	func failedConsolidationKeepsChats() async throws {
		let store = StubCouchStore([doc("uuid-1", chats: [1]), doc("uuid-2", chats: [2])])
		await store.failDeletes()
		let dbManager = DBManager(store: store)

		_ = try? await dbManager.subscribeForNewVersions(result("a.b.c"), forChatID: 3)

		let stored = await store.storedDocuments
		let allChats = stored.reduce(into: Set<Int64>()) { $0.formUnion($1.chats) }
		#expect(allChats == [1, 2, 3])
	}

	/// A delete conflict is the one the library reports as a decoding failure, so it is the
	/// easiest for a retry loop to miss — and consolidating duplicates deletes documents that
	/// another task may be holding.
	@Test("A delete that conflicts is retried rather than abandoning the plan")
	func deleteConflictIsRetried() async throws {
		let store = StubCouchStore([doc("uuid-1", chats: [1]), doc("uuid-2", chats: [2])])
		let dbManager = DBManager(store: store)

		// The plan is built from documents read before this, so its delete carries a stale rev.
		await store.onFirstDelete { await store.bumpRevisions() }

		_ = try await dbManager.subscribeForNewVersions(result("a.b.c"), forChatID: 3)

		let stored = await store.storedDocuments
		#expect(stored.count == 1)
		#expect(stored.first?.chats == [1, 2, 3])
		// It really did have to go round again.
		#expect(await store.deleteAttempts > 1)
	}

	// MARK: - View wiring

	@Test("A missing design view is reported, not read as an empty database")
	func missingViewIsReported() async throws {
		let store = StubCouchStore()
		await store.forceStatus(404)
		let dbManager = DBManager(store: store)

		await #expect(throws: StoreError.notFound) {
			_ = try await dbManager.getAllSubscriptions()
		}
	}

	/// Group chats are large negative `Int64`s, and a numeric view key is exactly what the
	/// hand-rolled quoting used to get wrong.
	@Test("A negative group chat id round-trips through the view")
	func findsNegativeChatIDs() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [-1001234567890])])
		let dbManager = DBManager(store: store)

		#expect(try await dbManager.search(byChatID: -1001234567890).map(\.bundleID) == ["a.b.c"])
		#expect(try await dbManager.search(byChatID: 1001234567890).isEmpty)
	}

	// MARK: - Subscribe outcome

	@Test("Subscribing twice tells the caller nothing changed")
	func reportsAlreadySubscribed() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		let dbManager = DBManager(store: store)

		#expect(try await dbManager.subscribeForNewVersions(result("a.b.c"), forChatID: 1) == .alreadySubscribed)
		#expect(try await dbManager.subscribeForNewVersions(result("a.b.c"), forChatID: 2) == .subscribed)
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

	/// The watcher hands over a document loaded when the sweep started, which can be many
	/// batches old. A `/add` landing in between bumps `_rev`, and this is the most frequent
	/// write in the system — losing it to a conflict costs an announcement every time.
	@Test("Recording a version works from a document whose revision has moved on")
	func recordsVersionFromAStaleDocument() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		let dbManager = DBManager(store: store)

		var stale = doc("a.b.c", chats: [1])
		stale = stale.updateRevision("stale-rev")

		try await dbManager.addNewVersion("2.0", forSubscription: stale)

		#expect(await store.storedDocuments.first?.version == ["1.0", "2.0"])
	}

	@Test("A version already on record is not appended twice")
	func doesNotDoubleRecord() async throws {
		let store = StubCouchStore([doc("a.b.c", chats: [1])])
		let dbManager = DBManager(store: store)

		try await dbManager.addNewVersion("1.0", forSubscription: doc("a.b.c", chats: [1]))

		#expect(await store.storedDocuments.first?.version == ["1.0"])
	}

	@Test("Recording a version for a document that has since been deleted is reported")
	func recordingAgainstAMissingDocument() async {
		let dbManager = DBManager(store: StubCouchStore())

		await #expect(throws: StoreError.notFound) {
			try await dbManager.addNewVersion("2.0", forSubscription: doc("gone.app", chats: [1]))
		}
	}
}
