// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import SwiftFiltCLICore
import Testing

/// Hostile nesting depth through the CLI seams (arena filter, tree/JSON output, args mode).
/// Below the construction ceiling, deep nesting renders the printer's `<<too complex>>` cap
/// exactly as `swift-demangle` does; past the ceiling the candidate declines and every mode
/// passes the bytes through untouched — never a partial guess (these inputs SIGBUS-crashed the
/// 0.4.0 binary). The capped-render case hosts the CLI on a large stack; decline cases run
/// unaided, since construction-time bounding leaves nothing deep to walk.
@Suite("Deep-input totality")
struct DeepInputTests {
    private func nestedArrays(_ depth: Int, tail: String = "D") -> String {
        "$s" + String(repeating: "Say", count: depth) + "Si"
            + String(repeating: "G", count: depth) + tail
    }

    /// `runCLI` on a dedicated 128 MiB-stack thread — the deep-render
    /// analogue of the library suites' `onLargeStack`.
    private func runCLIOnLargeStack(_ arguments: [String], stdin: [UInt8]) async -> CLIRun {
        await withCheckedContinuation { (continuation: CheckedContinuation<CLIRun, Never>) in
            let thread = Thread { continuation.resume(returning: runCLI(arguments, stdin: stdin)) }
            thread.stackSize = 128 << 20
            thread.start()
        }
    }

    @Test func cappedBandRendersTheReferenceMarkerInFilterMode() async {
        let line = nestedArrays(500) + "\n"
        let expected = String(repeating: "[", count: 383) + "<<too complex>>"
            + String(repeating: "]", count: 383) + "\n"
        let run = await runCLIOnLargeStack([], stdin: Array(line.utf8))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == expected)
        #expect(run.stderr.isEmpty)
    }

    @Test func declinedDeepLineEchoesVerbatimBetweenNeighbors() {
        let deep = nestedArrays(2000)
        let input = "before $s4main3fooyyF\n\(deep)\nafter\n"
        let run = runCLI([], stdin: Array(input.utf8))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == "before main.foo() -> ()\n\(deep)\nafter\n")
    }

    @Test func treeModeSkipsDeclinedDeepCandidates() {
        let run = runCLI(["--tree"], stdin: Array((nestedArrays(2000) + "\n").utf8))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.isEmpty)
    }

    @Test func jsonModeEmitsNoRecordForDeclinedDeepCandidates() {
        let run = runCLI(["--json"], stdin: Array((nestedArrays(2000) + "\n").utf8))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.isEmpty)
    }

    @Test func argsModeEchoesADeclinedDeepSymbol() {
        let deep = nestedArrays(2000)
        let run = runCLI([deep])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == deep + "\n")
    }

    @Test func deepPrefixWithAGarbageTailPassesThrough() {
        let line = nestedArrays(2000, tail: "%%") + "\n"
        let run = runCLI([], stdin: Array(line.utf8))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == line)
    }
}
