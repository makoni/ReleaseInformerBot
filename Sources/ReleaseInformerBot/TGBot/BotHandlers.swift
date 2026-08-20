//
//  BotHandlers.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import Vapor
import Shared
import Logging
import SwiftTelegramBot

let searchManager = SearchManager()

final class BotHandlers {
	static func addHandlers(dispatcher: any TGDefaultDispatcherPrtcl, dbManager: DBManager) async {
		let bot = dispatcher.bot
		await help(dispatcher: dispatcher, bot: bot)
		await list(dispatcher: dispatcher, bot: bot, dbManager: dbManager)
		await search(dispatcher: dispatcher, bot: bot)
		await add(dispatcher: dispatcher, bot: bot, dbManager: dbManager)
		await del(dispatcher: dispatcher, bot: bot, dbManager: dbManager)
		await commandShowButtonsHandler(dispatcher: dispatcher, bot: bot)
		await buttonsActionHandler(dispatcher: dispatcher, bot: bot, dbManager: dbManager)
	}

	private static func help(dispatcher: any TGDefaultDispatcherPrtcl, bot: TGBot) async {
		await dispatcher.add(
			TGCommandHandler(commands: ["/help"]) { update in
				try await update.message?.reply(text: Self.helpText, bot: bot, parseMode: .html)
			})
	}

	private static func list(dispatcher: any TGDefaultDispatcherPrtcl, bot: TGBot, dbManager: DBManager) async {
		await dispatcher.add(
			TGCommandHandler(commands: ["/list"]) { update in
				guard let chatID = update.message?.chat.id else { return }

				do {
					let subscriptions = try await dbManager.search(byChatID: chatID)

					guard !subscriptions.isEmpty else {
						try await update.message?.reply(text: Self.makeListMessage([]), bot: bot, parseMode: .html)
						return
					}

					// Telegram caps message length, so a long list goes out in pages.
					for page in subscriptions.chunked(into: 10) {
						let message = Self.makeListMessage(page)
						try await update.message?.reply(text: message, bot: bot, parseMode: .html)
					}
				} catch {
					await Self.replyWithFailure(error, to: update, bot: bot, log: dispatcher.log)
				}
			})
	}

	private static func search(dispatcher: any TGDefaultDispatcherPrtcl, bot: TGBot) async {
		await dispatcher.add(
			TGCommandHandler(commands: ["/search"]) { update in
				guard var searchString = update.message?.text else { return }
				searchString = String(searchString.dropFirst("/search".count)).trimmingCharacters(in: .whitespacesAndNewlines)

				do {
					let searchResults = try await searchManager.search(byTitle: searchString)
					let message = Self.makeSearchResultsMessage(searchResults)

					try await update.message?.reply(text: message, bot: bot, parseMode: .html)
				} catch {
					await Self.replyWithFailure(error, to: update, bot: bot, log: dispatcher.log)
				}
			})
	}

	private static func del(dispatcher: any TGDefaultDispatcherPrtcl, bot: TGBot, dbManager: DBManager) async {
		await dispatcher.add(
			TGCommandHandler(commands: ["/del"]) { update in
				guard let chatID = update.message?.chat.id else { return }
				guard var searchString = update.message?.text else { return }
				searchString = String(searchString.dropFirst("/del".count)).trimmingCharacters(in: .whitespacesAndNewlines)

				do {
					guard let subscription = try await dbManager.unsubscribeFromNewVersions(searchString, forChatID: chatID) else {
						let message = "Subscription for <b>\(searchString.escapedForTelegramHTML)</b> not found"
						try await update.message?.reply(text: message, bot: bot, parseMode: .html)
						return
					}

					let message = "<b>\(subscription.title.escapedForTelegramHTML)</b> with bundle ID <b>\(subscription.bundleID.escapedForTelegramHTML)</b> has been removed from your subscriptions."
					try await update.message?.reply(text: message, bot: bot, parseMode: .html)
				} catch {
					await Self.replyWithFailure(error, to: update, bot: bot, log: dispatcher.log)
				}
			})
	}

	private static func add(dispatcher: any TGDefaultDispatcherPrtcl, bot: TGBot, dbManager: DBManager) async {
		await dispatcher.add(
			TGCommandHandler(commands: ["/add"]) { update in
				guard let chatID = update.message?.chat.id else { return }
				guard var searchString = update.message?.text else { return }
				searchString = String(searchString.dropFirst("/add".count)).trimmingCharacters(in: .whitespacesAndNewlines)

				do {
					let searchResults = try await searchManager.search(byBundleID: searchString)
					// The watcher prefers the iOS entry, so the baseline version recorded here
					// has to come from the same one — otherwise the first sweep announces the
					// other platform's version as brand new.
					guard let result = searchResults.first(where: \.isiOSApp) ?? searchResults.first else {
						let message = Self.makeSearchResultsMessage([])
						try await update.message?.reply(text: message, bot: bot, parseMode: .html)
						return
					}

					let outcome = try await dbManager.subscribeForNewVersions(result, forChatID: chatID)

					let message = Self.makeSubscribedMessage(for: result, outcome: outcome)
					try await update.message?.reply(text: message, bot: bot, parseMode: .html)
				} catch {
					await Self.replyWithFailure(error, to: update, bot: bot, log: dispatcher.log)
				}
			})
	}

	private static func commandShowButtonsHandler(dispatcher: any TGDefaultDispatcherPrtcl, bot: TGBot) async {
		await dispatcher.add(
			TGCommandHandler(commands: ["/start"]) { update in
				guard let chatID = update.message?.chat.id else {
					dispatcher.log.error("User ID not found")
					return
				}
				let buttons: [[TGInlineKeyboardButton]] = [
					[
						.init(text: "Help", callbackData: "help"),
						.init(text: "Subscriptions List", callbackData: "list")
					]
				]
				let keyboard: TGInlineKeyboardMarkup = .init(inlineKeyboard: buttons)
				let params: TGSendMessageParams = .init(
					chatId: .chat(chatID),
					text: "Keyboard active",
					replyMarkup: .inlineKeyboardMarkup(keyboard)
				)
				try await bot.sendMessage(params: params)
			})
	}

	private static func buttonsActionHandler(dispatcher: any TGDefaultDispatcherPrtcl, bot: TGBot, dbManager: DBManager) async {
		await dispatcher.add(
			TGCallbackQueryHandler(pattern: "help") { update in
				dispatcher.log.info("help")

				guard let chatID = update.callbackQuery?.from.id else {
					dispatcher.log.error("user id not found")
					return
				}

				let params: TGAnswerCallbackQueryParams = .init(
					callbackQueryId: update.callbackQuery?.id ?? "0",
					text: update.callbackQuery?.data ?? "data not exist",
					showAlert: nil,
					url: nil,
					cacheTime: nil
				)
				try await bot.answerCallbackQuery(params: params)
				try await bot.sendMessage(params: .init(chatId: .chat(chatID), text: Self.helpText, parseMode: .html))
			})

		await dispatcher.add(
			TGCallbackQueryHandler(pattern: "list") { update in
				guard let userId = update.callbackQuery?.from.id else {
					dispatcher.log.error("user id not found")
					return
				}

				let params: TGAnswerCallbackQueryParams = .init(
					callbackQueryId: update.callbackQuery?.id ?? "0",
					text: update.callbackQuery?.data ?? "data not exist",
					showAlert: nil,
					url: nil,
					cacheTime: nil
				)
				try await bot.answerCallbackQuery(params: params)

				do {
					let subscriptions = try await dbManager.search(byChatID: userId)
					let message = Self.makeListMessage(subscriptions)

					try await bot.sendMessage(params: .init(chatId: .chat(userId), text: message, parseMode: .html))
				} catch {
					dispatcher.log.error("Subscriptions list failed: \(error)")
					_ = try? await bot.sendMessage(
						params: .init(chatId: .chat(userId), text: Self.genericFailureText, parseMode: .html)
					)
				}
			})
	}
}

extension BotHandlers {
	static let genericFailureText = "Sorry, something went wrong handling that. Please try again."
	static let rateLimitedText = "The App Store is rate-limiting me at the moment. Please try again in a minute."

	/// Turns a thrown handler error into something the user actually sees.
	///
	/// The Telegram SDK runs each handler in a detached task and does nothing with a throw
	/// but log it, so without this a rate-limited App Store leaves the user staring at
	/// silence — which is worse than the "No results found" they used to get.
	static func failureText(for error: any Error) -> String {
		guard let searchError = error as? SearchManager.SearchError, searchError == .rateLimited else {
			return genericFailureText
		}
		return rateLimitedText
	}

	private static func replyWithFailure(
		_ error: any Error,
		to update: TGUpdate,
		bot: TGBot,
		log: Logger
	) async {
		log.error("Handler failed: \(error)")
		try? await update.message?.reply(text: Self.failureText(for: error), bot: bot, parseMode: .html)
	}

	private static let helpText = """
		Help: 

		/help - Display this help message.
		/search [app name] - Search for an app by name.
		/add [bundle ID] - Subscribe to notifications for new versions of an app using its Bundle ID (you can find it with /search).
		/del [bundle ID] - Unsubscribe from notifications for new versions using the Bundle ID.
		/list - Show your list of subscriptions.

		Examples:
		<pre>/search Gmail</pre>
		<pre>/add com.google.Gmail</pre>
		<pre>/del com.google.Gmail</pre>
		<pre>/list</pre>
		"""

	static func makeSearchResultsMessage(_ results: [SearchResult]) -> String {
		if results.isEmpty {
			return "No results found in the App Store."
		}

		var text = "Search Results:\n\n"

		for result in results[0..<min(10, results.count)] {
			text += "<b>\(result.title.escapedForTelegramHTML)</b>\n"
			text += "Version: <b>\(result.version.escapedForTelegramHTML)</b>\n"
			text += "URL: \(result.url.escapedForTelegramHTML)\n"
			text += "Bundle ID: <b>\(result.bundleID.escapedForTelegramHTML)</b>\n\n"
		}

		return text
	}

	static func makeSubscribedMessage(
		for result: SearchResult,
		outcome: DBManager.SubscribeOutcome
	) -> String {
		let name = "<b>\(result.title.escapedForTelegramHTML)</b>"
		let bundle = "<b>\(result.bundleID.escapedForTelegramHTML)</b>"

		switch outcome {
		case .subscribed:
			return "\(name) with bundle ID \(bundle) has been added to your subscriptions. I will inform you when a new version will be released."
		case .alreadySubscribed:
			return "You are already subscribed to \(name) with bundle ID \(bundle)."
		}
	}

	static func makeListMessage(_ subscriptions: [Subscription]) -> String {
		if subscriptions.isEmpty {
			return "You are not subscribed to updates for any apps."
		}

		var text = "Your Subscriptions:\n\n"

		for subscription in subscriptions {
			text += "<b>\(subscription.title.escapedForTelegramHTML)</b>\n"
			text += "Latest Version: <b>\((subscription.version.last ?? "N/A").escapedForTelegramHTML)</b>\n"
			text += "URL: \(subscription.url.escapedForTelegramHTML)\n"
			text += "Bundle ID: <b>\(subscription.bundleID.escapedForTelegramHTML)</b>\n\n"
		}

		return text
	}
}
