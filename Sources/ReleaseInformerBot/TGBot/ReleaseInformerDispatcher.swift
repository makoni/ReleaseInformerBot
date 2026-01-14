//
//  ReleaseInformerDispatcher.swift
//  ReleaseInformerBot
//

import Logging
import Shared
import SwiftTelegramBot

final class ReleaseInformerDispatcher: TGDefaultDispatcher, @unchecked Sendable {
	private let dbManager: DBManager

	init(bot: TGBot, logger: Logger, dbManager: DBManager) {
		self.dbManager = dbManager
		super.init(bot: bot, logger: logger)
	}

	override func handle() async {
		await BotHandlers.addHandlers(dispatcher: self, dbManager: dbManager)
	}
}
