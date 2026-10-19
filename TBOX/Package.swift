// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TBOX",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TBOX", targets: ["TBOX"]),
    ],
    targets: [
        .target(
            name: "ArgmaxCore",
            path: "Vendor/ArgmaxOSS/Sources/ArgmaxCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "WhisperKit",
            dependencies: ["ArgmaxCore"],
            path: "Vendor/ArgmaxOSS/Sources/WhisperKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "SpeakerKit",
            dependencies: ["ArgmaxCore", "WhisperKit"],
            path: "Vendor/ArgmaxOSS/Sources/SpeakerKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "TBOX",
            dependencies: ["WhisperKit", "SpeakerKit"],
            path: "TBOX",
            exclude: ["Assets.xcassets", "Resources", "TBOX.entitlements"]
        ),
        .executableTarget(
            name: "TranscribeTest",
            dependencies: ["WhisperKit"],
            path: "Tools/TranscribeTest"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
