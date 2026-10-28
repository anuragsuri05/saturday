// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Saturday",
    platforms: [.macOS(.v14)],
    targets: [
        // Runtime bridge to sherpa-onnx's Kokoro voice (the library itself is downloaded on first use).
        .target(name: "CSherpa", path: "Sources/CSherpa", exclude: ["vendor"]),
        .executableTarget(name: "Saturday", dependencies: ["CSherpa"], path: "Sources/Saturday"),
    ]
)
