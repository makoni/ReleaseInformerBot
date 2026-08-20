//
//  StoreError.swift
//  ReleaseInformerBot
//

import CouchDBClient
import Foundation

/// Failures reading or writing the subscription store.
///
/// One vocabulary on purpose. The store adapter translates `couchdb-swift`'s errors into these
/// so nothing above it has to know which of the library's several shapes a conflict arrived in
/// — the previous arrangement had reads reporting `StoreError` while writes leaked
/// `CouchDBClientError`, and a conflict could arrive as either.
public enum StoreError: Error, Equatable, Sendable {
	case notFound
	case unauthorized
	/// Someone else wrote the document first. The caller should re-read and merge.
	case conflict
	/// The server answered in a way the client cannot interpret.
	case unexpectedResponse
	case requestFailed(statusCode: Int)
}

extension StoreError {
	/// Translates a `couchdb-swift` error.
	init(_ error: CouchDBClientError) {
		switch error {
		case .conflictError:
			self = .conflict

		case .insertError(let couch), .updateError(let couch), .deleteError(let couch),
			.getError(let couch), .findError(let couch):
			// The library reports a 409 as an operation-specific case carrying CouchDB's own
			// error string, so the string is the only reliable discriminator.
			switch couch.error {
			case "conflict": self = .conflict
			case "not_found": self = .notFound
			case "unauthorized", "forbidden": self = .unauthorized
			default: self = .unexpectedResponse
			}

		case .notFound:
			self = .notFound

		case .unauthorized:
			self = .unauthorized

		case .idMissing, .revMissing, .noData, .unknownResponse:
			self = .unexpectedResponse
		}
	}
}

/// Turns a CouchDB HTTP status into a thrown error.
///
/// `couchdb-swift` hands raw view responses back to the caller, so without this a `500` or a
/// reverse-proxy error page reaches the decoder. It does fail — but as
/// `keyNotFound("total_rows")`, which reads like a model bug rather than the outage it is, and
/// an error body must never be mistaken for an empty view: "no rows" is what drives deletion.
enum CouchStatus {
	static func validate(statusCode: Int) throws {
		switch statusCode {
		case 200..<300:
			return
		case 401, 403:
			throw StoreError.unauthorized
		case 404:
			throw StoreError.notFound
		case 409:
			throw StoreError.conflict
		default:
			throw StoreError.requestFailed(statusCode: statusCode)
		}
	}
}
