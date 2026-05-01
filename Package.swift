// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kith",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kith", targets: ["kith"]),
        .library(name: "ContactsCore", targets: ["ContactsCore"]),
        .library(name: "MessagesCore", targets: ["MessagesCore"]),
        .library(name: "ResolveCore", targets: ["ResolveCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.5"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", from: "4.2.5"),
    ],
    targets: [
        .target(name: "ContactsCore"),
        .target(
            name: "MessagesCore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "ResolveCore",
            dependencies: ["ContactsCore", "MessagesCore"]
        ),
        .executableTarget(
            name: "kith",
            dependencies: [
                "ContactsCore",
                "MessagesCore",
                "ResolveCore",
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
        .testTarget(name: "ResolveCoreTests", dependencies: ["ResolveCore"]),
        .testTarget(name: "kithTests", dependencies: ["kith", "ResolveCore"]),
    ]
)
