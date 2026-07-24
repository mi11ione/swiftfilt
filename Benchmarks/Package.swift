// swift-tools-version: 6.0
// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The benchmark harness — its OWN SwiftPM package, deliberately
// outside the root package's target graph so the published SwiftFilt
// package keeps zero dependencies (the comparison contender below is
// pinned in THIS package's Package.resolved, never the root's).
// Depends on the library by relative path; build and run from this
// directory:
//
//     swift run -c release swiftfilt-bench            # full battery
//     swift run -c release swiftfilt-bench card       # the benchmark card
//     swift run -c release swiftfilt-bench smoke --baseline baseline.json

import PackageDescription

let package = Package(
    name: "swiftfilt-benchmarks",
    // ContinuousClock is everywhere the library builds; macOS 13 floors
    // the Apple side for Swift Concurrency + Clock. The deployment floor
    // here is the HARNESS's, not the library's.
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: ".."),
        // Comparison contender for the benchmark card — bench-only, never
        // a dependency of the published SwiftFilt package. Revision-pinned
        // (the repo publishes no version tags) so the card's numbers name
        // an exact contender.
        .package(url: "https://github.com/mattgallagher/CwlDemangle", revision: "6bfc351bd08d7a1805234b9ba698f8381d2df08e"),
    ],
    targets: [
        .executableTarget(
            name: "swiftfilt-bench",
            dependencies: [
                .product(name: "SwiftFilt", package: "swiftfilt"),
                .product(name: "CwlDemangle", package: "CwlDemangle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
    ],
)
