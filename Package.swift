// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kith",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kith",       targets: ["kith"]),
        .executable(name: "kith-agent", targets: ["KithAgent"]),
        .library(name: "ContactsCore",       targets: ["ContactsCore"]),
        .library(name: "MessagesCore",       targets: ["MessagesCore"]),
        .library(name: "ResolveCore",        targets: ["ResolveCore"]),
        .library(name: "KithAgentProtocol",  targets: ["KithAgentProtocol"]),
        .library(name: "KithAgentClient",    targets: ["KithAgentClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git",  from: "0.15.5"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git",   from: "4.2.5"),
        .package(url: "https://github.com/trilemma-dev/SecureXPC.git",     from: "0.8.0"),
    ],
    targets: [
        .target(name: "ContactsCore"),
        .target(
            name: "MessagesCore",
            dependencies: [
                .product(name: "SQLite",         package: "SQLite.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "ResolveCore",
            dependencies: ["ContactsCore", "MessagesCore"]
        ),
        // Wire-protocol types + XPCRoute definitions shared between the
        // agent (server) and the CLI (client). No platform deps; just
        // SecureXPC for the route helpers.
        .target(
            name: "KithAgentProtocol",
            dependencies: [
                "ContactsCore",
                .product(name: "SecureXPC", package: "SecureXPC"),
            ]
        ),
        // Long-lived daemon (LaunchAgent in v0.2.0 production layout).
        // ResolveCore brings the `KithPhoneNumberNormalizer: PhoneNumberNormalizing`
        // conformance the agent needs to wire `CNBackedContactsStore`.
        .executableTarget(
            name: "KithAgent",
            dependencies: [
                "KithAgentProtocol",
                "ContactsCore",
                "MessagesCore",
                "ResolveCore",
                .product(name: "SecureXPC", package: "SecureXPC"),
            ]
        ),
        // Thin client the CLI uses to talk to the agent over Mach service.
        .target(
            name: "KithAgentClient",
            dependencies: [
                "KithAgentProtocol",
                "ContactsCore",
                .product(name: "SecureXPC", package: "SecureXPC"),
            ]
        ),
        .executableTarget(
            name: "kith",
            dependencies: [
                "ContactsCore",
                "MessagesCore",
                "ResolveCore",
                "KithAgentClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/kith/Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "ContactsCoreTests", dependencies: ["ContactsCore"]),
        .testTarget(name: "MessagesCoreTests", dependencies: ["MessagesCore"]),
        .testTarget(name: "ResolveCoreTests",  dependencies: ["ResolveCore"]),
        .testTarget(name: "kithTests",         dependencies: ["kith", "ResolveCore"]),
    ]
)
