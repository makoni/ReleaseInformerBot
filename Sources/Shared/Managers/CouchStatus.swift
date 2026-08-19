//
//  CouchStatus.swift
//  ReleaseInformerBot
//

import CouchDBClient
import Foundation

/// Failures reading or writing the subscription store.
public enum StoreError: Error, Equatable, Sendable {
	case notFound
	case unauthorized
	case requestFailed(statusCode: Int)
}

/// Turns a CouchDB HTTP status into a thrown error.
///
/// `couchdb-swift` hands raw responses back to the caller and only throws for `401` and
/// `404`, so a `500`, a `429` or a reverse-proxy error page used to be decoded as if it were
/// a view result. It fails — but as `keyNotFound("total_rows")`, which reads like a model
/// bug rather than the outage it is.
public enum CouchStatus {
	public static func validate(statusCode: Int) throws {
		switch statusCode {
		case 200..<300:
			return
		case 401, 403:
			throw StoreError.unauthorized
		case 404:
			throw StoreError.notFound
		default:
			throw StoreError.requestFailed(statusCode: statusCode)
		}
	}
}

public extension CouchDBClientError {
	/// Whether CouchDB rejected a write because someone else got there first.
	///
	/// This is the signal to re-read and merge rather than to give up: it is how two
	/// concurrent subscribers to the same app are resolved into one document.
	var isDocumentConflict: Bool {
		switch self {
		case .conflictError:
			return true
		case .insertError(let error), .updateError(let error), .deleteError(let error):
			return error.error == "conflict"
		default:
			return false
		}
	}
}
