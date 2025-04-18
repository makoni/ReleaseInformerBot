//
//  ReleaseWatcher.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 18.04.2025.
//

import Foundation
import Shared
import Logging

let logger = Logger(label: "ReleaseWatcher")
let releaseWatcher = ReleaseWatcher()

@main
struct MinutePrinter {
    static func main() {
        Task {
            await releaseWatcher.start()
        }
        // Keep the program running indefinitely so that the timer can continue to fire.
        RunLoop.main.run()
    }
}

public actor ReleaseWatcher {
    private let timer: DispatchSourceTimer
    private var isRunning = false {
        didSet {
//            print("isRunning: \(isRunning)")
        }
    }
    private let dbManager: DBManager
    private let searchManager = SearchManager()

    init(dbManager: DBManager = DBManager()) {
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

    func start() {
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

                
            }
        } catch {
            logger.error("Error happened: \(error)")
            return
        }
    }
}
