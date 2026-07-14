// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)] // velocity now; strict-concurrency migration is a tracked task

let package = Package(
    name: "PrismStudio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PrismCore", targets: ["PrismCore"]),
        .library(name: "PrismCapture", targets: ["PrismCapture"]),
        .library(name: "PrismScreen", targets: ["PrismScreen"]),
        .library(name: "PrismAudio", targets: ["PrismAudio"]),
        .library(name: "PrismCompositor", targets: ["PrismCompositor"]),
        .library(name: "PrismAnimation", targets: ["PrismAnimation"]),
        .library(name: "PrismColor", targets: ["PrismColor"]),
        .library(name: "PrismVision", targets: ["PrismVision"]),
        .library(name: "PrismSources", targets: ["PrismSources"]),
        .library(name: "PrismExport", targets: ["PrismExport"]),
        .library(name: "PrismControlSurface", targets: ["PrismControlSurface"]),
        .library(name: "PrismProximity", targets: ["PrismProximity"]),
        .library(name: "PrismDirector", targets: ["PrismDirector"]),
        .library(name: "PrismSound", targets: ["PrismSound"]),
        .library(name: "PrismCompose", targets: ["PrismCompose"]),
        .library(name: "PrismOutput", targets: ["PrismOutput"]),
        .library(name: "PrismControl", targets: ["PrismControl"]),
        .library(name: "PrismLink", targets: ["PrismLink"]),
        .library(name: "PrismLinkSender", targets: ["PrismLinkSender"]),
        .library(name: "PrismVirtualCam", targets: ["PrismVirtualCam"]),
        // Phase-0 AR depth spike (isolated prove-or-kill; not production).
        .library(name: "PrismDepthSpike", targets: ["PrismDepthSpike"]),
        .executable(name: "prism-dev", targets: ["prism-dev"]),
        .executable(name: "prism-bench", targets: ["prism-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift", from: "2.0.0"),
    ],
    targets: [
        .target(name: "PrismCore", swiftSettings: v5),
        .target(name: "PrismCapture", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismScreen", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismAudio", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismCompositor", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismAnimation", dependencies: ["PrismCore", "PrismCompositor"], swiftSettings: v5),
        .target(name: "PrismColor", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismVision", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismSources", dependencies: ["PrismCore", "PrismVision", "PrismCompositor"], swiftSettings: v5),
        .target(name: "PrismExport", dependencies: ["PrismCore", "PrismOutput"], swiftSettings: v5),
        .target(name: "PrismControlSurface", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismProximity", dependencies: ["PrismCore", "PrismLink"], swiftSettings: v5),
        .target(name: "PrismDirector", dependencies: ["PrismCore", "PrismVision", "PrismCompositor"], swiftSettings: v5),
        .target(name: "PrismSound", dependencies: ["PrismCore", "PrismAudio"], swiftSettings: v5),
        .target(name: "PrismCompose", dependencies: ["PrismCore", "PrismCompositor"], swiftSettings: v5),
        .target(
            name: "PrismOutput",
            dependencies: [
                "PrismCore",
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift"),
                .product(name: "SRTHaishinKit", package: "HaishinKit.swift"),
            ],
            swiftSettings: v5
        ),
        .target(name: "PrismControl", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismLink", dependencies: ["PrismCore"], swiftSettings: v5),
        .target(name: "PrismLinkSender", dependencies: ["PrismCore", "PrismLink"], swiftSettings: v5),
        .target(name: "PrismVirtualCam", dependencies: ["PrismCore"], exclude: ["README.md"], swiftSettings: v5),
        // Phase-0 AR depth spike: isolated compositing + depth-alignment math on
        // synthetic data. Depends only on PrismCore (PixelBufferPool); touches no
        // production compositor/render-loop source.
        .target(name: "PrismDepthSpike", dependencies: ["PrismCore"], swiftSettings: v5),
        .executableTarget(
            name: "prism-dev",
            dependencies: [
                "PrismCore", "PrismCapture", "PrismScreen", "PrismAudio",
                "PrismCompositor", "PrismAnimation", "PrismColor", "PrismVision", "PrismSources", "PrismExport", "PrismCompose", "PrismControlSurface", "PrismProximity", "PrismDirector", "PrismSound",
                "PrismOutput", "PrismControl", "PrismLink", "PrismLinkSender",
                "PrismVirtualCam",
            ],
            swiftSettings: v5
        ),
        .executableTarget(
            name: "prism-bench",
            dependencies: ["PrismCore", "PrismCompositor", "PrismOutput"],
            swiftSettings: v5
        ),
        .testTarget(name: "PrismCoreTests", dependencies: ["PrismCore"], swiftSettings: v5),
        .testTarget(name: "PrismDepthSpikeTests", dependencies: ["PrismDepthSpike", "PrismCore"], swiftSettings: v5),
        .testTarget(
            name: "PrismSuiteTests",
            dependencies: [
                "PrismCompositor", "PrismAudio", "PrismAnimation", "PrismColor",
                "PrismVision", "PrismSources", "PrismExport", "PrismCompose",
                "PrismOutput", "PrismControlSurface", "PrismControl", "PrismProximity", "PrismDirector", "PrismSound",
                "PrismCapture", "PrismScreen", "PrismLink", "PrismVirtualCam",
            ],
            swiftSettings: v5
        ),
    ]
)
