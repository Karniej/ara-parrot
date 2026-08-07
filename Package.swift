// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ara",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
        // Already in the graph — WhisperKit 0.18 pins it — but named here because
        // mlx-swift-lm 3.x deliberately dropped its own HuggingFace dependency:
        // `Downloader` and `TokenizerLoader` are now protocols with no
        // implementations in the package, so a caller must supply both. The range
        // is WhisperKit's, so this adds no new resolution.
        .package(url: "https://github.com/huggingface/swift-transformers.git", "1.1.0" ..< "2.0.0"),
    ],
    targets: [
        // The portable engine: cleanup, vocabulary, modes, the session. No
        // dependencies at all — this is the target an iOS keyboard extension
        // links, and every dependency it grows is paid inside a ~30-48 MB
        // memory budget. Foundation only, forever.
        .target(name: "AraEngine"),
        .target(
            name: "AraCore",
            dependencies: [
                "AraEngine",
                // Still here because the CLI command types (Install, Setup,
                // Doctor) live in this library — a macOS-only concern.
                // AraEngine, the target an iOS extension links, has no
                // dependencies at all; that is the boundary that matters.
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "ara",
            dependencies: [
                "AraCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AraCoreTests", dependencies: ["AraCore", "AraEngine"]),
    ]
)
