// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDevPilot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Core library: Models, Store, Services (used by both app and server)
        .target(
            name: "Core",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Core"
        ),
        // Server library: HTTP server with Hummingbird
        .target(
            name: "Server",
            dependencies: [
                "Core",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Server"
        ),
        // Main executable
        .executableTarget(
            name: "AgentDevPilot",
            dependencies: [
                "Core",
                "Server",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/App",
            exclude: ["Info.plist", "Resources/AppIcon.icns"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/App/Info.plist",
                ]),
            ]
        ),
        // Tests for core functionality
        .testTarget(
            name: "AgentDevPilotTests",
            dependencies: [
                "Core",
                "AgentDevPilot",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests",
            exclude: ["ServerTests"]
        ),
        // Tests for HTTP server
        .testTarget(
            name: "ServerTests",
            dependencies: [
                "Server",
                "Core",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/ServerTests"
        ),
    ]
)
