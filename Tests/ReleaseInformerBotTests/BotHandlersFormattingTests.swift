import Foundation
import Testing

@testable import ReleaseInformerBot
import Shared

@Suite("BotHandlers formatting")
struct BotHandlersFormattingTests {
	private func makeSearchResult(index: Int) throws -> SearchResult {
		let json = """
		{
		  "trackCensoredName": "App \(index)",
		  "bundleId": "com.example.app\(index)",
		  "trackViewUrl": "https://example.com/app\(index)",
		  "version": "\(index).0"
		}
		"""
		return try JSONDecoder().decode(SearchResult.self, from: Data(json.utf8))
	}

	private func makeSubscription(title: String, bundleID: String, url: String, versions: [String]) throws -> Subscription {
		let versionsJSON = versions.isEmpty
			? "[]"
			: "[" + versions.map { "\"\($0)\"" }.joined(separator: ",") + "]"
		let json = """
		{
		  "_id": "test-id",
		  "bundle_id": "\(bundleID)",
		  "url": "\(url)",
		  "title": "\(title)",
		  "version": \(versionsJSON),
		  "chats": [123]
		}
		"""
		return try JSONDecoder().decode(Subscription.self, from: Data(json.utf8))
	}

	@Test("makeSearchResultsMessage: empty")
	func searchResultsEmpty() {
		#expect(BotHandlers.makeSearchResultsMessage([]) == "No results found in the App Store.")
	}

	@Test("makeSearchResultsMessage: limits to 10")
	func searchResultsLimitedTo10() async throws {
		let results = try (0..<12).map { try makeSearchResult(index: $0) }
		let message = BotHandlers.makeSearchResultsMessage(results)
		#expect(message.contains("App 0"))
		#expect(message.contains("App 9"))
		#expect(!message.contains("App 10"))
		#expect(!message.contains("App 11"))
	}

	@Test("makeListMessage: empty")
	func listEmpty() {
		#expect(BotHandlers.makeListMessage([]) == "You are not subscribed to updates for any apps.")
	}

	@Test("makeListMessage: shows last version or N/A")
	func listShowsLastVersion() throws {
		let s1 = try makeSubscription(title: "MyApp", bundleID: "com.my.app", url: "https://example.com", versions: ["1.0", "1.1"])
		let s2 = try makeSubscription(title: "NoVersion", bundleID: "com.none", url: "https://example.com/none", versions: [])
		let message = BotHandlers.makeListMessage([s1, s2])
		#expect(message.contains("<b>MyApp</b>"))
		#expect(message.contains("Latest Version: <b>1.1</b>"))
		#expect(message.contains("<b>NoVersion</b>"))
		#expect(message.contains("Latest Version: <b>N/A</b>"))
	}
}
