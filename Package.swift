// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftPipes",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftPipes",
            targets: ["SwiftPipes"]),
        .library(
            name: "SwiftPipesRTC",
            targets: ["SwiftPipesRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ngr-tc/swift-rtc.git", from: "0.7.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftPipes"),
        .target(
            name: "SwiftPipesRTC",
            dependencies: [
                "SwiftPipes",
                .product(name: "RTC", package: "swift-rtc"),
            ]),
        .executableTarget(
            name: "CameraRTPExample",
            dependencies: ["SwiftPipesRTC"]),
        .executableTarget(
            name: "FullRoundTripTest",
            dependencies: ["SwiftPipesRTC"]),
        .executableTarget(
            name: "SimpleH265Test",
            dependencies: ["SwiftPipesRTC"]),
        .testTarget(
            name: "SwiftPipesTests",
            dependencies: ["SwiftPipes"]
        ),
        .testTarget(
            name: "SwiftPipesRTCTests",
            dependencies: ["SwiftPipesRTC"]
        ),
    ]
)