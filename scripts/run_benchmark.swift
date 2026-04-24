#!/usr/bin/env swift
// Convenience entry point. The actual tool is a SwiftPM package at
// `scripts/benchmark-tool/` — see its Package.swift and Sources/main.swift
// for the implementation.
//
// Run via one of:
//
//   cd scripts/benchmark-tool && swift run -c release benchmark-tool
//   swift run --package-path scripts/benchmark-tool -c release benchmark-tool
//
// We keep this shim because the project plan referenced `scripts/run_benchmark.swift`
// directly; pointing contributors at the package spares them the "where is the tool?"
// search.

import Foundation

let packagePath = "scripts/benchmark-tool"
let process = Process()
process.launchPath = "/usr/bin/env"
process.arguments = ["swift", "run", "--package-path", packagePath, "-c", "release", "benchmark-tool"]
do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("Failed to launch benchmark-tool: \(error)\n".utf8))
    exit(2)
}
