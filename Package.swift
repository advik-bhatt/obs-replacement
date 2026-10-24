// swift-tools-version:5.9
import PackageDescription

// UpstageCore is pure Swift (Foundation only) and builds everywhere, so the
// model, the RTMP/FLV/AMF0 muxer and the obs-websocket protocol are unit-tested
// on Linux CI as well as on macOS. The Upstage app target only exists when the
// manifest is evaluated on macOS, because it imports AppKit, AVFoundation,
// Metal, MetalFX, ScreenCaptureKit, CoreAudio, CoreMIDI and VideoToolbox.

var targets: [Target] = [
    .target(
        name: "UpstageCore",
        path: "Sources/UpstageCore"
    ),
    .testTarget(
        name: "UpstageCoreTests",
        dependencies: ["UpstageCore"],
        path: "Tests/UpstageCoreTests"
    ),
]

var products: [Product] = [
    .library(name: "UpstageCore", targets: ["UpstageCore"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "Upstage",
        dependencies: ["UpstageCore"],
        path: "Sources/Upstage",
        linkerSettings: [
            // Embed Info.plist into the bare executable so `swift run Upstage`
            // (no .app bundle) still carries the camera / microphone usage
            // strings that TCC requires. scripts/bundle.sh builds the real
            // bundle for distribution.
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "\(Context.packageDirectory)/Resources/Info.plist",
            ]),
        ]
    )
)
products.append(.executable(name: "Upstage", targets: ["Upstage"]))
#endif

let package = Package(
    name: "Upstage",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
