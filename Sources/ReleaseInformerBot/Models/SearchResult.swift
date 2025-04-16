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

struct SearchResult: Codable {
    let title: String
    let bundleId: String
    let url: String
    let version: String
    let releaseNotes: String

    enum CodingKeys: String, CodingKey {
        case title = "trackCensoredName"
        case bundleId = "bundleId"
        case url = "trackViewUrl"
        case version
        case releaseNotes = "releaseNotes"
    }
}

struct SearchResultResponse: Codable {
    let resultCount: Int
    let results: [SearchResult]
}
