//
//  Subscription.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import CouchDBClient

struct Subscription: CouchDBRepresentable {
    internal init(_id: String, _rev: String? = nil, bundleId: String, url: String, title: String, version: [String], chats: [Int64]) {
        self._id = _id
        self._rev = _rev
        self.bundleId = bundleId
        self.url = url
        self.title = title
        self.version = version
        self.chats = chats
    }
    
    var _id: String
    var _rev: String?

    func updateRevision(_ newRevision: String) -> Subscription {
        return .init(_id: _id, _rev: newRevision, bundleId: bundleId, url: url, title: title, version: version, chats: chats)
    }

    var bundleId: String
    var url: String
    var title: String
    var version: [String]
    var chats: [Int64]

    enum CodingKeys: String, CodingKey {
        case _id
        case _rev
        case bundleId = "bundle_id"
        case url
        case title
        case version
        case chats
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._id = try container.decode(String.self, forKey: ._id)
        self._rev = try container.decodeIfPresent(String.self, forKey: ._rev)
        self.bundleId = try container.decode(String.self, forKey: .bundleId)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decode(String.self, forKey: .title)

        let version = try container.decodeIfPresent([String].self, forKey: .version)
        if let version {
            self.version = version
        } else {
            let versionString = try container.decodeIfPresent(String.self, forKey: .version)
            self.version = versionString == nil ? [] : [versionString!]
        }

        self.chats = try container.decode([Int64].self, forKey: .chats)
    }
}
