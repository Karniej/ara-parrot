// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ara",
    platforms: [.macOS(.v14)],
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
        // SPIKE, test target only. Parakeet TDT v3 on the Neural Engine, to be
        // measured against the Whisper path before anything ships on it — see
        // `ParakeetBenchmark`. Nothing in AraCore links this, so the daemon is
        // unchanged and the dependency can be removed by deleting two lines.
        // Zero transitive dependencies of its own, and the same macOS 14 floor.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
    ],
    targets: [
        // The portable engine: cleanup, vocabulary, modes, the session. No
        // dependencies at all, and that is the point — this is the target
        // something small links, where every dependency is paid inside a
        // memory budget measured in tens of megabytes rather than gigabytes.
        // Foundation only, forever.
        .target(name: "AraEngine"),
        .target(
            name: "AraCore",
            dependencies: [
                "AraEngine",
                // Still here because the CLI command types (Install, Setup,
                // Doctor) live in this library — a macOS-only concern.
                // AraEngine has no dependencies at all; that is the boundary
                // that matters, and it is why the split exists.
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
        .testTarget(
            name: "AraCoreTests",
            dependencies: [
                "AraCore", "AraEngine",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]),
    ]
)
