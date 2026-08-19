//
//  ReleaseDiffTests.swift
//  ReleaseInformerBot
//

import Foundation
import Testing

@testable import ReleaseWatcher
@testable import Shared

@Suite("Release diffing")
struct ReleaseDiffTests {
	private func subscription(
		_ bundleID: String,
		versions: [String],
		title: String = "Old Title",
		url: String = "https://old.example",
		chats: Set<Int64> = [1]
	) -> Subscription {
		Subscription(bundleID: bundleID, url: url, title: title, version: versions, chats: chats)
	}

	private func result(
		_ bundleID: String,
		version: String,
		title: String = "New Title",
		url: String = "https://new.example",
		releaseNotes: String? = nil,
		kind: String? = nil
	) -> SearchResult {
		SearchResult(
			title: title,
			bundleID: bundleID,
			url: url,
			version: version,
			releaseNotes: releaseNotes,
			kind: kind
		)
	}

	@Test("A version the subscription has never seen is reported as an update")
	func detectsNewVersion() {
		let subs = [subscription("a.b.c", versions: ["1.0"])]
		let updates = ReleaseDiff.updates(for: subs, results: [result("a.b.c", version: "2.0")])

		#expect(updates.count == 1)
		#expect(updates.first?.result.version == "2.0")
		#expect(updates.first?.subscription.bundleID == "a.b.c")
	}

	@Test("An already-known version produces no update")
	func ignoresKnownVersion() {
		let subs = [subscription("a.b.c", versions: ["1.0", "2.0"])]
		let updates = ReleaseDiff.updates(for: subs, results: [result("a.b.c", version: "2.0")])
		#expect(updates.isEmpty)
	}

	@Test("A subscription with no recorded versions is treated as an update")
	func emptyVersionHistoryIsAnUpdate() {
		let subs = [subscription("a.b.c", versions: [])]
		let updates = ReleaseDiff.updates(for: subs, results: [result("a.b.c", version: "1.0")])
		#expect(updates.count == 1)
	}

	@Test("A rollback to a version still in the recorded history is not re-announced")
	func rollbackWithinHistoryIsSilent() {
		let subs = [subscription("a.b.c", versions: ["1.0", "2.0"])]
		#expect(ReleaseDiff.updates(for: subs, results: [result("a.b.c", version: "1.0")]).isEmpty)
	}

	@Test("Title and URL are refreshed from the lookup result")
	func refreshesMetadata() throws {
		let subs = [subscription("a.b.c", versions: ["1.0"], title: "Old", url: "https://old")]
		let updates = ReleaseDiff.updates(
			for: subs,
			results: [result("a.b.c", version: "2.0", title: "Renamed", url: "https://new")]
		)

		let update = try #require(updates.first)
		#expect(update.subscription.title == "Renamed")
		#expect(update.subscription.url == "https://new")
		// The identity of the stored document must survive the refresh.
		#expect(update.subscription._id == subs[0]._id)
	}

	@Test("Each subscription is matched to its own result, in subscription order")
	func matchesResultsToSubscriptions() {
		let subs = [
			subscription("a.b.c", versions: ["1.0"]),
			subscription("d.e.f", versions: ["9.9"]),
			subscription("g.h.i", versions: ["3.0"])
		]
		let results = [
			result("d.e.f", version: "9.9"),
			result("g.h.i", version: "4.0"),
			result("a.b.c", version: "2.0")
		]

		#expect(ReleaseDiff.updates(for: subs, results: results).map(\.subscription.bundleID) == ["a.b.c", "g.h.i"])
	}

	@Test("Results for apps nobody subscribed to are ignored")
	func ignoresUnrelatedResults() {
		let subs = [subscription("a.b.c", versions: ["1.0"])]
		let updates = ReleaseDiff.updates(
			for: subs,
			results: [result("a.b.c", version: "1.0"), result("z.z.z", version: "5.0")]
		)
		#expect(updates.isEmpty)
	}

	/// A universal-purchase app answers one bundle ID with an entry per platform. Apple's
	/// ordering is not contractual, so first-wins would let the announced version flip
	/// between the iOS and macOS builds on alternating sweeps.
	@Test("The iOS entry wins when one bundle ID returns several platforms")
	func prefersTheiOSEntry() throws {
		let subs = [subscription("a.b.c", versions: ["1.0"])]

		let macFirst = ReleaseDiff.updates(
			for: subs,
			results: [
				result("a.b.c", version: "9.0", kind: "mac-software"),
				result("a.b.c", version: "2.0", kind: "software")
			]
		)
		let iosFirst = ReleaseDiff.updates(
			for: subs,
			results: [
				result("a.b.c", version: "2.0", kind: "software"),
				result("a.b.c", version: "9.0", kind: "mac-software")
			]
		)

		#expect(macFirst.first?.result.version == "2.0")
		#expect(iosFirst.first?.result.version == "2.0")
	}

	@Test("An entry with no kind is still usable")
	func missingKindIsTreatedAsiOS() {
		let subs = [subscription("a.b.c", versions: ["1.0"])]
		let updates = ReleaseDiff.updates(for: subs, results: [result("a.b.c", version: "2.0", kind: nil)])
		#expect(updates.first?.result.version == "2.0")
	}

	@Test("Subscriptions absent from a successful response are reported as missing")
	func reportsMissingApps() {
		let subs = [
			subscription("a.b.c", versions: ["1.0"]),
			subscription("gone.app", versions: ["1.0"])
		]
		let missing = ReleaseDiff.missing(in: subs, results: [result("a.b.c", version: "1.0")])
		#expect(missing.map(\.bundleID) == ["gone.app"])
	}

	@Test("Nothing is missing when every subscription is present")
	func reportsNoMissingApps() {
		let subs = [subscription("a.b.c", versions: ["1.0"])]
		#expect(ReleaseDiff.missing(in: subs, results: [result("a.b.c", version: "1.0")]).isEmpty)
	}
}

@Suite("iTunes response validation")
struct ITunesResponseValidationTests {
	@Test("A successful status passes validation", arguments: [200, 201, 204])
	func acceptsSuccess(status: Int) {
		#expect(throws: Never.self) {
			try SearchManager.validate(statusCode: status)
		}
	}

	@Test("A rate-limited response is surfaced as an error, not as an empty result")
	func rejectsRateLimit() {
		#expect(throws: SearchManager.SearchError.rateLimited) {
			try SearchManager.validate(statusCode: 403)
		}
	}

	@Test("Other failures keep their status code", arguments: [400, 404, 429, 500, 503])
	func rejectsFailure(status: Int) {
		#expect(throws: SearchManager.SearchError.requestFailed(statusCode: status)) {
			try SearchManager.validate(statusCode: status)
		}
	}

	@Test("Only failures that might pass are worth retrying")
	func classifiesTransience() {
		#expect(SearchManager.SearchError.rateLimited.isTransient)
		#expect(SearchManager.SearchError.requestFailed(statusCode: 503).isTransient)
		// A payload that will not parse now will not parse in a minute either.
		#expect(!SearchManager.SearchError.invalidResponseEncoding.isTransient)
		#expect(!SearchManager.SearchError.invalidURL.isTransient)
	}
}

@Suite("Missing app tracking")
struct MissingAppTrackerTests {
	@Test("A single miss is not enough to delete a subscription")
	func singleMissIsTolerated() {
		var tracker = MissingAppTracker(threshold: 3)
		#expect(tracker.record(missing: ["a.b.c"], present: []).isEmpty)
	}

	@Test("A subscription is reported only after the threshold of consecutive misses")
	func reportsAfterThreshold() {
		var tracker = MissingAppTracker(threshold: 3)
		#expect(tracker.record(missing: ["a.b.c"], present: []).isEmpty)
		#expect(tracker.record(missing: ["a.b.c"], present: []).isEmpty)
		#expect(tracker.record(missing: ["a.b.c"], present: []) == ["a.b.c"])
	}

	@Test("An app that reappears has its strikes cleared")
	func reappearingAppResetsStrikes() {
		var tracker = MissingAppTracker(threshold: 3)
		_ = tracker.record(missing: ["a.b.c"], present: [])
		_ = tracker.record(missing: ["a.b.c"], present: [])
		_ = tracker.record(missing: [], present: ["a.b.c"])

		#expect(tracker.strikeCount(for: "a.b.c") == 0)
		// Back to zero: two more misses must still not be enough.
		#expect(tracker.record(missing: ["a.b.c"], present: []).isEmpty)
		#expect(tracker.record(missing: ["a.b.c"], present: []).isEmpty)
	}

	@Test("Strikes are tracked per app")
	func tracksAppsIndependently() {
		var tracker = MissingAppTracker(threshold: 2)
		_ = tracker.record(missing: ["gone.app"], present: ["live.app"])
		#expect(tracker.record(missing: ["gone.app", "other.app"], present: []) == ["gone.app"])
	}

	/// The caller clears the record only once the delete has actually succeeded — clearing
	/// on report would restart the countdown every time a delete failed.
	@Test("A reported app keeps its strikes until it is explicitly forgotten")
	func keepsStrikesUntilForgotten() {
		var tracker = MissingAppTracker(threshold: 3)
		for _ in 0..<3 { _ = tracker.record(missing: ["a.b.c"], present: []) }
		#expect(tracker.strikeCount(for: "a.b.c") == 3)

		// Still over the threshold, so a failed delete gets another chance next sweep.
		#expect(tracker.record(missing: ["a.b.c"], present: []) == ["a.b.c"])

		tracker.forget("a.b.c")
		#expect(tracker.strikeCount(for: "a.b.c") == 0)
		#expect(tracker.record(missing: ["a.b.c"], present: []).isEmpty)
	}

	@Test("A threshold of one reports immediately")
	func thresholdOfOne() {
		var tracker = MissingAppTracker(threshold: 1)
		#expect(tracker.record(missing: ["a.b.c"], present: []) == ["a.b.c"])
	}

	@Test("A nonsensical threshold is clamped rather than deleting on sight")
	func clampsThreshold() {
		#expect(MissingAppTracker(threshold: 0).threshold == 1)
		#expect(MissingAppTracker(threshold: -5).threshold == 1)
	}

	@Test("Nothing is reported when nothing is missing")
	func nothingMissing() {
		var tracker = MissingAppTracker(threshold: 2)
		#expect(tracker.record(missing: [], present: ["a.b.c", "d.e.f"]).isEmpty)
	}
}
