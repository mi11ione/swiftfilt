// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import SwiftFiltParityCore
import Testing

/// Totality-battery machinery: the deterministic PRNG and the regression guards for the `AnonymousContext` crash the battery found — one driving the built CLI out of process, one exercising the public API in process.
@Suite("Totality battery")
struct TotalityBatteryTests {
    @Test func splitMix64IsDeterministicAndSeedable() {
        var a = SplitMix64(seed: 0xDEAD_BEEF)
        var b = SplitMix64(seed: 0xDEAD_BEEF)
        var c = SplitMix64(seed: 0xDEAD_BEF0)
        let seqA = (0 ..< 8).map { _ in a.next() }
        let seqB = (0 ..< 8).map { _ in b.next() }
        let seqC = (0 ..< 8).map { _ in c.next() }
        #expect(seqA == seqB, "same seed → identical stream")
        #expect(seqA != seqC, "different seed → different stream")
    }

    @Test func splitMix64BoundedIsInRange() {
        var rng = SplitMix64(seed: 1)
        for _ in 0 ..< 1000 {
            let value = rng.next(below: 37)
            #expect(value >= 0 && value < 37)
        }
        #expect(rng.next(below: 0) == 0, "a zero bound is clamped, never a division trap")
    }

    /// REGRESSION GUARD for the crash the `total` battery found. `$sXZ` used to demangle to an
    /// `AnonymousContext` built from an empty stack (`?? anon` fallbacks) whose printer read
    /// `children[1]` out of range — a SIGTRAP reachable from `demangle()` and every CLI path.
    /// The fix restores apple's null-propagation (malformed input declines). Driven in a SUBPROCESS
    /// so a re-introduced trap can't kill the runner: asserts a clean decline (exit 0, input echoed).
    @Test func malformedAnonymousContextDeclinesCleanlyNeverTraps() throws {
        guard let binary = locateBuiltCLI() else {
            Issue.record("swiftfilt CLI binary not found under .build; build the product to exercise the regression guard")
            return
        }
        for input in ["$sXZ", "_$sXZ3"] {
            let out = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [input]
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(
                process.terminationReason == .exit && process.terminationStatus == 0,
                "`swiftfilt '\(input)'` did not exit cleanly (status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)) — the AnonymousContext crash regressed",
            )
            // c++filt semantics: a non-demangling argument echoes unchanged.
            #expect(String(decoding: data, as: UTF8.self) == input + "\n")
        }
    }

    /// The same fix at the public API (in-process, safe now it no longer traps): every degenerate
    /// `$sX…`/`$sXZ…` input the fuzz battery reaches must return nil or a non-empty string — never
    /// an under-populated tree, never a trap. The oracle declines `$sXZ`, and so must the product.
    @Test func degenerateSpecialTypesAreNilOrValidAtTheAPI() throws {
        for input in ["$sXZ", "_$sXZ", "$sXZ3", "$sXZa", "$sXZ_", "$sXZS", "$sX", "$sXY"] {
            let result = SwiftFilt.demangle(input)
            // nil is fine; a non-nil result must be non-empty — exactly `!= ""`.
            #expect(result != "", "\(input): produced an empty string")
            // The parity contract: demangle(validating:) throws exactly when
            // demangle is nil, and never traps.
            if result == nil {
                #expect(throws: DemangleError.self) { try demangle(validating: input) }
            }
        }
    }

    private func locateBuiltCLI() -> String? {
        let root = repositoryRoot()
        for config in ["release", "debug"] {
            let path = root.appendingPathComponent(".build/\(config)/swiftfilt").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
