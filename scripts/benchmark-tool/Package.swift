// swift-tools-version:5.9
import PackageDescription

// Standalone macOS-only benchmark harness.
//
// This package intentionally does NOT depend on the WardrobeReDo app target
// — the app is a UIKit/SwiftUI project that can't link on macOS. The tool
// reimplements the Vision-only extraction path (no SAM2) so we can
// iterate over the DeepFashion2 benchmark subset on a dev Mac and emit an
// IoU + latency report that `compare_benchmarks.py` can diff.
//
// SAM2 metrics live in `ExtractionPerformanceTests` (device-only) —
// there's no meaningful way to benchmark the Core ML path from a macOS CLI.

let package = Package(
    name: "benchmark-tool",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "benchmark-tool",
            path: "Sources/benchmark-tool"
        )
    ]
)
