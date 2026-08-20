//
//  ViewQuery.swift
//  ReleaseInformerBot
//

import Foundation

/// A CouchDB view key.
///
/// `by_bundle` emits strings and `by_chat` emits numbers, and the view API wants both as JSON
/// literals — so the distinction has to survive all the way to the query item.
enum ViewKey: Equatable, Sendable {
	case string(String)
	case number(Int64)

	/// The key as a JSON literal, which is what `key` and `startkey` must carry. CouchDB
	/// answers `400 bad_request` for an unquoted string key.
	var jsonLiteral: String {
		switch self {
		case .string(let value):
			// Encoded rather than wrapped in quotes by hand: a value containing `"` or `\`
			// would otherwise produce malformed JSON. Encoding a single-element array and
			// trimming the brackets avoids relying on top-level fragment support.
			guard
				let data = try? JSONEncoder().encode([value]),
				let array = String(data: data, encoding: .utf8),
				array.count >= 2
			else { return "\"\"" }
			return String(array.dropFirst().dropLast())

		case .number(let value):
			return "\(value)"
		}
	}
}

/// Where a paged view read should resume.
struct ViewCursor: Equatable, Sendable {
	let key: ViewKey
	let documentID: String
}

/// Builds the query items for a view read.
///
/// Query construction lives here so the CouchDB contract is stated once, and so tests can
/// assert the emitted items literally instead of a fake having to re-implement CouchDB's
/// parsing rules and blessing whatever the production code happens to send.
enum ViewQuery {
	/// Every row for one key.
	static func rows(matching key: ViewKey) -> [URLQueryItem] {
		[URLQueryItem(name: "key", value: key.jsonLiteral)]
	}

	/// One page, asking for one row beyond it: if that row arrives, it is where the next page
	/// starts. `startkey_docid` — the document ID, unquoted — is what makes this correct when
	/// several documents share a key, which `by_bundle` allows.
	static func page(size: Int, after cursor: ViewCursor? = nil) -> [URLQueryItem] {
		var items = [URLQueryItem(name: "limit", value: "\(size + 1)")]

		if let cursor {
			items.append(URLQueryItem(name: "startkey", value: cursor.key.jsonLiteral))
			items.append(URLQueryItem(name: "startkey_docid", value: cursor.documentID))
		}

		return items
	}
}
