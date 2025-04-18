//
//  Subscription.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import CouchDBClient
import Foundation

public struct Subscription: CouchDBRepresentable {
    internal init(_id: String = NSUUID().uuidString, _rev: String? = nil, bundleId: String, url: String, title: String, version: [String], chats: Set<Int64>) {
        self._id = _id
        self._rev = _rev
        self.bundleId = bundleId
        self.url = url
        self.title = title
        self.version = version
        self.chats = chats
    }
    
    public var _id: String
    public var _rev: String?

    public func updateRevision(_ newRevision: String) -> Subscription {
        return .init(_id: _id, _rev: newRevision, bundleId: bundleId, url: url, title: title, version: version, chats: chats)
    }

    public var bundleId: String
    public var url: String
    public var title: String
    public var version: [String]
    public var chats: Set<Int64>

    enum CodingKeys: String, CodingKey {
        case _id
        case _rev
        case bundleId = "bundle_id"
        case url
        case title
        case version
        case chats
    }

    public init(from decoder: any Decoder) throws {
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

        self.chats = try container.decode(Set<Int64>.self, forKey: .chats)
    }
}
