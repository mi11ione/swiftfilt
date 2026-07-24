// swift-tools-version: 6.0
// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import PackageDescription

let package = Package(
    name: "SwiftFilt",
    // The SwiftFilt library imports nothing and builds on any platform Swift
    // supports (Linux/Windows/Android are unaffected by this Apple-only floor).
    // The floor exists for the dev-only swiftfilt-parity tool, whose Foundation
    // and Swift Concurrency APIs (isolation-parametered TaskGroup,
    // FileHandle.read(upToCount:)) carry macOS availability; without it SwiftPM
    // defaults the deployment target below that on CI.
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SwiftFilt",
            targets: ["SwiftFilt"],
        ),
        .executable(
            name: "swiftfilt",
            targets: ["swiftfilt-cli"],
        ),
    ],
    targets: [
        .target(
            name: "SwiftFilt",
            // The DocC catalog builds through `docc convert` (no plugin);
            // excluded here so source builds stay warning-free.
            exclude: ["SwiftFilt.docc"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        // CLI logic lives in a non-product library target so it is
        // unit-testable end to end with injected stdio; it is deliberately
        // NOT public API of the package.
        .target(
            name: "SwiftFiltCLICore",
            dependencies: ["SwiftFilt"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .executableTarget(
            name: "swiftfilt-cli",
            dependencies: ["SwiftFilt", "SwiftFiltCLICore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        // The in-repo trust instrument (never a published product): parity
        // logic lives in a non-product library target so its table parsing,
        // matcher semantics, and gating behavior are unit-testable; the
        // executable below is a thin entry point over it.
        .target(
            name: "SwiftFiltParityCore",
            dependencies: ["SwiftFilt", "SwiftFiltCLICore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .executableTarget(
            name: "swiftfilt-parity",
            dependencies: ["SwiftFiltParityCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "SwiftFiltTests",
            dependencies: ["SwiftFilt"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "SwiftFiltCLITests",
            dependencies: ["SwiftFiltCLICore", "SwiftFilt"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "SwiftFiltParityTests",
            dependencies: ["SwiftFiltParityCore", "SwiftFilt"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
    ],
)
