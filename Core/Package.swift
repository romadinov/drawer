// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrawerCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "DrawerCore", targets: ["DrawerCore"])],
    targets: [
        .target(name: "DrawerCore"),
        .testTarget(name: "DrawerCoreTests", dependencies: ["DrawerCore"]),
    ]
)
