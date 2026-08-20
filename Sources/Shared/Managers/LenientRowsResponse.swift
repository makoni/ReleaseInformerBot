//
//  LenientRowsResponse.swift
//  ReleaseInformerBot
//

import Foundation

/// A CouchDB view response that survives documents it cannot read.
///
/// The library's `RowsResponse` decodes all-or-nothing, so a single malformed document broke
/// `getAllSubscriptions`, `search(byChatID:)` and every bundle-ID lookup at once — the watcher
/// would log a decoding error every sweep and check nothing at all. Skipping the bad row costs
/// one subscription; failing the response costs all of them.
struct LenientRowsResponse<Value: Decodable>: Decodable {
	struct Row: Decodable {
		let id: String?
		let key: ViewKey?
		let value: Value?

		private enum CodingKeys: String, CodingKey {
			case id, key, value
		}

		init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			id = try? container.decodeIfPresent(String.self, forKey: .id)

			// `by_bundle` emits a string key, `by_chat` a number. Keeping both means a paged
			// read of either view can build a correct `startkey`.
			if let text = try? container.decode(String.self, forKey: .key) {
				key = .string(text)
			} else if let number = try? container.decode(Int64.self, forKey: .key) {
				key = .number(number)
			} else {
				key = nil
			}

			value = try? container.decode(Value.self, forKey: .value)
		}

		/// Where a read would resume after this row, when the row carries enough to say.
		var cursor: ViewCursor? {
			guard let key, let id else { return nil }
			return ViewCursor(key: key, documentID: id)
		}
	}

	let totalRows: Int
	let rows: [Row]

	var values: [Value] { rows.compactMap(\.value) }

	/// Identifiers of the rows that could not be read, so an operator can go and find them.
	/// A bare count leaves the bad document unfindable and therefore skipped forever.
	var skippedRowIDs: [String] { rows.filter { $0.value == nil }.map { $0.id ?? "<no id>" } }

	private enum CodingKeys: String, CodingKey {
		case totalRows = "total_rows"
		case rows
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// `rows` is required: a CouchDB error body has none, and mistaking that for an empty
		// view would look like "every app is gone".
		rows = try container.decode([Row].self, forKey: .rows)
		totalRows = try container.decodeIfPresent(Int.self, forKey: .totalRows) ?? rows.count
	}
}
