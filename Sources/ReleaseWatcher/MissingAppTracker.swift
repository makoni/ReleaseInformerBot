//
//  MissingAppTracker.swift
//  ReleaseInformerBot
//

import Foundation

/// Counts how many consecutive successful lookups an app has been absent from.
///
/// Deleting a subscription is irreversible for everyone subscribed to it, and an app can drop
/// out of a lookup response for reasons that have nothing to do with being pulled from the
/// store — a storefront hiccup, or temporary regional unavailability. Requiring several
/// consecutive misses keeps a transient blip from silently unsubscribing users.
///
/// The state is deliberately in-memory only: losing it on restart merely delays a deletion,
/// which is the safe direction to fail in.
struct MissingAppTracker {
	let threshold: Int
	private var strikes = [String: Int]()

	init(threshold: Int) {
		self.threshold = max(1, threshold)
	}

	/// Records one successful lookup batch and returns the bundle IDs that have now been
	/// absent often enough to act on.
	///
	/// Strikes are *not* cleared for the IDs it returns — the caller clears them with
	/// ``forget(_:)`` once the deletion has actually succeeded. Clearing here would restart
	/// the countdown every time a delete failed.
	mutating func record(missing: [String], present: [String]) -> [String] {
		for bundleID in present {
			strikes[bundleID] = nil
		}

		var exhausted = [String]()
		for bundleID in missing {
			let count = (strikes[bundleID] ?? 0) + 1
			strikes[bundleID] = count

			if count >= threshold {
				exhausted.append(bundleID)
			}
		}

		return exhausted
	}

	/// Drops the record for an app that has been dealt with.
	mutating func forget(_ bundleID: String) {
		strikes[bundleID] = nil
	}

	/// Consecutive misses recorded so far. Exposed for tests and logging.
	func strikeCount(for bundleID: String) -> Int {
		strikes[bundleID] ?? 0
	}
}
