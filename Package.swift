// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChatSlaughter",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ChatSlaughter", targets: ["ChatSlaughter"])],
    targets: [
        .target(name: "ChatSlaughterCore"),
        .executableTarget(name: "ChatSlaughter", dependencies: ["ChatSlaughterCore"]),
        .testTarget(name: "ChatSlaughterCoreTests", dependencies: ["ChatSlaughterCore"])
    ]
)
