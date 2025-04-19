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

	enum CodingKeys: String, CodingKey {
		case title = "trackCensoredName"
		case bundleID = "bundleId"
		case url = "trackViewUrl"
		case version
		case releaseNotes = "releaseNotes"
	}
}

public struct SearchResultResponse: Codable {
	public let resultCount: Int
	public let results: [SearchResult]
}
