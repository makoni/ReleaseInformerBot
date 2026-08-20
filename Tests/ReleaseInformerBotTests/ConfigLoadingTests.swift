//
//  ConfigLoadingTests.swift
//  ReleaseInformerBot
//

import Foundation
import Testing
import VaporTesting

@testable import ReleaseInformerBot

/// A configuration file that exists but cannot be read used to be a warning, after which the
/// bot carried on with the built-in CouchDB defaults — a different database than the operator
/// asked for, which then looks exactly like every user having no subscriptions. Making that
/// fatal is a deliberate decision, and this is what stops a later "let's be lenient" edit from
/// quietly undoing it.
@Suite("Configuration loading", .serialized)
struct ConfigLoadingTests {
	private func withConfigFile(
		contents: String,
		_ body: (Application) async throws -> Void
	) async throws {
		let path = FileManager.default.temporaryDirectory
			.appendingPathComponent("release-informer-\(UUID().uuidString).json")
		try Data(contents.utf8).write(to: path)
		setenv("RELEASE_INFORMER_CONFIG_PATH", path.path, 1)

		let app = try await Application.make(.testing)
		defer {
			unsetenv("RELEASE_INFORMER_CONFIG_PATH")
			try? FileManager.default.removeItem(at: path)
		}

		do {
			try await body(app)
		} catch {
			try await app.asyncShutdown()
			throw error
		}
		try await app.asyncShutdown()
	}

	@Test("An unreadable configuration file aborts startup")
	func unreadableConfigIsFatal() async throws {
		try await withConfigFile(contents: "{ this is not json") { app in
			await #expect(throws: (any Error).self) {
				try await configure(app)
			}
		}
	}

	@Test("A readable configuration file is accepted")
	func readableConfigIsAccepted() async throws {
		try await withConfigFile(contents: #"{"telegram": {"apiKey": "test-token"}}"#) { app in
			try await configure(app)
			// `.testing` skips service bootstrap, so a successful return is the assertion:
			// the file was read rather than rejected.
			#expect(app.releaseInformerConfig != nil)
		}
	}
}
