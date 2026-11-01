// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "spike",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "spike",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
