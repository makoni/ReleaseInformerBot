//
//  AsyncHttpTGClient.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import Foundation
import Vapor
import SwiftTelegramBot
import Logging
import AsyncHTTPClient

private struct TGEmptyParams: Encodable {}

public final class AsyncHttpTGClient: TGClientPrtcl, @unchecked Sendable {

	public typealias HTTPMediaType = SwiftTelegramBot.HTTPMediaType
	private let log: Logger = .init(label: "AsyncHttpTGClient")
	private let client: HTTPClient

	public init(client: HTTPClient = .shared) {
		self.client = client
	}

	@discardableResult
	public func post<Params: Encodable, Response: Decodable>(
		_ url: URL,
		params: Params? = nil,
		as mediaType: HTTPMediaType? = nil
	) async throws -> Response {
		let request = try makeRequest(url: url, params: params, as: mediaType)
		let clientResponse = try await client.execute(request, timeout: .seconds(30))

		// Collected before the status check on purpose: Telegram puts the reason — and a
		// `retry_after` on a 429 — in the body of the very responses that used to be discarded.
		// `getUpdates` can also return more than the old 1 MB allowed for.
		let buffer = try await clientResponse.body.collect(upTo: 10 * 1024 * 1024)

		guard clientResponse.status == .ok else {
			let body = Data(buffer.readableBytesView)
			let reason = TelegramFailure.describe(status: clientResponse.status.code, body: body)
			log.error("\(reason)")

			// The SDK's long-polling loop catches whatever we throw and immediately re-polls
			// with no delay, so a persistent 401 or a 429 would otherwise become an
			// unthrottled request loop writing two error lines per iteration. Waiting here is
			// the only place in this path that can apply back-pressure.
			if let delay = TelegramFailure.backoff(status: clientResponse.status.code, body: body) {
				try? await Task.sleep(for: delay)
			}

			throw BotError(type: .network, reason: reason)
		}

		let telegramContainer: TGTelegramContainer<Response> = try JSONDecoder().decode(TGTelegramContainer<Response>.self, from: buffer)
		return try processContainer(telegramContainer)
	}

	@discardableResult
	public func post<Response: Decodable>(_ url: URL) async throws -> Response {
		try await post(url, params: TGEmptyParams(), as: nil)
	}

	private func makeRequest<Params: Encodable>(
		url: URL,
		params: Params?,
		as mediaType: HTTPMediaType?
	) throws -> HTTPClientRequest {
		var request: HTTPClientRequest = HTTPClientRequest(url: url.absoluteString)
		request.method = .POST

		if mediaType == .formData || mediaType == nil {
			var rawMultipart: (body: NSMutableData, boundary: String)!
			do {
				if let currentParams = params {
					rawMultipart = try currentParams.toMultiPartFormData(log: log)
				} else {
					rawMultipart = try TGEmptyParams().toMultiPartFormData(log: log)
				}
			} catch {
				log.critical("Post request error: \(error.localizedDescription)")
				throw error
			}
			request.headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(rawMultipart.boundary)")
			request.body = .bytes(rawMultipart.body as Data)
		} else {
			request.headers.add(name: "Content-Type", value: "application/json")
			let encoded: any Encodable = params ?? TGEmptyParams()
			let data = try JSONEncoder().encode(encoded)
			request.body = .bytes(data)
		}

		return request
	}

	private func processContainer<T: Decodable>(_ container: TGTelegramContainer<T>) throws -> T {
		guard container.ok else {
			let desc = """
				Response marked as `not Ok`, it seems something wrong with request
				Code: \(container.errorCode ?? -1)
				\(container.description ?? "Empty")
				"""
			let error = BotError(
				type: .server,
				description: desc
			)
			log.error("\(error)")
			throw error
		}

		guard let result = container.result else {
			let error = BotError(
				type: .server,
				reason: "Response marked as `Ok`, but doesn't contain `result` field."
			)
			log.error("\(error)")
			throw error
		}

		let logString = """
			Response:
			Code: \(container.errorCode ?? 0)
			Status OK: \(container.ok)
			Description: \(container.description ?? "Empty")
			"""
		log.trace("\(logString)")
		return result
	}
}
