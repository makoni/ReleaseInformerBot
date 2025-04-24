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

public actor SearchManager {
	enum SearchError: Error {
		case noData
	}

	private let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

	enum SearchType {
		case title(title: String)
		case bundleId(bundleId: String)
	}

	public init() {}

	public func search(byTitle title: String) async throws -> [SearchResult] {
		return try await search(byType: .title(title: title))
	}

	public func search(byBundleID bundleID: String) async throws -> [SearchResult] {
		return try await search(byType: .bundleId(bundleId: bundleID))
	}

	private func search(byType searchType: SearchType) async throws -> [SearchResult] {
		var urlBuilder = URLComponents()
		urlBuilder.scheme = "https"
		urlBuilder.host = "itunes.apple.com"

		switch searchType {
		case .title(let title):
			urlBuilder.path = "/search"
			urlBuilder.queryItems = [
				URLQueryItem(name: "term", value: title),
				URLQueryItem(name: "entity", value: "software"),
				URLQueryItem(name: "limit", value: "10")
			]
		case .bundleId(let bundleId):
			urlBuilder.path = "/lookup"
			urlBuilder.queryItems = [
				URLQueryItem(name: "bundleId", value: bundleId),
				URLQueryItem(name: "limit", value: "1")
			]
		}

		guard let url = urlBuilder.url else {
			logger.error("Could not build URL")
			return []
		}

		let request = try buildRequest(fromUrl: url.absoluteString, withMethod: .GET)
		let response =
			try await httpClient
			.execute(request, timeout: .seconds(30))

		let body = response.body
		let expectedBytes = response.headers.first(name: "content-length").flatMap(Int.init)
		var bytes = try await body.collect(upTo: expectedBytes ?? 1024 * 1024 * 10)

		guard let data = bytes.readData(length: bytes.readableBytes) else {
			throw SearchError.noData
		}

		guard var dataString = String(data: data, encoding: .utf8) else {
			return []
		}

		dataString = processJSONString(dataString)

		guard let correctedData = dataString.data(using: .utf8) else {
			return []
		}

		return try JSONDecoder().decode(SearchResultResponse.self, from: correctedData).results
	}

	private func processJSONString(_ input: String) -> String {
		var result = ""
		var inString = false
		var lastChar: Character?

		for char in input {
			if char == "\"" && lastChar != "\\" {
				inString.toggle()
			}

			if inString {
				// Escape control characters within strings
				switch char {
				case "\n": result.append("\\n")
				case "\t": result.append("\\t")
				case "\r": result.append("\\r")
				case "\u{00A0}": result.append(" ")
				default: result.append(char)
				}
			} else {
				// Outside strings, just replace non-breaking spaces
				if char == "\u{00A0}" {
					result.append(" ")
				} else {
					result.append(char)
				}
			}

			lastChar = char
		}

		return result
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
