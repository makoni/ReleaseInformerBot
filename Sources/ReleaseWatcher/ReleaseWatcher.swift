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
        print("run called")
        guard !isRunning else {
            print("running already. skipping")
            return
        }
        isRunning = true
        defer { isRunning = false }

        print("running")
        let subscriptions: [Subscription]
        do {
            subscriptions = try await dbManager.getAllSubscriptions()

            logger.info("Subscriptions to check: \(subscriptions.count)")
            for subscription in subscriptions {
                if subscription.chats.isEmpty {
                    try await dbManager.deleteSubscription(subscription)
                    continue
                }

                try await Task.sleep(for: .seconds(1))

                logger.info("Checking \(subscription.bundleID) - \(subscription.title)")

                guard let appData = try await searchManager.search(byBundleID: subscription.bundleID).first else {
                    logger.error("App not found with bundle ID: \(subscription.bundleID)")
                    continue
                }
                guard !subscription.version.contains(appData.version) else {
                    continue
                }

                logger.info("New version \(appData.version) found for \(subscription.bundleID) - \(subscription.title)")
            }
        } catch {
            logger.error("Error happened: \(error)")
            return
        }
    }
}
