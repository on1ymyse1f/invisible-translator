// swift-tools-version: 6.0

import PackageDescription

let includeOptionalRuntime = Context.environment["CPT_INCLUDE_OPTIONAL_RUNTIME"] == "1"

let package = Package(
    name: "ClaudePromptTranslator",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "ClaudePromptTranslator",
            targets: ["ClaudePromptTranslator"]
        ),
        .executable(
            name: "ClaudePromptTranslatorNativeHost",
            targets: ["ClaudePromptTranslatorNativeHost"]
        )
    ],
    dependencies: includeOptionalRuntime ? [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.0.0")
    ] : [],
    targets: [
        .executableTarget(
            name: "ClaudePromptTranslator",
            dependencies: includeOptionalRuntime ? [
                "BrowserNativeBridgeShared",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ] : ["BrowserNativeBridgeShared"],
            swiftSettings: [
                .unsafeFlags(["-Osize"], .when(configuration: .release))
            ]
        ),
        .target(
            name: "BrowserNativeBridgeShared",
            swiftSettings: [
                .unsafeFlags(["-Osize"], .when(configuration: .release))
            ]
        ),
        .executableTarget(
            name: "ClaudePromptTranslatorNativeHost",
            dependencies: ["BrowserNativeBridgeShared"],
            swiftSettings: [
                .unsafeFlags(["-Osize"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "ClaudePromptTranslatorTests",
            dependencies: ["ClaudePromptTranslator"]
        )
    ]
)
