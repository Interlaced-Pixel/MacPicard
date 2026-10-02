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
        .library(
            name: "PicardFormats",
            targets: ["PicardFormats"]
        ),
        .library(
            name: "PicardMusicBrainz",
            targets: ["PicardMusicBrainz"]
        ),
        .executable(
            name: "MacPicard",
            targets: ["MacPicard"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/jeonghi/TagLibSwift.git",
            revision: "a36e48f43a4cea1fd41baa0c90acdb6f35444800"
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
            dependencies: ["PicardFoundation", "PicardFormats"],
            path: "Sources/MacPicard",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .target(
            name: "PicardFormats",
            dependencies: [
                "PicardFoundation",
                .product(name: "TagLibSwift", package: "TagLibSwift")
            ],
            path: "Sources/PicardFormats",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .target(
            name: "PicardMusicBrainz",
            dependencies: ["PicardFoundation"],
            path: "Sources/PicardMusicBrainz",
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
        ),
        .testTarget(
            name: "PicardFormatsTests",
            dependencies: ["PicardFormats"],
            path: "Tests/PicardFormatsTests",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .testTarget(
            name: "PicardMusicBrainzTests",
            dependencies: ["PicardMusicBrainz", "PicardFoundation"],
            path: "Tests/PicardMusicBrainzTests",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
