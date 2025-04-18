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
		// Update existing subscription
		if var subscription = try await self.searchByBundleID(result.bundleID) {
			if !subscription.chats.contains(chatID) {
				subscription.chats.insert(chatID)
				_ = try await couchDBClient.update(dbName: db, doc: subscription)
			}
			return
		}

		// Add a new subscription
		let subscription = Subscription(
			bundleID: result.bundleID,
			url: result.url,
			title: result.title,
			version: [result.version],
			chats: [chatID]
		)
		_ = try await couchDBClient.insert(dbName: db, doc: subscription)
		logger.info("Subscription for \(result.bundleID) has been added to the database.")
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
		_ = try await couchDBClient.delete(fromDb: db, doc: subscription)
		logger.info("Subscription for \(subscription.bundleID) has been deleted from the database.")
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
			logger.error("Failed to read response data.")
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
			logger.error("Failed to read response data.")
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
			logger.error("Failed to read response data.")
			return []
		}

		let decoder = JSONDecoder()
		let decoded = try decoder.decode(
			RowsResponse<Subscription>.self,
			from: data
		)

		return decoded.rows.map({ $0.value })
	}

	public func addNewVersion(_ version: String, forSubscription doc: Subscription) async throws {
		var subscription = doc
		subscription.version.append(version)
		while subscription.version.count > 5 {
			subscription.version.removeFirst()
		}

		_ = try await couchDBClient.update(dbName: db, doc: subscription)
		logger.info("New version \(version) has been added to subscription \(subscription.bundleID).")
	}
}
