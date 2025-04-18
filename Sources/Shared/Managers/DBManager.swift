//
//  DBManager.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import Foundation
import CouchDBClient
import Logging


fileprivate let couchDBClient = CouchDBClient(
    config: CouchDBClient.Config(
        userName: "admin"
    )
)

fileprivate let logger = Logger(label: "DBManager")

public actor DBManager {
    public init() {}
    
    private let db = "release_bot"

    public func subscribeForNewVersions(_ result: SearchResult, forChatID chatID: Int64) async throws {
        // update existing
        if var subscription = try await self.searchByBundleID(result.bundleID) {
            if !subscription.chats.contains(chatID) {
                subscription.chats.insert(chatID)
                _ = try await couchDBClient.update(dbName: db, doc: subscription)
            }
            return
        }

        // add new one
        let subscription = Subscription(bundleId: result.bundleID, url: result.url, title: result.title, version: [result.version], chats: [chatID])
        _ = try await couchDBClient.insert(dbName: db, doc: subscription)
        logger.info("\(result.bundleID) has been added to DB")
    }

    func searchByBundleID(_ bundleID: String) async throws -> Subscription? {
        let response = try await couchDBClient.get(
            fromDB: db,
            uri: "_design/list/_view/by_bundle",
            queryItems: [
                URLQueryItem(name: "key", value: "\"\(bundleID)\"")
            ]
        )

        let expectedBytes =
            response.headers
            .first(name: "content-length")
            .flatMap(Int.init) ?? 1024 * 1024 * 10
        var bytes = try await response.body.collect(upTo: expectedBytes)

        guard let data = bytes.readData(length: bytes.readableBytes) else {
            logger.error("Could not read response")
            return nil
        }

        let decoder = JSONDecoder()
        let subscriptions = try decoder.decode(
            RowsResponse<Subscription>.self,
            from: data
        ).rows.map({ $0.value })

        return subscriptions.first
    }

    public func search(byChatID chatID: Int64) async throws -> [Subscription] {
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
