//
//  SearchResult.swift
//  ReleaseInformerBot
//
//  Created by Sergei Armodin on 17.04.2025.
//

import Foundation

/*
 {
   "resultCount": 50,
   "results": [
     {
       "trackCensoredName": "VLC media player",
       "trackViewUrl": "https://apps.apple.com/us/app/vlc-media-player/id650377962?uo=4",
       "bundleId": "org.videolan.vlc-ios",
       "trackName": "VLC media player",
       "releaseNotes": "· Fix another edge-case of silent playback recovery",
       "version": "3.6.4",
     }   ]
 }
 */

public struct SearchResult: Codable, Sendable {
	public let title: String
	public let bundleID: String
	public let url: String
	public let version: String
	public let releaseNotes: String?
	/// `software` for iOS, `mac-software` for the Mac build. A universal-purchase app can
	/// answer a single bundle ID with one entry per platform, and their version numbers
	/// differ — so this is what keeps the announced version from flipping between them.
	public let kind: String?

	public init(
		title: String,
		bundleID: String,
		url: String,
		version: String,
		releaseNotes: String? = nil,
		kind: String? = nil
	) {
		self.title = title
		self.bundleID = bundleID
		self.url = url
		self.version = version
		self.releaseNotes = releaseNotes
		self.kind = kind
	}

	/// Whether this entry is the iOS build. Absent `kind` is treated as iOS: the field is
	/// missing from some older entries, and iOS is what this bot is about.
	public var isiOSApp: Bool {
		kind == nil || kind == "software"
	}

	enum CodingKeys: String, CodingKey {
		case title = "trackCensoredName"
		case bundleID = "bundleId"
		case url = "trackViewUrl"
		case version
		case releaseNotes = "releaseNotes"
		case kind
	}
}

public struct SearchResultResponse: Codable {
	public let resultCount: Int
	public let results: [SearchResult]
}
