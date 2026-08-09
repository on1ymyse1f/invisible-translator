// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClaudePromptTranslator",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "ClaudePromptTranslator",
            targets: ["ClaudePromptTranslator"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ClaudePromptTranslator"
        ),
        .testTarget(
            name: "ClaudePromptTranslatorTests",
            dependencies: ["ClaudePromptTranslator"]
        )
    ]
)
