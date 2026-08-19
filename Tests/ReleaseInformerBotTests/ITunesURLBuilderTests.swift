//
//  ITunesURLBuilderTests.swift
//  ReleaseInformerBot
//

import Foundation
import Testing

@testable import Shared

@Suite("iTunes URL building")
struct ITunesURLBuilderTests {
	private func components(_ url: URL?) throws -> URLComponents {
		let url = try #require(url)
		return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
	}

	/// Deliberately not a dictionary: collapsing duplicates would hide a builder that
	/// appends a parameter twice, which is exactly how a URL silently goes wrong.
	private func values(_ url: URL?, _ name: String) throws -> [String] {
		try components(url).queryItems?.filter { $0.name == name }.map { $0.value ?? "" } ?? []
	}

	@Test("Lookup URL points at the iTunes lookup endpoint")
	func lookupEndpoint() throws {
		let url = try #require(ITunesURLBuilder.url(for: .bundleIDs(["org.videolan.vlc-ios"]), cacheBuster: "1"))
		#expect(url.scheme == "https")
		#expect(url.host == "itunes.apple.com")
		#expect(url.path == "/lookup")
	}

	@Test("A lookup carries exactly one cache-busting parameter")
	func lookupCarriesOneCacheBuster() throws {
		let url = ITunesURLBuilder.url(for: .bundleIDs(["a.b.c"]), cacheBuster: "1730000000")
		#expect(try values(url, ITunesURLBuilder.cacheBusterKey) == ["1730000000"])
	}

	@Test("Distinct cache busters produce distinct URLs")
	func cacheBusterVariesTheURL() {
		let first = ITunesURLBuilder.url(for: .bundleIDs(["a.b.c"]), cacheBuster: "1")
		let second = ITunesURLBuilder.url(for: .bundleIDs(["a.b.c"]), cacheBuster: "2")
		#expect(first != second)
	}

	@Test("A generated cache buster is not reused between calls")
	func generatedCacheBusterIsUnique() {
		let busters = (0..<50).map { _ in ITunesURLBuilder.makeCacheBuster() }
		#expect(Set(busters).count == busters.count)
	}

	/// The regression that matters. The 24-hour Akamai cache is keyed on the whole URL, so
	/// the fix is only real if *every* request gets a fresh key. Caching the buster in a
	/// stored property would leave every assertion above green while restoring the bug.
	@Test("Two lookups for the same app produce two different URLs")
	func repeatedLookupsAreNeverTheSameURL() throws {
		let query = ITunesLookupQuery.bundleIDs(["org.videolan.vlc-ios"])
		let first = try SearchManager.requestURL(for: query)
		let second = try SearchManager.requestURL(for: query)

		#expect(first != second)
		// And they differ *only* in the cache buster, not in what is being asked for.
		#expect(try values(first, "bundleId") == values(second, "bundleId"))
	}

	@Test("Several bundle IDs are sent as one comma-separated batch")
	func batchesBundleIDs() throws {
		let ids = ["one.app", "two.app", "three.app"]
		let url = ITunesURLBuilder.url(for: .bundleIDs(ids), cacheBuster: "1")
		#expect(try values(url, "bundleId") == ["one.app,two.app,three.app"])
	}

	/// A limit equal to the ID count truncates the response when any app answers with more
	/// than one entry, which makes the tail of the batch look absent — and absent apps get
	/// their subscriptions deleted.
	@Test("A lookup sends no limit, so the response cannot be truncated")
	func lookupSendsNoLimit() throws {
		let ids = (0..<40).map { "app.number.\($0)" }
		#expect(try values(ITunesURLBuilder.url(for: .bundleIDs(ids), cacheBuster: "1"), "limit").isEmpty)
	}

	@Test("Duplicate bundle IDs are collapsed, keeping the original order")
	func deduplicatesBundleIDs() throws {
		let url = ITunesURLBuilder.url(for: .bundleIDs(["b.app", "a.app", "b.app"]), cacheBuster: "1")
		#expect(try values(url, "bundleId") == ["b.app,a.app"])
	}

	@Test("An empty batch produces no URL")
	func emptyBatchHasNoURL() {
		#expect(ITunesURLBuilder.url(for: .bundleIDs([]), cacheBuster: "1") == nil)
	}

	@Test("Title search keeps the documented search parameters")
	func titleSearch() throws {
		let url = try #require(ITunesURLBuilder.url(for: .title("vlc"), cacheBuster: "42"))
		#expect(url.path == "/search")
		#expect(try values(url, "term") == ["vlc"])
		#expect(try values(url, "entity") == ["software"])
		#expect(try values(url, "limit") == ["10"])
	}

	/// Apple asks callers to cache search results, stale ones are harmless, and origin trips
	/// here would come out of the same rate budget the watcher needs.
	@Test("Title search is not cache-busted")
	func titleSearchIsCacheable() throws {
		let url = ITunesURLBuilder.url(for: .title("vlc"), cacheBuster: "42")
		#expect(try values(url, ITunesURLBuilder.cacheBusterKey).isEmpty)
	}
}

@Suite("Chunking")
struct ChunkingTests {
	@Test("A list is split into runs of the requested size, in order")
	func chunksInOrder() {
		let ids = (0..<250).map { "app.\($0)" }
		let chunks = ids.chunked(into: 100)

		#expect(chunks.map(\.count) == [100, 100, 50])
		#expect(chunks.flatMap { $0 } == ids)
	}

	@Test("A list that fits exactly is one chunk, with no empty tail")
	func exactMultipleHasNoEmptyChunk() {
		let hundred: [String] = (0..<100).map { "app.\($0)" }
		let twoHundred: [String] = (0..<200).map { "app.\($0)" }

		#expect(hundred.chunked(into: 100).count == 1)
		#expect(twoHundred.chunked(into: 100).map(\.count) == [100, 100])
	}

	@Test("One element over the boundary starts a second chunk")
	func justOverTheBoundary() {
		let ids: [String] = (0..<101).map { "app.\($0)" }
		#expect(ids.chunked(into: 100).map(\.count) == [100, 1])
	}

	@Test("Chunking an empty list yields no chunks")
	func chunkingEmpty() {
		#expect([String]().chunked(into: 100).isEmpty)
	}

	@Test("A non-positive size yields a single chunk rather than looping forever")
	func nonPositiveSize() {
		#expect(["a", "b"].chunked(into: 0) == [["a", "b"]])
		#expect([String]().chunked(into: 0).isEmpty)
	}
}
