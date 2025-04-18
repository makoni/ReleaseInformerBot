//
//  ReleaseWatcher.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 18.04.2025.
//

import Foundation
import Shared
import Logging
@preconcurrency import SwiftTelegramSdk

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
    private var isRunning = false
    private let dbManager: DBManager
    private let searchManager = SearchManager()

    public weak var tgBot: TGBot?

    public init(dbManager: DBManager = DBManager()) {
        self.dbManager = dbManager

        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .seconds(60*5))
        timer.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.run()
            }
        }
        print("init")
    }

    public func setBot(_ bot: TGBot?) {
        self.tgBot = bot
    }

    public func start() {
        timer.resume()
    }

    func run() async {
        print("Run called")
        guard !isRunning else {
            print("Already running. Skipping this cycle.")
            return
        }
        isRunning = true
        defer { isRunning = false }

        print("Running...")
        var subscriptions: [Subscription]
        do {
            subscriptions = try await dbManager.getAllSubscriptions()

            // for tests
//            subscriptions = subscriptions.filter({ $0.bundleID == "org.videolan.vlc-ios" })

            logger.info("Number of subscriptions to check: \(subscriptions.count)")
            for subscription in subscriptions {
                if subscription.chats.isEmpty {
                    try await dbManager.deleteSubscription(subscription)
                    logger.info("Deleted subscription for \(subscription.bundleID) as it has no active chats.")
                    continue
                }

                try await Task.sleep(for: .seconds(1))

                logger.info("Checking subscription: \(subscription.bundleID) - \(subscription.title)")

                guard let appData = try await searchManager.search(byBundleID: subscription.bundleID).first else {
                    logger.error("App not found with Bundle ID: \(subscription.bundleID)")
                    continue
                }
                guard !subscription.version.contains(appData.version) else {
                    continue
                }

                logger.info("New version \(appData.version) found for \(subscription.bundleID) - \(subscription.title).")
                try await dbManager.addNewVersion(appData.version, forSubscription: subscription)

                for chat in subscription.chats {
                    logger.info("Sending notification to chat: \(chat)")

                    do {
                        var text = "New version released!\n\n"
                        text += "<b>\(appData.title)</b>\n"
                        text += "Version: <b>\(appData.version)</b>\n"
                        text += "URL: \(appData.url)\n"
                        text += "<b>Bundle ID:</b> \(appData.bundleID)\n\n"

                        try await tgBot?.sendMessage(
                            params: .init(chatId: .chat(chat), text: text, parseMode: .html)
                        )
                        logger.info("Notification sent to chat: \(chat)")
                    } catch {
                        logger.error("Failed to send notification to chat \(chat). Error: \(error)")
                    }

                    try await Task.sleep(for: .seconds(1))
                }
            }
        } catch {
            logger.error("An error occurred during the run cycle: \(error)")
            return
        }
    }
}
