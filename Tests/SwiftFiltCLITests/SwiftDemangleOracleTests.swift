// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The live external oracle: the same fixtures through this CLI and the toolchain's
// `swift-demangle`, compared byte for byte. The engine already holds corpus parity;
// this suite proves the CLI wiring (scanning, framing, replacement, tree shape) adds no
// divergence. Runs only when a toolchain is present — skipped via a visible `.enabled(if:)`.

import Foundation
import SwiftFiltCLICore
import Testing

/// Locates `swift-demangle` once; absence disables (and records as
/// skipped) every test in the suite.
enum SwiftDemangleOracle {
    /// The tool path from `xcrun -f swift-demangle`, or `nil` when no
    /// toolchain is installed.
    static let path: String? = {
        guard let output = try? run("/usr/bin/xcrun", ["-f", "swift-demangle"], stdin: []) else { return nil }
        let candidate = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }()

    static var available: Bool {
        path != nil
    }

    /// Run a tool to completion, returning stdout bytes; throws on any
    /// spawn failure or nonzero exit. Uses the shared EPIPE-safe runner.
    static func run(_ toolPath: String, _ arguments: [String], stdin: [UInt8]) throws -> [UInt8] {
        let (status, out) = try runTool(toolPath, arguments, stdin: stdin)
        struct OracleFailed: Error {}
        guard status == 0 else { throw OracleFailed() }
        return out
    }

    /// The oracle's stdin-filter output for `input`.
    static func filter(_ input: [UInt8], flags: [String] = []) throws -> [UInt8] {
        struct OracleMissing: Error {}
        guard let path else { throw OracleMissing() }
        return try run(path, flags, stdin: input)
    }
}

/// CLI-vs-`swift-demangle` parity over the checked-in fixtures.
@Suite("swift-demangle oracle parity", .enabled(if: SwiftDemangleOracle.available))
struct SwiftDemangleOracleTests {
    @Test(arguments: ["crash-log.txt", "nm-output.txt", "linker-error.txt", "ansi-build-log.txt"])
    func filterMatchesOracleByteForByte(fixture: String) throws {
        let input = fixtureBytes(cliInputPath(fixture))
        let oracle = try SwiftDemangleOracle.filter(input)
        let mine = runCLI([], stdin: input)
        #expect(mine.stdoutBytes == oracle, "\(fixture): CLI diverges from swift-demangle")
    }

    @Test func simplifiedFilterMatchesOracle() throws {
        let input = fixtureBytes(cliInputPath("crash-log.txt"))
        let oracle = try SwiftDemangleOracle.filter(input, flags: ["-simplified"])
        #expect(runCLI(["--simplified"], stdin: input).stdoutBytes == oracle)
    }

    @Test func noSugarFilterMatchesOracle() throws {
        let input = fixtureBytes(cliInputPath("crash-log.txt"))
        let oracle = try SwiftDemangleOracle.filter(input, flags: ["-no-sugar"])
        #expect(runCLI(["--qualified"], stdin: input).stdoutBytes == oracle)
    }

    @Test func argsTreesMatchOracleTreeOnly() throws {
        // `swiftfilt --tree <sym>` is byte-identical to
        // `swift-demangle -tree-only <sym>` for every fixture symbol.
        let symbols = [
            "$s10AppIntents0aB8XPCErrorO9errorCodeSivg",
            "$s7Testing4JSONO6decode_4fromxxm_SWtKSeRzlFZxyKXEfU_",
            "$s4main3fooyyFSi_Tg5",
            "_$s3foo3barC3bas3zimyAaEC_tFTo",
            "_T013call_protocol1CCAA1PA2aDP3fooSiyFTW",
            "_T03abc6testitySiFTm",
        ]
        for symbol in symbols {
            let oracle = try SwiftDemangleOracle.filter([], flags: ["-tree-only", symbol])
            let mine = runCLI(["--tree", symbol])
            #expect(mine.stdoutBytes == oracle, "tree for \(symbol) diverges")
        }
    }

    @Test func argsClassifyMatchesOracleMarkers() throws {
        // Oracle args mode prints `mangled ---> {markers} demangled`; our
        // args mode is the c++filt line `{markers} demangled`. Strip the
        // oracle's echo prefix and the lines must be identical.
        let symbols = [
            "_$s3foo3barC3bas3zimyAaEC_tFTo",
            "_T013call_protocol1CCAA1PA2aDP3fooSiyFTW",
            "_T03abc6testitySiFTm",
            "$s10AppIntents0aB8XPCErrorO9errorCodeSivg",
            "notasymbol",
        ]
        let oracle = try SwiftDemangleOracle.filter([], flags: ["-classify"] + symbols)
        let oracleLines = String(decoding: oracle, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let arrow = line.range(of: " ---> ") else { return String(line) }
                return String(line[arrow.upperBound...])
            }
        let mine = runCLI(["--classify"] + symbols).stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(mine == oracleLines, "classify lines diverge from the oracle")
    }

    @Test func oracleLocationIsRecorded() throws {
        // Makes the oracle's identity visible in the test log — and, when
        // the suite is skipped, this test's absence in the results is the
        // recorded evidence the toolchain was missing.
        let path = try #require(SwiftDemangleOracle.path)
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }
}
