// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NottyCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "NottyCore", targets: ["NottyCore"])],
    targets: [
        .target(name: "NottyCore"),
        .testTarget(name: "NottyCoreTests", dependencies: ["NottyCore"])
    ]
)
