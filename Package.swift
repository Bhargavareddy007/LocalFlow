// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .executableTarget(
            name: "LocalFlow",
            dependencies: ["CWhisper"],
            path: "Sources/LocalFlow",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-L/opt/homebrew/opt/llama.cpp/lib"]),
                .linkedLibrary("whisper"),
                .linkedLibrary("parakeet"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml"),
                .linkedLibrary("llama"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
