//
//  File.swift
//  
//
//  Created by Oleh Hudeichuk on 01.06.2021.
//

import Vapor
import CouchDBClient
@preconcurrency import SwiftTelegramSdk

let couchDBClient = CouchDBClient(config: config)

final class BotHandlers {

    static let db = "release_bot"

    static func addHandlers(bot: TGBot) async {
//        await defaultBaseHandler(bot: bot)
//        await messageHandler(bot: bot)
        await help(bot: bot)
        await list(bot: bot)
        await commandShowButtonsHandler(bot: bot)
        await buttonsActionHandler(bot: bot)
    }
    
    private static func defaultBaseHandler(bot: TGBot) async {
        await bot.dispatcher.add(TGBaseHandler({ update in
            guard let message = update.message else { return }
            let params: TGSendMessageParams = .init(chatId: .chat(message.chat.id), text: "TGBaseHandler")
            try await bot.sendMessage(params: params)
        }))
    }

    private static func messageHandler(bot: TGBot) async {
        await bot.dispatcher.add(TGMessageHandler(filters: (.all && !.command.names(["/ping", "/show_buttons"]))) { update in
            let params: TGSendMessageParams = .init(chatId: .chat(update.message!.chat.id), text: "Success")
            try await bot.sendMessage(params: params)
        })
    }

    private static func help(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/help"]) { update in
            let helpText = """
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
            try await update.message?.reply(text: helpText, bot: bot)
        })
    }

    private static func list(bot: TGBot) async {
        await bot.dispatcher.add(TGCommandHandler(commands: ["/list"]) { update in
            guard let fromId = update.message?.from?.id else { return }


            let response = try await couchDBClient.get(
                fromDB: Self.db,
                uri: "_design/list/_view/by_chat",
                queryItems: [
                    URLQueryItem(name: "key", value: "\(fromId)")
                ]
            )

            let expectedBytes =
                response.headers
                .first(name: "content-length")
                .flatMap(Int.init) ?? 1024 * 1024 * 10
            var bytes = try await response.body.collect(upTo: expectedBytes)

            guard let data = bytes.readData(length: bytes.readableBytes) else {
                bot.log.error("Could not read response")
                return
            }

            let decoder = JSONDecoder()

            let subscriptions = try decoder.decode(
                RowsResponse<Subscription>.self,
                from: data
            ).rows.map({ $0.value })


            let message = Self.makeListMessage(subscriptions)

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
