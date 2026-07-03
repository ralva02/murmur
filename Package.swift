// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wisprrr",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "WisprrrCore"),
        .executableTarget(name: "Wisprrr", dependencies: ["WisprrrCore"]),
        .testTarget(name: "WisprrrCoreTests", dependencies: ["WisprrrCore"]),
    ]
)
