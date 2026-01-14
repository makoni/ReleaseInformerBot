//
//  ReleaseWatcher.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 18.04.2025.
//

import Foundation
import Shared
import Logging
import SwiftTelegramBot

let logger = Logger(label: "ReleaseWatcher")

//let releaseWatcher = ReleaseWatcher()
//
//@main
//struct MinutePrinter {
//    static func main() {
//        Task {
//            await releaseWatcher.start()
//        }
//        // Keep the program running indefinitely so that the timer can continue to fire.
//        RunLoop.main.run()
//    }
//}

public actor ReleaseWatcher {
	private let timer: DispatchSourceTimer

	private let appCheckTimer: DispatchSourceTimer
	private var isRunning = false
	private let dbManager: DBManager
	private let searchManager = SearchManager()

	private var queue = [Subscription]()

	public weak var tgBot: TGBot?

	public init(dbManager: DBManager = DBManager()) {
		self.dbManager = dbManager

		timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
		appCheckTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
	}

	func configureTimers() {
		timer.schedule(deadline: .now(), repeating: .seconds(60 * 5))
		timer.setEventHandler { [weak self] in
			Task { [weak self] in
				guard let self else { return }
				guard await self.queue.isEmpty == true else { return }
				await self.run()
			}
		}

		appCheckTimer.schedule(deadline: .now(), repeating: .seconds(2))
		appCheckTimer.setEventHandler { [weak self] in
			Task { [weak self] in
				try await self?.handleSubscription()
			}
		}
	}

	public func setBot(_ bot: TGBot?) {
		self.tgBot = bot
	}

	public func start() {
		configureTimers()
		timer.resume()
		appCheckTimer.resume()
	}

	func handleSubscription() async throws {
		guard queue.isEmpty == false else { return }
		var subscription = self.queue.removeFirst()

		if subscription.chats.isEmpty {
			try await dbManager.deleteSubscription(subscription)
			logger.info("Deleted subscription for \(subscription.bundleID) as it has no active chats.")
			return
		}

		try await Task.sleep(for: .seconds(2))

		logger.info("Checking subscription: \(subscription.bundleID) - \(subscription.title)")

		guard let appData = try await self.searchManager.search(byBundleID: subscription.bundleID).first else {
			logger.error("App not found with Bundle ID: \(subscription.bundleID)")
			try await dbManager.deleteSubscription(subscription)
			return
		}
		guard !subscription.version.contains(appData.version) else {
			return
		}

		if subscription.title != appData.title {
			subscription.title = appData.title
		}

		if subscription.url != appData.url {
			subscription.url = appData.url
		}

		logger.info("New version \(appData.version) found for \(subscription.bundleID) - \(subscription.title).")
		try await dbManager.addNewVersion(appData.version, forSubscription: subscription)

		for chat in subscription.chats {
			logger.info("Sending notification to chat: \(chat)")

			do {
				var text = "<b>New Version Released!</b>\n\n"
				text += "<b>\(appData.title)</b>\n"
				text += "Version: <b>\(appData.version)</b>\n"
				text += "URL: \(appData.url)\n"
				text += "<b>Bundle ID:</b> \(appData.bundleID)\n\n"

				if let releaseNotes = appData.releaseNotes {
					text += "<b>Release Notes:</b>\n\(releaseNotes)\n\n"
				}

				try await self.tgBot?.sendMessage(
					params: .init(chatId: .chat(chat), text: text, parseMode: .html)
				)
				logger.info("Notification sent to chat: \(chat)")
			} catch {
				logger.error("Failed to send notification for \(subscription.bundleID) to chat \(chat). Error: \(error)")
			}

			try await Task.sleep(for: .seconds(2))
		}
	}

	func run() async {
		guard !isRunning else {
			logger.info("Already running. Skipping this cycle.")
			return
		}
		isRunning = true
		defer { isRunning = false }

		logger.info("Running...")
		do {
			queue = try await dbManager.getAllSubscriptions()

			// for tests
			// subscriptions = subscriptions.filter({ $0.bundleID.contains("com.google") })

			logger.info("Number of subscriptions to check: \(queue.count)")
		} catch {
			logger.error("An error occurred during the run cycle: \(error)")
			return
		}
	}
}
