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

actor SearchManager {
    enum SearchError: Error {
        case noData
    }

    private let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

    enum SearchType {
        case title(title: String)
        case bundleId(bundleId: String)
    }

    func search(byTitle title: String) async throws -> [SearchResult] {
        return try await search(byType: .title(title: title))
    }

    func search(byBundleID bundleID: String) async throws -> [SearchResult] {
        return try await search(byType: .bundleId(bundleId: bundleID))
    }

    private func search(byType searchType: SearchType) async throws -> [SearchResult] {
        // const searchString = 'https://itunes.apple.com/search?term=' + encodeURI(searchText.trim()) + '&entity=software';
        var urlBuilder = URLComponents()
        urlBuilder.scheme = "https"
        urlBuilder.host = "itunes.apple.com"
        urlBuilder.path = "/search"

        switch searchType {
            case .title(title: let title):
            urlBuilder.queryItems = [
                URLQueryItem(name: "term", value: title),
                URLQueryItem(name: "entity", value: "software"),
            ]
        case .bundleId(bundleId: let bundleId):
            urlBuilder.queryItems = [
                URLQueryItem(name: "bundleId", value: bundleId)
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
        return try JSONDecoder().decode(SearchResultResponse.self, from: data).results
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
