// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RECache",
    platforms: [
        .iOS(.v13),
        .tvOS(.v13),
    ],
    products: [
        .library(
            name: "RECache",
            targets: ["RECache"]
        ),
    ],
    targets: [
        .target(
            name: "RECache"
        ),
        .testTarget(
            name: "RECacheTests",
            dependencies: ["RECache"]
        ),
    ]
)
