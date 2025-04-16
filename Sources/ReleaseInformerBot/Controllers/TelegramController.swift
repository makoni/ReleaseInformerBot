//
//  TelegramController.swift
//  Vapor-telegram-bot-example
//
//  Created by Oleh Hudeichuk on 10.03.2023.
//

import Foundation
import Vapor
@preconcurrency import SwiftTelegramSdk

final class TelegramController: RouteCollection {
    func boot(routes: any Vapor.RoutesBuilder) throws {}
}
