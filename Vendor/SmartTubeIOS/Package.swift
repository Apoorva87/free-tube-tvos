// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmartTubeIOS",
    platforms: [.tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "SmartTubeIOSCore", targets: ["SmartTubeIOSCore"])],
    targets: [
        .target(name: "SmartTubeIOSCore"),
        .testTarget(name: "SmartTubeIOSCoreTests", dependencies: ["SmartTubeIOSCore"]),
    ]
)
