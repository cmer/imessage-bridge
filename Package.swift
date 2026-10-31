// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IMessageBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IMessageBridgeApp", targets: ["IMessageBridgeApp"]),
        .executable(name: "imessage-bridge", targets: ["imessage-bridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "BridgeCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "IMessageBridgeApp",
            dependencies: ["BridgeCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(
            name: "imessage-bridge",
            dependencies: ["BridgeCore"]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"]
        ),
    ]
)
