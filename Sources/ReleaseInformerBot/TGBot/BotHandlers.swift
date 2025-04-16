//
//  File.swift
//  
//
//  Created by Oleh Hudeichuk on 01.06.2021.
//

import Vapor
import CouchDBClient
@preconcurrency import SwiftTelegramSdk

final class BotHandlers {
    static func addHandlers(bot: TGBot) async {
        await help(bot: bot)
        await list(bot: bot)
        await search(bot: bot)
        await commandShowButtonsHandler(bot: bot)
        await buttonsActionHandler(bot: bot)
    }

    private static func help(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/help"]) { update in
            try await update.message?.reply(text: Self.helpText, bot: bot)
        })
    }

    private static func list(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/list"]) { update in
            guard let fromId = update.message?.chat.id else { return }

            let subscriptions = try await dbManager.search(byChatID: fromId)
            let message = Self.makeListMessage(subscriptions)

            try await update.message?.reply(text: message, bot: bot)
        })
    }

    private static func search(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/search"]) { update in
            guard var searchString = update.message?.text else { return }
            searchString = String(searchString.dropFirst("/search".count)).trimmingCharacters(in: .whitespacesAndNewlines)

            let searchResults = try await searchManager.search(byTitle: searchString)
            let message = Self.makeSearchResultsMessage(searchResults)

            try await update.message?.reply(text: message, bot: bot)
        })
    }

    private static func commandShowButtonsHandler(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/show_buttons"]) { update in
            guard let userId = update.message?.from?.id else { fatalError("user id not found") }
            let buttons: [[TGInlineKeyboardButton]] = [
                [.init(text: "Button 1", callbackData: "press 1"), .init(text: "Button 2", callbackData: "press 2")]
            ]
            let keyboard: TGInlineKeyboardMarkup = .init(inlineKeyboard: buttons)
            let params: TGSendMessageParams = .init(chatId: .chat(userId),
                                                    text: "Keyboard active",
                                                    replyMarkup: .inlineKeyboardMarkup(keyboard))
            try await bot.sendMessage(params: params)
        })
    }

    private static func buttonsActionHandler(bot: TGBot) async {
        await bot.dispatcher.add(TGCallbackQueryHandler(pattern: "press 1") { update in
            bot.log.info("press 1")
            guard let userId = update.callbackQuery?.from.id else { fatalError("user id not found") }
            let params: TGAnswerCallbackQueryParams = .init(callbackQueryId: update.callbackQuery?.id ?? "0",
                                                            text: update.callbackQuery?.data  ?? "data not exist",
                                                            showAlert: nil,
                                                            url: nil,
                                                            cacheTime: nil)
            try await bot.answerCallbackQuery(params: params)
            try await bot.sendMessage(params: .init(chatId: .chat(userId), text: "press 1"))
        })
        
        await bot.dispatcher.add(TGCallbackQueryHandler(pattern: "press 2") { update in
            bot.log.info("press 2")
            guard let userId = update.callbackQuery?.from.id else { fatalError("user id not found") }
            let params: TGAnswerCallbackQueryParams = .init(callbackQueryId: update.callbackQuery?.id ?? "0",
                                                            text: update.callbackQuery?.data  ?? "data not exist",
                                                            showAlert: nil,
                                                            url: nil,
                                                            cacheTime: nil)
            try await bot.answerCallbackQuery(params: params)
            try await bot.sendMessage(params: .init(chatId: .chat(userId), text: "press 2"))
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
        /search GMail
        /add com.google.Gmail
        /del com.google.Gmail
        /list
        """

    static func makeSearchResultsMessage(_ results: [SearchResult]) -> String {
        if results.isEmpty {
            return "Nothing found in App Store."
        }

        var text = "Search results:\n\n"

        for result in results[0..<min(10, results.count)] {
            text += result.title + "\n"
            text += "Version: " + (result.version) + "\n"
            text += "URL: " + result.url + "\n"
            text += "Bundle ID: " + result.bundleId + "\n\n"
        }

        return text
    }

    static func makeListMessage(_ subscriptions: [Subscription]) -> String {
        if subscriptions.isEmpty {
            return "You are not subscribed to any apps updates."
        }

        var text = "Results:\n\n"

        for subscription in subscriptions {
            text += subscription.title + "\n"
            text += "Version: " + (subscription.version.last ?? "") + "\n"
            text += "URL: " + subscription.url + "\n"
            text += "Bundle ID: " + subscription.bundleId + "\n\n"
        }

        return text
    }
}
