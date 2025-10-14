import Vapor
import Shared
import ReleaseWatcher
@preconcurrency import SwiftTelegramSdk
import Logging
import Configuration
import Foundation
import SystemPackage

fileprivate let logger = Logger(label: "configure")

private enum ConfigConstants {
	static let envConfigPath = "RELEASE_INFORMER_CONFIG_PATH"
	static let defaultConfigRelativePath = "config/config.json"
}

extension Application {
	private struct ConfigReaderStorageKey: StorageKey {
		typealias Value = ConfigReader
	}

	private struct DBManagerStorageKey: StorageKey {
		typealias Value = DBManager
	}

	private struct ReleaseWatcherStorageKey: StorageKey {
		typealias Value = ReleaseWatcher
	}

	var releaseInformerConfig: ConfigReader? {
		get { storage[ConfigReaderStorageKey.self] }
		set { storage[ConfigReaderStorageKey.self] = newValue }
	}

	var releaseInformerDBManager: DBManager? {
		get { storage[DBManagerStorageKey.self] }
		set { storage[DBManagerStorageKey.self] = newValue }
	}

	var releaseInformerWatcher: ReleaseWatcher? {
		get { storage[ReleaseWatcherStorageKey.self] }
		set { storage[ReleaseWatcherStorageKey.self] = newValue }
	}
}

// configures your application
public func configure(_ app: Application) async throws {
	let config = try await loadConfig(for: app)

	let shouldBootstrapServices = config.bool(
		forKey: "runtime.bootstrapServices",
		default: app.environment != .testing
	)

	let telegramKey = config.string(
		forKey: "telegram.apiKey",
		default: ProcessInfo.processInfo.environment["apiKey"] ?? ""
	)

	guard telegramKey.isEmpty == false || shouldBootstrapServices == false else {
		logger.error("Telegram API key is missing. Set telegram.apiKey in configuration or apiKey environment variable.")
		try await Task.sleep(for: .seconds(10))
		exit(1)
	}

	guard shouldBootstrapServices else {
		try routes(app)
		return
	}

	let couchConfig = makeCouchConfig(using: config)
	let dbManager = DBManager(couchConfig: couchConfig)
	app.releaseInformerDBManager = dbManager

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
			botId: telegramKey,
			log: app.logger
		)
	} catch {
		logger.error("Could not initialize bot: \(error)")
		try await Task.sleep(for: .seconds(10))
		exit(1)
	}

	let botActor: BotActor = .init()

	await botActor.setBot(bot)
	await BotHandlers.addHandlers(bot: botActor.bot, dbManager: dbManager)

	do {
		try await botActor.bot.start()
	} catch {
		logger.error("Could not start bot: \(error.localizedDescription)")
		try await Task.sleep(for: .seconds(10))
		exit(1)
	}

	let releaseWatcher = ReleaseWatcher(dbManager: dbManager)
	app.releaseInformerWatcher = releaseWatcher
	await releaseWatcher.setBot(botActor.bot)
	await releaseWatcher.start()

	// uncomment to serve files from /Public folder
	// app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

	// register routes
	try routes(app)
}

private func loadConfig(for app: Application) async throws -> ConfigReader {
	if let existing = app.releaseInformerConfig {
		return existing
	}

	var providers: [any ConfigProvider] = [EnvironmentVariablesProvider()]

	let configuredPath = ProcessInfo.processInfo.environment[ConfigConstants.envConfigPath]
	let defaultPath = app.directory.workingDirectory + ConfigConstants.defaultConfigRelativePath
	let candidatePath = configuredPath ?? defaultPath

	if FileManager.default.fileExists(atPath: candidatePath) {
		do {
			let jsonProvider = try await JSONProvider(filePath: FilePath(candidatePath))
			providers.append(jsonProvider)
		} catch {
			logger.warning("Failed to load configuration file at \(candidatePath): \(error)")
		}
	} else if let configuredPath {
		logger.warning("Configuration file not found at \(configuredPath). Proceeding with environment variables only.")
	}

	let config = ConfigReader(providers: providers)
	app.releaseInformerConfig = config
	return config
}

private func makeCouchConfig(using config: ConfigReader) -> CouchConfig {
	let proto = config.string(forKey: "couch.protocol", default: "http")
	let host = config.string(forKey: "couch.host", default: "127.0.0.1")
	let port = config.int(forKey: "couch.port", default: 5984)
	let user = config.string(forKey: "couch.user", default: "admin")
	let password = config.string(
		forKey: "couch.password",
		default: ProcessInfo.processInfo.environment["COUCHDB_PASS"] ?? ""
	)
	let timeout = config.int(forKey: "couch.requestsTimeout", default: 30)

	return CouchConfig(
		couchProtocol: CouchConfig.makeProtocol(proto),
		host: host,
		port: port,
		user: user,
		password: password,
		timeout: Int64(timeout)
	)
}
