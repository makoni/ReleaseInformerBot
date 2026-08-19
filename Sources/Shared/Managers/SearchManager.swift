//
//  SearchManager.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import Foundation
import AsyncHTTPClient
import Logging
import NIOHTTP1

fileprivate let logger = Logger(label: "SearchManager")

/// The App Store lookup the release watcher depends on.
///
/// Existing as a protocol is what lets the watcher's delete-and-notify decisions be tested
/// without a network — they are the parts of this project where being wrong costs a user
/// their subscriptions.
public protocol AppVersionLookup: Sendable {
	/// The largest number of bundle IDs served by a single HTTP request.
	///
	/// Callers pace themselves against this, so "one batch per tick" stays one request.
	nonisolated var maxIDsPerRequest: Int { get }

	func search(byBundleIDs bundleIDs: [String]) async throws -> [SearchResult]
}

public actor SearchManager: AppVersionLookup {
	public enum SearchError: Error, Equatable, Sendable {
		case noData
		case invalidResponseEncoding
		case invalidURL
		/// The Search API answered `403`. Apple documents a limit of roughly 20 calls per
		/// minute, and the body is an empty result set — so this must never be mistaken
		/// for "app not found".
		case rateLimited
		case requestFailed(statusCode: Int)

		/// Whether backing off and retrying the same request later is the right response.
		/// A malformed payload will still be malformed in a minute; a 403 will not.
		public var isTransient: Bool {
			switch self {
			// An empty body is a transport/CDN hiccup, so it is worth retrying. A body that
			// will not decode will not decode in a minute either.
			case .rateLimited, .requestFailed, .noData: return true
			case .invalidResponseEncoding, .invalidURL: return false
			}
		}
	}

	private let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

	public nonisolated var maxIDsPerRequest: Int { ITunesURLBuilder.batchSize }

	public init() {}

	public func search(byTitle title: String) async throws -> [SearchResult] {
		return try await search(query: .title(title))
	}

	public func search(byBundleID bundleID: String) async throws -> [SearchResult] {
		return try await search(query: .bundleIDs([bundleID]))
	}

	/// Looks up several apps at once.
	///
	/// One request per app is both slow and a fast route to Apple's rate limit, so IDs are
	/// batched. Anything above ``maxIDsPerRequest`` is split across requests.
	public func search(byBundleIDs bundleIDs: [String]) async throws -> [SearchResult] {
		guard !bundleIDs.isEmpty else { return [] }

		var results = [SearchResult]()
		for batch in bundleIDs.chunked(into: maxIDsPerRequest) {
			results += try await search(query: .bundleIDs(batch))
		}
		return results
	}

	/// Maps an HTTP status onto a thrown error.
	///
	/// Without this, a rate-limited `403` — which Apple answers with an empty `results`
	/// array — is indistinguishable from "this app no longer exists", and the watcher acts
	/// on that difference by deleting subscriptions.
	static func validate(statusCode: Int) throws {
		switch statusCode {
		case 200..<300:
			return
		case 403:
			throw SearchError.rateLimited
		default:
			throw SearchError.requestFailed(statusCode: statusCode)
		}
	}

	/// Builds the URL for one request.
	///
	/// Every call mints a *new* cache buster. That is the fix for the 24-hour Akamai cache,
	/// so it has to happen per request — hoisting the buster into a stored property would
	/// silently restore the original bug.
	nonisolated static func requestURL(for query: ITunesLookupQuery) throws -> URL {
		guard let url = ITunesURLBuilder.url(for: query, cacheBuster: ITunesURLBuilder.makeCacheBuster()) else {
			logger.error("Could not build URL")
			throw SearchError.invalidURL
		}
		return url
	}

	private func search(query: ITunesLookupQuery) async throws -> [SearchResult] {
		let url = try Self.requestURL(for: query)

		let request = try buildRequest(fromUrl: url.absoluteString, withMethod: .GET)
		let response =
			try await httpClient
			.execute(request, timeout: .seconds(30))

		try Self.validate(statusCode: Int(response.status.code))

		let body = response.body
		let expectedBytes = response.headers.first(name: "content-length").flatMap(Int.init)
		let bytes = try await body.collect(upTo: expectedBytes ?? 1024 * 1024 * 10)

		let data = Data(bytes.readableBytesView)

		guard !data.isEmpty else {
			throw SearchError.noData
		}

		guard let dataString = String(data: data, encoding: String.Encoding.utf8) else {
			throw SearchError.invalidResponseEncoding
		}

		let repaired = JSONSanitizer.repairingControlCharacters(in: dataString)

		return try JSONDecoder().decode(SearchResultResponse.self, from: Data(repaired.utf8)).results
	}

	private func buildRequest(fromUrl url: String, withMethod method: HTTPMethod) throws -> HTTPClientRequest {
		var headers = HTTPHeaders()
		headers.add(name: "Content-Type", value: "application/json")

		var request = HTTPClientRequest(url: url)
		request.method = method
		request.headers = headers
		return request
	}
}
