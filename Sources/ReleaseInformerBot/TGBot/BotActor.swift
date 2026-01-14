//
//  BotActor.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import SwiftTelegramBot

actor BotActor {
	private var _bot: TGBot!
	var bot: TGBot { self._bot }
	func setBot(_ bot: TGBot) { self._bot = bot }
}
