// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacPicard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PicardFoundation",
            targets: ["PicardFoundation"]
        ),
        .executable(
            name: "MacPicard",
            targets: ["MacPicard"]
        )
    ],
    targets: [
        .target(
            name: "PicardFoundation",
            path: "Sources/PicardFoundation",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .executableTarget(
            name: "MacPicard",
            dependencies: ["PicardFoundation"],
            path: "Sources/MacPicard",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .testTarget(
            name: "PicardFoundationTests",
            dependencies: ["PicardFoundation"],
            path: "Tests/PicardFoundationTests",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
