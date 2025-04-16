//
//  DBManager.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import Foundation
import CouchDBClient
import Logging

fileprivate let couchDBClient = CouchDBClient(config: config)
fileprivate let logger = Logger(label: "DBManager")

actor DBManager {
    private let db = "release_bot"

    func search(byChatID chatID: Int64) async throws -> [Subscription] {
        let response = try await couchDBClient.get(
            fromDB: db,
            uri: "_design/list/_view/by_chat",
            queryItems: [
                URLQueryItem(name: "key", value: "\(chatID)")
            ]
        )

        let expectedBytes =
            response.headers
            .first(name: "content-length")
            .flatMap(Int.init) ?? 1024 * 1024 * 10
        var bytes = try await response.body.collect(upTo: expectedBytes)

        guard let data = bytes.readData(length: bytes.readableBytes) else {
            logger.error("Could not read response")
            return []
        }

        let decoder = JSONDecoder()

        let subscriptions = try decoder.decode(
            RowsResponse<Subscription>.self,
            from: data
        ).rows.map({ $0.value })

        return subscriptions
    }
}
