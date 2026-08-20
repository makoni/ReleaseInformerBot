//
//  TelegramHTML.swift
//  ReleaseInformerBot
//

import Foundation

public extension String {
	/// Escapes the three characters Telegram's HTML parse mode treats as markup.
	///
	/// Telegram rejects an entire message with a 400 when it sees stray markup, so an app
	/// title or release note containing `&`, `<` or `>` — "Barnes & Noble", "if x < y",
	/// "<3" — silently costs the user the whole notification. Worse, the new version has
	/// already been recorded by then, so that release is never announced again.
	var escapedForTelegramHTML: String {
		// `&` first: escaping it after the others would mangle the entities they produce.
		replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}
}
