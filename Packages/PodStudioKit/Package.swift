// swift-tools-version: 6.0
//
// PodStudioKit — all non-UI logic of PodStudio.
//
//  CLAME          vendored LAME 3.100 encoder (C, LGPL-2.0+), see Sources/CLAME/README.md
//  LAMEKit        Swift wrapper around CLAME (MP3 encoding, M7)
//  StudioCore     platform-independent core: messages (M3), script model, clock sync,
//                 loudness/DSP/mixdown (M6), crash-safe WAV + storage/recovery (M8).
//                 Builds and tests on Linux, too.
//  StudioServices Apple-only services: capture (M4), SharePlay session + messenger (M2/M3),
//                 CloudKit delivery (M5), AVAudioEngine post-production (M6), export (M7).
//  pstool         command line harness: runs the post-production chain on WAV files
//                 (used to verify loudness / export acceptance criteria without a device).
import PackageDescription

let package = Package(
    name: "PodStudioKit",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
        .library(name: "LAMEKit", targets: ["LAMEKit"]),
        .library(name: "StudioServices", targets: ["StudioServices"]),
        .executable(name: "pstool", targets: ["pstool"]),
    ],
    targets: [
        .target(
            name: "CLAME",
            path: "Sources/CLAME",
            exclude: ["COPYING.LGPL", "LICENSE.lame", "README.md"],
            sources: ["libmp3lame"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("libmp3lame"),
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "LAMEKit",
            dependencies: ["CLAME"]
        ),
        .target(
            name: "StudioCore"
        ),
        .target(
            name: "StudioServices",
            dependencies: ["StudioCore", "LAMEKit"],
            // Apple frameworks (AVFoundation, GroupActivities, CloudKit) are not yet fully
            // annotated for strict concurrency; switch to .v6 once it builds warning-free.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pstool",
            dependencies: ["StudioCore", "LAMEKit"]
        ),
        .testTarget(
            name: "StudioCoreTests",
            dependencies: ["StudioCore"]
        ),
        .testTarget(
            name: "LAMEKitTests",
            dependencies: ["LAMEKit", "StudioCore"]
        ),
    ]
)
