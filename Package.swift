// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nanonfs",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "NanoNFS",
            targets: ["NanoNFS"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "NanoNFS",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "Sources/NanoNFS",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "NanoNFSDemo",
            dependencies: [
                "NanoNFS",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/NanoNFSDemo",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "NanoNFSTests",
            dependencies: ["NanoNFS"],
            path: "Tests/NanoNFSTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
