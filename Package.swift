// swift-tools-version: 6.2
import PackageDescription

// SE-0450 package traits select which TCP transport implementation is built
// into NanoNFS. Baseline dependencies (NIOCore, NIOFoundationCompat,
// Logging, Atomics) are pulled unconditionally — see CLAUDE.md §3 "Trait
// gating" and README.md §2 for the rationale. The xdr / rpc / wire layers
// rely on `NIOCore.ByteBuffer` regardless of trait selection, so gating it
// would leave the encoder uncompilable.

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
    traits: [
        .trait(
            name: "NIO",
            description: "Build the NIOPosix-backed listener (NFSTransport.nio)."
        ),
        .trait(
            name: "BSDSocket",
            description: "Build the pure-Swift-Concurrency BSD socket listener (NFSTransport.bsdSocket)."
        ),
        .default(enabledTraits: ["NIO"]),
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
                // baseline (always pulled, regardless of trait selection)
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
                // NIO-trait only
                .product(name: "NIO", package: "swift-nio",
                         condition: .when(traits: ["NIO"])),
                .product(name: "NIOPosix", package: "swift-nio",
                         condition: .when(traits: ["NIO"])),
            ],
            path: "Sources/NanoNFS",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
                .define("NIO", .when(traits: ["NIO"])),
                .define("BSDSOCKET", .when(traits: ["BSDSocket"])),
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
                .define("NIO", .when(traits: ["NIO"])),
                .define("BSDSOCKET", .when(traits: ["BSDSocket"])),
            ]
        ),
        .testTarget(
            name: "NanoNFSTests",
            dependencies: ["NanoNFS"],
            path: "Tests/NanoNFSTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
                .define("NIO", .when(traits: ["NIO"])),
                .define("BSDSOCKET", .when(traits: ["BSDSocket"])),
            ]
        ),
    ]
)
