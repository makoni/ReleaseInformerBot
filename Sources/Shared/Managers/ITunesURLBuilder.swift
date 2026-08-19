//
//  ITunesURLBuilder.swift
//  ReleaseInformerBot
//

import Foundation

/// A single request against the iTunes Search API.
enum ITunesLookupQuery: Sendable {
	/// A free-text search, used by the `/search` bot command.
	case title(String)
	/// A batched version lookup for one or more bundle IDs.
	case bundleIDs([String])
}

/// Builds URLs for the iTunes Search API.
enum ITunesURLBuilder {
	/// The lookup endpoint accepts comma-separated IDs; 100 per request is verified to
	/// return all 100 results in a single response.
	static let batchSize = 100

	/// Name of the cache-busting query parameter. The API ignores unknown parameters,
	/// but Akamai keys its cache on the full URL.
	static let cacheBusterKey = "_"

	/// Responses from `itunes.apple.com` are served through Akamai with
	/// `cache-control: max-age=86400`, and repeat requests for the same URL are answered
	/// from that cache without revalidating — the remaining TTL simply counts down. A bot
	/// polling a fixed URL therefore sees a snapshot that can be a full day old.
	///
	/// Giving every request a unique cache key forces a trip to the origin, which does
	/// reflect new releases within minutes.
	static func makeCacheBuster() -> String {
		UUID().uuidString
	}

	static func url(for query: ITunesLookupQuery, cacheBuster: String) -> URL? {
		var builder = URLComponents()
		builder.scheme = "https"
		builder.host = "itunes.apple.com"

		switch query {
		case .title(let title):
			builder.path = "/search"
			builder.queryItems = [
				URLQueryItem(name: "term", value: title),
				URLQueryItem(name: "entity", value: "software"),
				URLQueryItem(name: "limit", value: "10")
			]
			// Deliberately not cache-busted. Apple asks callers to cache search results,
			// stale ones are harmless, and origin trips here come out of the same rate
			// budget the watcher needs.

		case .bundleIDs(let bundleIDs):
			// Duplicates would be wasted work, and two subscription documents for one
			// bundle ID is a state the database does not prevent.
			let uniqueIDs = NSOrderedSet(array: bundleIDs).array as? [String] ?? bundleIDs
			guard !uniqueIDs.isEmpty else { return nil }

			builder.path = "/lookup"
			builder.queryItems = [
				URLQueryItem(name: "bundleId", value: uniqueIDs.joined(separator: ","))
			]
			// No `limit`: a universal-purchase app can answer with more than one entry, and
			// a limit equal to the ID count would then truncate the tail of the batch —
			// making real apps look absent, which is what drives deletion.

			builder.queryItems?.append(URLQueryItem(name: cacheBusterKey, value: cacheBuster))
		}

		return builder.url
	}
}
