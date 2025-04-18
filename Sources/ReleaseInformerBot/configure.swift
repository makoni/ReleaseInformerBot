import Vapor
import Shared
import ReleaseWatcher
@preconcurrency import SwiftTelegramSdk

let dbManager = DBManager()
let releaseWatcher = ReleaseWatcher(dbManager: dbManager)

// configures your application
public func configure(_ app: Application) async throws {
	let bot: TGBot = try await .init(
		connectionType: .longpolling(limit: nil, timeout: nil, allowedUpdates: nil),
		dispatcher: nil,
		tgClient: AsyncHttpTGClient(),
		tgURI: TGBot.standardTGURL,
		botId: ProcessInfo.processInfo.environment["apiKey"] ?? "",
		log: app.logger
	)

	let botActor: BotActor = .init()

	await botActor.setBot(bot)
	await BotHandlers.addHandlers(bot: botActor.bot)
	try await botActor.bot.start()

	await releaseWatcher.setBot(botActor.bot)

	await releaseWatcher.start()

	// uncomment to serve files from /Public folder
	// app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

	// register routes
	try routes(app)
}
