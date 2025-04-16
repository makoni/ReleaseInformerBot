// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReleaseInformerBot",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.1"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/nerzh/swift-telegram-sdk.git", .upToNextMajor(from: "3.8.0")),
        .package(url: "https://github.com/makoni/couchdb-swift.git", from: "2.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ReleaseInformerBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SwiftTelegramSdk", package: "swift-telegram-sdk"),
                .product(name: "CouchDBClient", package: "couchdb-swift"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ReleaseInformerBotTests",
            dependencies: [
                .target(name: "ReleaseInformerBot"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
