// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrameSheet",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "FrameSheet", targets: ["FrameSheet"]),
        .library(name: "FrameSheetCore", targets: ["FrameSheetCore"]),
    ],
    targets: [
        // Pure logic and decoding: no SwiftUI or AppKit.
        .target(
            name: "FrameSheetCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FrameSheet",
            dependencies: ["FrameSheetCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FrameSheetCoreTests",
            dependencies: ["FrameSheetCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
