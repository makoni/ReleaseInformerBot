import Vapor
import Shared
import ReleaseWatcher
@preconcurrency import SwiftTelegramSdk
import Logging

fileprivate let logger = Logger(label: "configure")

let dbManager = DBManager()
let releaseWatcher = ReleaseWatcher(dbManager: dbManager)

// configures your application
public func configure(_ app: Application) async throws {
    do {
        try await dbManager.setupIfNeed()
    } catch {
        logger.error("Database setup failed: \(error.localizedDescription)")
        try await Task.sleep(for: .seconds(10))
        exit(1)
    }
    
    let bot: TGBot
    do {
        bot = try await .init(
            connectionType: .longpolling(limit: nil, timeout: nil, allowedUpdates: nil),
            dispatcher: nil,
            tgClient: AsyncHttpTGClient(),
            tgURI: TGBot.standardTGURL,
            botId: ProcessInfo.processInfo.environment["apiKey"] ?? "",
            log: app.logger
        )
    } catch {
        logger.error("Could not initialize bot: \(error)")
        try await Task.sleep(for: .seconds(10))
        exit(1)
    }

	let botActor: BotActor = .init()

	await botActor.setBot(bot)
	await BotHandlers.addHandlers(bot: botActor.bot)

    do {
        try await botActor.bot.start()
    } catch {
        logger.error("Could not start bot: \(error.localizedDescription)")
        try await Task.sleep(for: .seconds(10))
        exit(1)
    }

	await releaseWatcher.setBot(botActor.bot)
	await releaseWatcher.start()

	// uncomment to serve files from /Public folder
	// app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

	// register routes
	try routes(app)
}
