// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReleaseInformerBot",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.1"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/nerzh/swift-telegram-sdk.git", .upToNextMajor(from: "4.3.0")),
        .package(url: "https://github.com/makoni/couchdb-swift.git", from: "2.1.0"),
        .package(url: "https://github.com/apple/swift-configuration", .upToNextMinor(from: "0.1.0")),
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "CouchDBClient", package: "couchdb-swift"),
            ]
        ),
        .target(
            name: "ReleaseWatcher",
            dependencies: [
                .product(name: "SwiftTelegramBot", package: "swift-telegram-sdk"),
                .target(name: "Shared")
            ]
        ),
        .executableTarget(
            name: "ReleaseInformerBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SwiftTelegramBot", package: "swift-telegram-sdk"),
                .product(name: "Configuration", package: "swift-configuration"),
                .target(name: "Shared"),
                .target(name: "ReleaseWatcher")
            ]
        ),
        .testTarget(
            name: "ReleaseInformerBotTests",
            dependencies: [
                .target(name: "ReleaseInformerBot"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "Configuration", package: "swift-configuration"),
            ]
        )
    ]
)
