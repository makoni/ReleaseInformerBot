//
//  BotHandlers.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import Vapor
import CouchDBClient
import Shared
import Logging
@preconcurrency import SwiftTelegramSdk

let searchManager = SearchManager()

final class BotHandlers {
    static func addHandlers(bot: TGBot) async {
        await help(bot: bot)
        await list(bot: bot)
        await search(bot: bot)
        await add(bot: bot)
        await del(bot: bot)
        await commandShowButtonsHandler(bot: bot)
        await buttonsActionHandler(bot: bot)
    }

    private static func help(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/help"]) { update in
            try await update.message?.reply(text: Self.helpText, bot: bot, parseMode: .html)
        })
    }

    private static func list(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/list"]) { update in
            guard let chatID = update.message?.chat.id else { return }

            let subscriptions = try await dbManager.search(byChatID: chatID)
            let message = Self.makeListMessage(subscriptions)

            try await update.message?.reply(text: message, bot: bot, parseMode: .html)
        })
    }

    private static func search(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/search"]) { update in
            guard var searchString = update.message?.text else { return }
            searchString = String(searchString.dropFirst("/search".count)).trimmingCharacters(in: .whitespacesAndNewlines)

            let searchResults = try await searchManager.search(byTitle: searchString)
            let message = Self.makeSearchResultsMessage(searchResults)

            try await update.message?.reply(text: message, bot: bot, parseMode: .html)
        })
    }

    private static func del(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/del"]) { update in
            guard let chatID = update.message?.chat.id else { return }
            guard var searchString = update.message?.text else { return }
            searchString = String(searchString.dropFirst("/del".count)).trimmingCharacters(in: .whitespacesAndNewlines)

            guard let subscription = try await dbManager.unsubscribeFromNewVersions(searchString, forChatID: chatID) else {
                let message = "Subscription for <b>\(searchString)</b> not found"
                try await update.message?.reply(text: message, bot: bot, parseMode: .html)
                return
            }

            let message = "<b>\(subscription.title)</b> with bundle ID <b>\(subscription.bundleID)</b> has been removed from your subscriptions."
            try await update.message?.reply(text: message, bot: bot, parseMode: .html)
        })
    }

    private static func add(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/add"]) { update in
            guard let chatID = update.message?.chat.id else { return }
            guard var searchString = update.message?.text else { return }
            searchString = String(searchString.dropFirst("/add".count)).trimmingCharacters(in: .whitespacesAndNewlines)

            let searchResults = try await searchManager.search(byBundleID: searchString)
            guard let result = searchResults.first else {
                let message = Self.makeSearchResultsMessage([])
                try await update.message?.reply(text: message, bot: bot, parseMode: .html)
                return
            }

            try await dbManager.subscribeForNewVersions(result, forChatID: chatID)

            let message = "<b>\(result.title)</b> with bundle ID <b>\(result.bundleID)</b> has been added to your subscriptions. I will inform you when a new version will be released."
            try await update.message?.reply(text: message, bot: bot, parseMode: .html)
        })
    }

    private static func commandShowButtonsHandler(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/start"]) { update in
            guard let chatID = update.message?.chat.id else {
                bot.log.error("User ID not found")
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

    private static func buttonsActionHandler(bot: TGBot) async {
        await bot.dispatcher.add(TGCallbackQueryHandler(pattern: "help") { update in
            bot.log.info("help")

            guard let chatID = update.callbackQuery?.from.id else {
                bot.log.error("user id not found")
                return
            }

            let params: TGAnswerCallbackQueryParams = .init(
                callbackQueryId: update.callbackQuery?.id ?? "0",
                text: update.callbackQuery?.data  ?? "data not exist",
                showAlert: nil,
                url: nil,
                cacheTime: nil
            )
            try await bot.answerCallbackQuery(params: params)
            try await bot.sendMessage(params: .init(chatId: .chat(chatID), text: Self.helpText, parseMode: .html))
        })
        
        await bot.dispatcher.add(TGCallbackQueryHandler(pattern: "list") { update in
            guard let userId = update.callbackQuery?.from.id else {
                bot.log.error("user id not found")
                return
            }

            let params: TGAnswerCallbackQueryParams = .init(
                callbackQueryId: update.callbackQuery?.id ?? "0",
                text: update.callbackQuery?.data  ?? "data not exist",
                showAlert: nil,
                url: nil,
                cacheTime: nil
            )
            try await bot.answerCallbackQuery(params: params)

            let subscriptions = try await dbManager.search(byChatID: userId)
            let message = Self.makeListMessage(subscriptions)

            try await bot.sendMessage(params: .init(chatId: .chat(userId), text: message, parseMode: .html))
        })
    }
}

private extension BotHandlers {
    static let helpText = """
        Help: 
        
        /help - help.
        /search [app name] - search app by name.
        /add [bundle ID] - subscribe for notifications about new versions of app by Bundle ID (you can find it with /search).
        /del [bundle ID]- unsubscribe from notifications about new versions by Bundle ID.
        /list - list of subscribtions
        
        Examples:
        <pre>/search GMail</pre>
        <pre>/add com.google.Gmail</pre>
        <pre>/del com.google.Gmail</pre>
        <pre>/list</pre>
        """

    static func makeSearchResultsMessage(_ results: [SearchResult]) -> String {
        if results.isEmpty {
            return "Nothing found in App Store."
        }

        var text = "Search results:\n\n"

        for result in results[0..<min(10, results.count)] {
            text += "<b>" + result.title + "</b>\n"
            text += "Version: <b>" + (result.version) + "</b>\n"
            text += "URL: " + result.url + "\n"
            text += "Bundle ID: <b>" + result.bundleID + "</b>\n\n"
        }

        return text
    }

    static func makeListMessage(_ subscriptions: [Subscription]) -> String {
        if subscriptions.isEmpty {
            return "You are not subscribed to any apps updates."
        }

        var text = "Subscriptions:\n\n"

        for subscription in subscriptions {
            text += "<b>" + subscription.title + "</b>\n"
            text += "Version: <b>" + (subscription.version.last ?? "") + "</b>\n"
            text += "URL: " + subscription.url + "\n"
            text += "Bundle ID: <b>" + subscription.bundleID + "</b>\n\n"
        }

        return text
    }
}
