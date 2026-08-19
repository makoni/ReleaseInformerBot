//
//  LenientRowsResponse.swift
//  ReleaseInformerBot
//

import Foundation

/// A CouchDB view response that survives documents it cannot read.
///
/// The library's `RowsResponse` decodes all-or-nothing, so a single malformed document broke
/// `getAllSubscriptions`, `search(byChatID:)` and every bundle-ID lookup at once — the watcher
/// would log a decoding error every sweep and check nothing at all. Skipping the bad row
/// costs one subscription; failing the batch costs all of them.
struct LenientRowsResponse<Value: Decodable>: Decodable {
	struct Row: Decodable {
		let id: String?
		let key: String?
		let value: Value?

		private enum CodingKeys: String, CodingKey {
			case id, key, value
		}

		init(from decoder: any Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			id = try? container.decodeIfPresent(String.self, forKey: .id)
			key = try? container.decodeIfPresent(String.self, forKey: .key)
			// A row whose document will not decode is skipped, not fatal.
			value = try? container.decode(Value.self, forKey: .value)
		}
	}

	let totalRows: Int
	let rows: [Row]

	var values: [Value] { rows.compactMap(\.value) }
	var skippedRowCount: Int { rows.count - values.count }

	private enum CodingKeys: String, CodingKey {
		case total_rows
		case rows
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// `rows` is required: a CouchDB error body has none, and mistaking that for an empty
		// view would look like "every app is gone".
		rows = try container.decode([Row].self, forKey: .rows)
		totalRows = try container.decodeIfPresent(Int.self, forKey: .total_rows) ?? rows.count
	}
}
