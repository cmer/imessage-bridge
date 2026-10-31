// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IMessageBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IMessageBridgeApp", targets: ["IMessageBridgeApp"]),
        .executable(name: "imessage-bridge", targets: ["imessage-bridge"]),
    ],
    targets: [
        .target(
            name: "BridgeCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "IMessageBridgeApp",
            dependencies: ["BridgeCore"]
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
