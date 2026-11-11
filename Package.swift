// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FFmpegFreeUI_macOS",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TranscodeCore"),
        .executableTarget(name: "FFmpegFreeUI_macOS", dependencies: ["TranscodeCore"]),
        .testTarget(name: "TranscodeCoreTests", dependencies: ["TranscodeCore", "FFmpegFreeUI_macOS"])
    ]
)
