import Vapor
import CouchDBClient
@preconcurrency import SwiftTelegramSdk

// configures your application
public func configure(_ app: Application) async throws {
    let bot: TGBot = try await .init(
        connectionType: .longpolling(limit: nil, timeout: nil, allowedUpdates: nil),
        dispatcher: nil,
        tgClient: VaporTGClient(client: app.client),
        tgURI: TGBot.standardTGURL,
        botId: ProcessInfo.processInfo.environment["apiKey"] ?? "",
        log: app.logger
    )

    let botActor: TGBotActor = .init()
    await botActor.setBot(bot)
    await BotHandlers.addHandlers(bot: botActor.bot)
    try await botActor.bot.start()

    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // register routes
    try routes(app)
}

let config = CouchDBClient.Config(
    userName: "admin"
)

let dbManager = DBManager()
