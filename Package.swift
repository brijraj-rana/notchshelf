// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notchshelf",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotchshelfCore", targets: ["NotchshelfCore"]),
        .executable(name: "Notchshelf", targets: ["Notchshelf"]),
    ],
    targets: [
        // UI-free shelf: the list of parked files, bookmarks, persistence.
        .target(name: "NotchshelfCore", path: "Sources/NotchshelfCore"),
        // The notch panel.
        .executableTarget(name: "Notchshelf", dependencies: ["NotchshelfCore"], path: "Sources/Notchshelf"),
        .testTarget(name: "NotchshelfCoreTests", dependencies: ["NotchshelfCore"], path: "Tests/NotchshelfCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
