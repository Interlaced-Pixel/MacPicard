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
        .library(
            name: "PicardScripts",
            targets: ["PicardScripts"]
        ),
        .library(
            name: "PicardFingerprint",
            targets: ["PicardFingerprint"]
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
        .target(
            name: "PicardScripts",
            dependencies: ["PicardFoundation"],
            path: "Sources/PicardScripts",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .target(
            name: "PicardFingerprint",
            dependencies: ["PicardMusicBrainz"],
            path: "Sources/PicardFingerprint",
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
        ),
        .testTarget(
            name: "PicardScriptsTests",
            dependencies: ["PicardScripts", "PicardFoundation"],
            path: "Tests/PicardScriptsTests",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        ),
        .testTarget(
            name: "PicardFingerprintTests",
            dependencies: ["PicardFingerprint", "PicardMusicBrainz"],
            path: "Tests/PicardFingerprintTests",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
