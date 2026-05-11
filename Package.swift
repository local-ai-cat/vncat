// swift-tools-version: 6.0
//
// RoyalVNCKitUI — iOS rendering and input layer for RoyalVNCKit.
//
// Wraps royalapplications/RoyalVNCKit (cross-platform VNC protocol +
// macOS framebuffer view) with a UIViewController + CALayer-based
// iOS renderer, gesture handling, modifier keys, paste flow, loading
// overlay, and an optional perf HUD.
//

import PackageDescription

let package = Package(
    name: "RoyalVNCKitUI",
    platforms: [
        .iOS(.v15),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "RoyalVNCKitUI",
            targets: ["RoyalVNCKitUI"]
        )
    ],
    dependencies: [
        .package(path: "royalvnc")
    ],
    targets: [
        .target(
            name: "RoyalVNCKitUI",
            dependencies: [
                .product(name: "RoyalVNCKit", package: "royalvnc")
            ],
            path: "Sources/RoyalVNCKitUI"
        )
    ]
)
