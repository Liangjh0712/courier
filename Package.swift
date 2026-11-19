// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Courier",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CourierKit", path: "Sources/CourierKit"),
        .executableTarget(name: "Courier", dependencies: ["CourierKit"], path: "Sources/Courier"),
        .testTarget(name: "CourierKitTests", dependencies: ["CourierKit"], path: "Tests/CourierKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
