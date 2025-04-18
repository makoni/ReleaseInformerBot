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
    public enum DBManagerError: Error {
        case chatsNotEmpty
    }

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
        let subscription = Subscription(bundleID: result.bundleID, url: result.url, title: result.title, version: [result.version], chats: [chatID])
        _ = try await couchDBClient.insert(dbName: db, doc: subscription)
        logger.info("\(result.bundleID) has been added to DB")
    }

    public func unsubscribeFromNewVersions(_ bundleID: String, forChatID chatID: Int64) async throws -> Subscription? {
        guard var subscription = try await self.searchByBundleID(bundleID) else { return nil }

        if subscription.chats.contains(chatID) {
            subscription.chats.remove(chatID)

            if !subscription.chats.isEmpty {
                subscription = try await couchDBClient.update(dbName: db, doc: subscription)
            } else {
                try await deleteSubscription(subscription)
            }
        }

        return subscription
    }

    public func deleteSubscription(_ subscription: Subscription) async throws {
        guard subscription.chats.isEmpty else {
            throw DBManagerError.chatsNotEmpty
        }
        _ = try await couchDBClient.delete(fromDb: db, doc: subscription)
    }

    private func searchByBundleID(_ bundleID: String) async throws -> Subscription? {
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

// MARK: - Watcher methods
extension DBManager {
    public func getAllSubscriptions() async throws -> [Subscription] {
        let response = try await couchDBClient.get(
            fromDB: db,
            uri: "_design/list/_view/by_bundle"
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
        let decoded = try decoder.decode(
            RowsResponse<Subscription>.self,
            from: data
        )

        return decoded.rows.map({ $0.value })
    }
}
