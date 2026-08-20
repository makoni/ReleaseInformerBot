//
//  DBManagerLogicTests.swift
//  ReleaseInformerBot
//

import CouchDBClient
import Foundation
import Testing

@testable import Shared

@Suite("CouchDB response validation")
struct CouchStatusTests {
	@Test("A successful status passes", arguments: [200, 201, 202, 204])
	func acceptsSuccess(status: Int) {
		#expect(throws: Never.self) {
			try CouchStatus.validate(statusCode: status)
		}
	}

	@Test("A missing document is its own error")
	func notFound() {
		#expect(throws: StoreError.notFound) {
			try CouchStatus.validate(statusCode: 404)
		}
	}

	@Test("Bad credentials are their own error", arguments: [401, 403])
	func unauthorized(status: Int) {
		#expect(throws: StoreError.unauthorized) {
			try CouchStatus.validate(statusCode: status)
		}
	}

	/// The library only throws for 401 and 404, so everything else used to be handed back
	/// with an error body that then failed to decode — surfacing a CouchDB outage as a
	/// confusing `keyNotFound("total_rows")`.
	@Test("Everything else keeps its status code", arguments: [400, 429, 500, 502, 503])
	func otherFailures(status: Int) {
		#expect(throws: StoreError.requestFailed(statusCode: status)) {
			try CouchStatus.validate(statusCode: status)
		}
	}
}

@Suite("Lenient view decoding")
struct LenientRowsResponseTests {
	private func decode(_ json: String) throws -> LenientRowsResponse<Subscription> {
		try JSONDecoder().decode(LenientRowsResponse<Subscription>.self, from: Data(json.utf8))
	}

	private func row(bundleID: String, version: String = "[\"1.0\"]") -> String {
		"""
		{"id":"\(bundleID)","key":"\(bundleID)","value":{"_id":"\(bundleID)","bundle_id":"\(bundleID)",\
		"url":"https://example.com","title":"\(bundleID)","version":\(version),"chats":[1]}}
		"""
	}

	@Test("Well-formed rows all decode")
	func decodesEveryRow() throws {
		let json = """
		{"total_rows":2,"offset":0,"rows":[\(row(bundleID: "a.b.c")),\(row(bundleID: "d.e.f"))]}
		"""
		let response = try decode(json)

		#expect(response.values.map(\.bundleID) == ["a.b.c", "d.e.f"])
		#expect(response.skippedRowIDs.isEmpty)
	}

	/// The whole point. `RowsResponse` decodes all-or-nothing, so a single malformed document
	/// used to break `getAllSubscriptions`, `search(byChatID:)` and `searchByBundleID` for
	/// every user at once — the watcher would log a decoding error every sweep and check
	/// nothing at all.
	@Test("One malformed document does not cost every other row")
	func skipsMalformedRow() throws {
		let broken = """
		{"id":"bad","key":"bad","value":{"_id":"bad","bundle_id":"bad.app","chats":[1]}}
		"""
		let json = """
		{"total_rows":3,"offset":0,"rows":[\(row(bundleID: "a.b.c")),\(broken),\(row(bundleID: "d.e.f"))]}
		"""
		let response = try decode(json)

		#expect(response.values.map(\.bundleID) == ["a.b.c", "d.e.f"])
		#expect(response.skippedRowIDs == ["bad"])
	}

	@Test("An empty view decodes to nothing")
	func decodesEmptyView() throws {
		let response = try decode("{\"total_rows\":0,\"offset\":0,\"rows\":[]}")
		#expect(response.values.isEmpty)
		#expect(response.skippedRowIDs.isEmpty)
	}

	/// A CouchDB error body has no `rows` at all, and must not be mistaken for an empty view
	/// — an empty result set is what drives subscription deletion.
	@Test("An error body is rejected rather than read as an empty view")
	func rejectsErrorBody() {
		#expect(throws: (any Error).self) {
			try decode("{\"error\":\"not_found\",\"reason\":\"missing\"}")
		}
	}

	@Test("A view response carrying only rows still decodes")
	func toleratesMinimalResponse() throws {
		let response = try decode("{\"rows\":[\(row(bundleID: "a.b.c"))]}")
		#expect(response.values.count == 1)
	}
}

@Suite("Subscribe planning")
struct SubscribePlannerTests {
	private func result(_ bundleID: String, version: String = "1.0") -> SearchResult {
		SearchResult(
			title: "App \(bundleID)",
			bundleID: bundleID,
			url: "https://example.com/\(bundleID)",
			version: version
		)
	}

	private func doc(_ id: String, bundleID: String, chats: Set<Int64>) -> Subscription {
		Subscription(
			_id: id,
			_rev: "1-abc",
			bundleID: bundleID,
			url: "https://example.com",
			title: "Stored",
			version: ["1.0"],
			chats: chats
		)
	}

	@Test("A brand-new app is inserted keyed by its bundle ID")
	func insertsNewSubscription() throws {
		let plan = SubscriptionPlanner.subscribe(result("a.b.c"), chatID: 7, existing: [])
		let insert = try #require(plan.insert)

		#expect(insert.bundleID == "a.b.c")
		#expect(insert.chats == [7])
		#expect(insert.version == ["1.0"])
		// Keying the document by its bundle ID is what lets CouchDB reject a concurrent
		// duplicate with a 409, instead of silently accepting two documents for one app.
		#expect(insert._id == "a.b.c")
		#expect(plan.update == nil)
		#expect(plan.deletions.isEmpty)
	}

	@Test("A chat is added to the existing document")
	func addsChatToExisting() throws {
		let existing = doc("a.b.c", bundleID: "a.b.c", chats: [1])
		let plan = SubscriptionPlanner.subscribe(result("a.b.c"), chatID: 2, existing: [existing])
		let update = try #require(plan.update)

		#expect(update.chats == [1, 2])
		#expect(update._id == existing._id)
		#expect(update._rev == existing._rev)
		#expect(plan.insert == nil)
		#expect(!plan.alreadySubscribed)
	}

	@Test("Subscribing twice writes nothing")
	func alreadySubscribedIsANoOp() {
		let existing = doc("a.b.c", bundleID: "a.b.c", chats: [1, 2])
		let plan = SubscriptionPlanner.subscribe(result("a.b.c"), chatID: 2, existing: [existing])

		#expect(plan.alreadySubscribed)
		#expect(plan.insert == nil)
		#expect(plan.update == nil)
		#expect(plan.deletions.isEmpty)
	}

	/// Two documents for one bundle ID hide subscribers: only the first is ever found, so
	/// `/del` misses the rest while the watcher notifies everybody twice. Any write is an
	/// opportunity to heal that.
	@Test("Duplicate documents are consolidated into one")
	func consolidatesDuplicates() throws {
		let first = doc("uuid-1", bundleID: "a.b.c", chats: [1, 2])
		let second = doc("uuid-2", bundleID: "a.b.c", chats: [3])
		let third = doc("uuid-3", bundleID: "a.b.c", chats: [4])

		let plan = SubscriptionPlanner.subscribe(
			result("a.b.c"),
			chatID: 5,
			existing: [first, second, third]
		)
		let update = try #require(plan.update)

		#expect(update._id == "uuid-1")
		#expect(update.chats == [1, 2, 3, 4, 5])
		#expect(plan.deletions.map(\._id) == ["uuid-2", "uuid-3"])
		#expect(plan.insert == nil)
	}

	@Test("Duplicates are consolidated even when the chat is already subscribed")
	func consolidatesRegardlessOfMembership() throws {
		let first = doc("uuid-1", bundleID: "a.b.c", chats: [1])
		let second = doc("uuid-2", bundleID: "a.b.c", chats: [2])

		let plan = SubscriptionPlanner.subscribe(result("a.b.c"), chatID: 1, existing: [first, second])

		#expect(try #require(plan.update).chats == [1, 2])
		#expect(plan.deletions.map(\._id) == ["uuid-2"])
		#expect(!plan.alreadySubscribed)
	}
}

@Suite("Unsubscribe planning")
struct UnsubscribePlannerTests {
	private func doc(_ id: String, chats: Set<Int64>) -> Subscription {
		Subscription(
			_id: id,
			_rev: "1-abc",
			bundleID: "a.b.c",
			url: "https://example.com",
			title: "MyApp",
			version: ["1.0"],
			chats: chats
		)
	}

	@Test("Removing one of several chats updates the document")
	func removesChat() throws {
		let plan = SubscriptionPlanner.unsubscribe(chatID: 2, from: [doc("a.b.c", chats: [1, 2])])

		#expect(try #require(plan.updates.first).chats == [1])
		#expect(plan.deletions.isEmpty)
		#expect(plan.removedFrom?.title == "MyApp")
	}

	@Test("Removing the last chat deletes the document")
	func deletesWhenLastChatLeaves() {
		let plan = SubscriptionPlanner.unsubscribe(chatID: 1, from: [doc("a.b.c", chats: [1])])

		#expect(plan.updates.isEmpty)
		#expect(plan.deletions.map(\._id) == ["a.b.c"])
		#expect(plan.removedFrom != nil)
	}

	/// The bot used to tell a user their subscription "has been removed" whenever the app
	/// existed, even if that user was never subscribed to it.
	@Test("A chat that was never subscribed reports nothing removed")
	func reportsNothingForAStranger() {
		let plan = SubscriptionPlanner.unsubscribe(chatID: 99, from: [doc("a.b.c", chats: [1, 2])])

		#expect(plan.removedFrom == nil)
		#expect(plan.updates.isEmpty)
		#expect(plan.deletions.isEmpty)
	}

	@Test("An app with no stored documents reports nothing removed")
	func reportsNothingForMissingApp() {
		let plan = SubscriptionPlanner.unsubscribe(chatID: 1, from: [])

		#expect(plan.removedFrom == nil)
		#expect(plan.updates.isEmpty)
		#expect(plan.deletions.isEmpty)
	}

	/// With duplicates present, removing the chat from only the first document leaves the
	/// user subscribed via the other one — they keep getting notifications after `/del`.
	@Test("The chat is removed from every duplicate document")
	func removesFromAllDuplicates() {
		let plan = SubscriptionPlanner.unsubscribe(
			chatID: 1,
			from: [doc("uuid-1", chats: [1, 2]), doc("uuid-2", chats: [1])]
		)

		#expect(plan.updates.map(\._id) == ["uuid-1"])
		#expect(plan.deletions.map(\._id) == ["uuid-2"])
	}
}

@Suite("CouchDB error mapping")
struct StoreErrorMappingTests {
	/// `CouchDBError` has no public initialiser, so it is built the way the library builds it.
	private func couchError(_ error: String, reason: String = "Document update conflict.") throws -> CouchDBError {
		let json = "{\"error\":\"\(error)\",\"reason\":\"\(reason)\"}"
		return try JSONDecoder().decode(CouchDBError.self, from: Data(json.utf8))
	}

	/// A conflict is the signal that another task wrote first, and the right answer is to
	/// re-read and merge. The library reports it as an operation-specific case, so every one
	/// of them has to map.
	@Test("A conflict is recognised whichever operation reported it")
	func mapsConflicts() throws {
		let conflict = try couchError("conflict")

		#expect(StoreError(.conflictError(error: conflict)) == .conflict)
		#expect(StoreError(.insertError(error: conflict)) == .conflict)
		#expect(StoreError(.updateError(error: conflict)) == .conflict)
		#expect(StoreError(.deleteError(error: conflict)) == .conflict)
	}

	@Test("A missing document maps to notFound")
	func mapsNotFound() throws {
		#expect(StoreError(.notFound(error: try couchError("not_found", reason: "missing"))) == .notFound)
		#expect(StoreError(.getError(error: try couchError("not_found", reason: "missing"))) == .notFound)
	}

	@Test("Bad credentials map to unauthorized")
	func mapsUnauthorized() throws {
		#expect(StoreError(.unauthorized) == .unauthorized)
		#expect(StoreError(.getError(error: try couchError("unauthorized", reason: "nope"))) == .unauthorized)
	}

	@Test("Anything else is an unexpected response rather than a conflict")
	func mapsEverythingElse() throws {
		#expect(StoreError(.unknownResponse) == .unexpectedResponse)
		#expect(StoreError(.noData) == .unexpectedResponse)
		#expect(StoreError(.idMissing) == .unexpectedResponse)
		#expect(StoreError(.getError(error: try couchError("badarg", reason: "bad"))) == .unexpectedResponse)
	}
}

@Suite("Delete failure mapping")
struct DeleteFailureMappingTests {
	private func couchError(_ error: String) throws -> CouchDBError {
		let json = "{\"error\":\"\(error)\",\"reason\":\"whatever\"}"
		return try JSONDecoder().decode(CouchDBError.self, from: Data(json.utf8))
	}

	/// `couchdb-swift` handles only 404 on delete; a 409 body reaches `JSONDecoder` and fails
	/// there, so without translating a decoding failure the retry loop never sees a delete
	/// conflict — the write where consolidating duplicates needs it most.
	@Test("A decoding failure from a delete is treated as a conflict")
	func decodingFailureIsAConflict() {
		// Exactly what the library produces: CouchDB's conflict body decoded as though it were
		// a `CouchUpdateResponse`.
		let conflictBody = Data(#"{"error":"conflict","reason":"Document update conflict."}"#.utf8)
		do {
			_ = try JSONDecoder().decode(CouchUpdateResponse.self, from: conflictBody)
			Issue.record("Expected the conflict body to fail decoding")
		} catch {
			#expect(error is DecodingError)
			#expect(CouchDBDocumentStore.storeError(fromDeleteFailure: error) == .conflict)
		}
	}

	@Test("A reported conflict stays a conflict")
	func reportedConflictPassesThrough() throws {
		let error = CouchDBClientError.deleteError(error: try couchError("conflict"))
		#expect(CouchDBDocumentStore.storeError(fromDeleteFailure: error) == .conflict)
	}

	@Test("A missing document is not mistaken for a conflict")
	func notFoundIsPreserved() throws {
		let error = CouchDBClientError.deleteError(error: try couchError("not_found"))
		#expect(CouchDBDocumentStore.storeError(fromDeleteFailure: error) == .notFound)
	}

	/// The library returns `CouchUpdateResponse(ok: false, ...)` for an empty body instead of
	/// throwing, so discarding the result would read a failed delete as a success.
	@Test("A delete that did not report success is an error")
	func unsuccessfulDeleteIsAnError() throws {
		let refused = try JSONDecoder().decode(
			CouchUpdateResponse.self,
			from: Data(#"{"ok":false,"id":"","rev":""}"#.utf8)
		)
		#expect(throws: StoreError.unexpectedResponse) {
			try CouchDBDocumentStore.verify(refused)
		}
	}

	@Test("A successful delete passes")
	func successfulDeletePasses() throws {
		let accepted = try JSONDecoder().decode(
			CouchUpdateResponse.self,
			from: Data(#"{"ok":true,"id":"a.b.c","rev":"2-x"}"#.utf8)
		)
		#expect(throws: Never.self) { try CouchDBDocumentStore.verify(accepted) }
	}

	@Test("An unrecognised failure is not silently retried forever")
	func unknownFailureIsNotAConflict() {
		struct Odd: Error {}
		#expect(CouchDBDocumentStore.storeError(fromDeleteFailure: Odd()) == .unexpectedResponse)
	}
}

@Suite("View query construction")
struct ViewQueryTests {
	/// CouchDB answers `400 bad_request` for a string key that is not a JSON literal, so the
	/// quoting is part of the contract — asserted here rather than re-implemented in a fake.
	@Test("A string key is sent as a JSON string")
	func quotesStringKeys() {
		#expect(ViewQuery.rows(matching: .string("com.my.app")) == [
			URLQueryItem(name: "key", value: "\"com.my.app\"")
		])
	}

	@Test("A numeric key is sent unquoted")
	func leavesNumbersUnquoted() {
		#expect(ViewQuery.rows(matching: .number(-1001234567890)) == [
			URLQueryItem(name: "key", value: "-1001234567890")
		])
	}

	@Test("A key containing quotes or backslashes is escaped, not concatenated")
	func escapesAwkwardKeys() {
		#expect(ViewKey.string("a\"b").jsonLiteral == "\"a\\\"b\"")
		#expect(ViewKey.string("a\\b").jsonLiteral == "\"a\\\\b\"")
	}

	@Test("A page asks for one row beyond itself, to learn where the next one starts")
	func pageAsksForOneExtraRow() {
		#expect(ViewQuery.page(size: 100) == [URLQueryItem(name: "limit", value: "101")])
	}

	/// `startkey` alone is not enough: `by_bundle` allows several documents per key, so
	/// without `startkey_docid` a page boundary inside a run of duplicates never advances.
	@Test("A continued page carries both the key and the document id")
	func continuedPageCarriesDocumentID() {
		let cursor = ViewCursor(key: .string("com.my.app"), documentID: "doc-7")
		#expect(ViewQuery.page(size: 100, after: cursor) == [
			URLQueryItem(name: "limit", value: "101"),
			URLQueryItem(name: "startkey", value: "\"com.my.app\""),
			URLQueryItem(name: "startkey_docid", value: "doc-7")
		])
	}
}

@Suite("Document id safety")
struct DocumentIDTests {
	/// The library interpolates the id straight into the document URL path with no escaping.
	@Test("Ordinary bundle IDs are usable", arguments: [
		"com.my.app", "org.videolan.vlc-ios", "a", "com.Example.App123"
	])
	func acceptsRealBundleIDs(bundleID: String) {
		#expect(SubscriptionPlanner.isUsableAsDocumentID(bundleID))
	}

	@Test("Anything that could address a different endpoint is rejected", arguments: [
		"", "_design/list", "../_users/admin", "a/b", "a b", "a?b", "a#b", "a%2Fb", "app\u{0}"
	])
	func rejectsDangerousIDs(bundleID: String) {
		#expect(!SubscriptionPlanner.isUsableAsDocumentID(bundleID))
	}

	@Test("An absurdly long id is rejected")
	func rejectsLongIDs() {
		#expect(!SubscriptionPlanner.isUsableAsDocumentID(String(repeating: "a", count: 201)))
	}

	@Test("A bundle ID that cannot be an id still yields a usable document")
	func fallsBackToAGeneratedID() throws {
		let result = SearchResult(
			title: "Odd",
			bundleID: "../_users/admin",
			url: "https://example.com",
			version: "1.0"
		)
		let plan = SubscriptionPlanner.subscribe(result, chatID: 1, existing: [])
		let insert = try #require(plan.insert)

		#expect(insert._id != "../_users/admin")
		#expect(SubscriptionPlanner.isUsableAsDocumentID(insert._id))
		#expect(insert.bundleID == "../_users/admin")
	}
}
