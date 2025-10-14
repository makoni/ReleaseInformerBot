@testable import ReleaseInformerBot
import VaporTesting
import Testing
import Configuration

@Suite("App Tests")
struct ReleaseInformerBotTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        let configProvider = InMemoryProvider(values: [
            "telegram.apiKey": "test-token",
            "couch.host": "localhost",
            "couch.user": "admin",
            "couch.password": "",
            "couch.port": 5984,
            "couch.requestsTimeout": 5
        ])
        app.releaseInformerConfig = ConfigReader(providers: [configProvider])
        do {
            try await configure(app)
            try await test(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
    
    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }
}
