// swift-tools-version: 6.2

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .unsafeFlags(["-strict-concurrency=complete"]),
]

let package = Package(
    name: "PiSwiftTui",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "PiSwiftCodingAgentTui",
            targets: ["PiSwiftCodingAgentTui"]
        ),
        .executable(
            name: "pi-coding-agent",
            targets: ["PiSwiftCodingAgentCLI"]
        ),
    ],
    dependencies: [
        .package(path: "../PiSwift"),
        .package(path: "../MiniTui"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "PiSwiftCodingAgentTui",
            dependencies: [
                .product(name: "PiSwiftAI", package: "PiSwift"),
                .product(name: "PiSwiftAgent", package: "PiSwift"),
                .product(name: "PiSwiftCodingAgent", package: "PiSwift"),
                .product(name: "PiSwiftSyntaxHighlight", package: "PiSwift"),
                .product(name: "MiniTui", package: "MiniTui"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "PiSwiftCodingAgentCLI",
            dependencies: [
                .product(name: "PiSwiftAI", package: "PiSwift"),
                .product(name: "PiSwiftAgent", package: "PiSwift"),
                .product(name: "PiSwiftCodingAgent", package: "PiSwift"),
                .product(name: "PiReviewExtension", package: "PiSwift"),
                "PiSwiftCodingAgentTui",
                .product(name: "MiniTui", package: "MiniTui"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftCodingAgentTuiTests",
            dependencies: [
                .product(name: "PiSwiftAI", package: "PiSwift"),
                .product(name: "PiSwiftAgent", package: "PiSwift"),
                .product(name: "PiSwiftCodingAgent", package: "PiSwift"),
                "PiSwiftCodingAgentTui",
                "PiSwiftCodingAgentCLI",
                .product(name: "MiniTui", package: "MiniTui"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            // These tests change the process-wide theme and terminal colors.
            // A separate test process keeps them out of live TUI and loader tests.
            name: "PiSwiftCodingAgentTuiTestsSystemTheme",
            dependencies: [
                .product(name: "PiSwiftAI", package: "PiSwift"),
                .product(name: "PiSwiftAgent", package: "PiSwift"),
                .product(name: "PiSwiftCodingAgent", package: "PiSwift"),
                "PiSwiftCodingAgentTui",
                .product(name: "MiniTui", package: "MiniTui"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "PiSwiftCodingAgentCLITests",
            dependencies: [
                .product(name: "PiSwiftAI", package: "PiSwift"),
                .product(name: "PiSwiftCodingAgent", package: "PiSwift"),
                "PiSwiftCodingAgentCLI",
                "PiSwiftCodingAgentTui",
            ],
            swiftSettings: strictConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
