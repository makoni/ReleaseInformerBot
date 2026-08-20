//
//  ReleaseDiff.swift
//  ReleaseInformerBot
//

import Foundation
import Shared

/// A subscription whose app has published a version the subscribers have not been told about.
struct VersionUpdate: Sendable {
	/// The stored subscription, with title and URL refreshed from the lookup result.
	let subscription: Subscription
	let result: SearchResult
}

/// Compares stored subscriptions against a batch of lookup results.
enum ReleaseDiff {
	static func updates(for subscriptions: [Subscription], results: [SearchResult]) -> [VersionUpdate] {
		let resultsByBundleID = index(results)

		return subscriptions.compactMap { subscription in
			guard let result = resultsByBundleID[subscription.bundleID] else { return nil }
			guard !subscription.version.contains(result.version) else { return nil }

			// Apps get renamed and move between storefronts; keep the stored copy current.
			var refreshed = subscription
			refreshed.title = result.title
			refreshed.url = result.url

			return VersionUpdate(subscription: refreshed, result: result)
		}
	}

	/// Subscriptions the lookup did not return. Only meaningful for a response that
	/// actually succeeded — a failed request tells us nothing about whether an app exists.
	static func missing(in subscriptions: [Subscription], results: [SearchResult]) -> [Subscription] {
		let found = Set(results.map(\.bundleID))
		return subscriptions.filter { !found.contains($0.bundleID) }
	}

	/// Picks one result per bundle ID.
	///
	/// A universal-purchase app answers with an entry per platform, and Apple's ordering is
	/// not contractual — so taking whatever came first would let the announced version flip
	/// between the iOS and macOS builds on every sweep. The iOS entry wins.
	private static func index(_ results: [SearchResult]) -> [String: SearchResult] {
		var byBundleID = [String: SearchResult]()

		for result in results {
			guard let existing = byBundleID[result.bundleID] else {
				byBundleID[result.bundleID] = result
				continue
			}
			if !existing.isiOSApp && result.isiOSApp {
				byBundleID[result.bundleID] = result
			}
		}

		return byBundleID
	}
}
