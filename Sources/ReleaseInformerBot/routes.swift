import Vapor
import CouchDBClient
import SwiftTelegramSdk

let couchDBClient = CouchDBClient(config: config)


func routes(_ app: Application) throws {
    app.get { req async in
        "It works!"
    }
}
