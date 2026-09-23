// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShortcutKey",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MultitouchBridge",
            path: "Sources/MultitouchBridge",
            linkerSettings: [.linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "ShortcutKey",
            dependencies: ["MultitouchBridge"],
            path: "Sources/ShortcutKey"
        ),
    ]
)
