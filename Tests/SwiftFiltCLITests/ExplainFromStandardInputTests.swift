// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// `swiftfilt explain` with no arguments reads symbols from stdin, one per line (the `nm | grep | swiftfilt explain` shape), diagnosing each exactly as an argument; arguments, when present, take precedence and stdin is left unread.
@Suite("Explain from standard input")
struct ExplainFromStandardInputTests {
    private func jsonLines(_ stdout: String) -> [String] {
        stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test func explainsEachStdinLineAsASymbol() {
        let run = runCLI(["explain"], stdinText: "$s4main3fooyyF\n$s4main9foo\n")
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stderr.isEmpty)
        // First symbol demangles; second is a truncated malformed name.
        #expect(run.stdout.contains("$s4main3fooyyF"))
        #expect(run.stdout.contains("status       demangled"))
        #expect(run.stdout.contains("full         main.foo() -> ()"))
        #expect(run.stdout.contains("status       malformed"))
    }

    @Test func jsonEmitsOneRecordPerStdinLine() {
        let run = runCLI(["explain", "--json"], stdinText: "$s4main3fooyyF\n_Z3fooi\n")
        #expect(run.status == CLI.exitSuccess)
        let lines = jsonLines(run.stdout)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"status\":\"demangled\""))
        #expect(lines[0].contains("\"mangled\":\"$s4main3fooyyF\""))
        #expect(lines[1].contains("\"status\":\"notSwiftMangled\""))
        #expect(lines[1].contains("\"foreign\":\"cxxItanium\""))
    }

    @Test func emptyLinesAreSkipped() {
        let run = runCLI(["explain", "--json"], stdinText: "$s4main3fooyyF\n\n\n$s4main9foo\n")
        #expect(jsonLines(run.stdout).count == 2)
    }

    @Test func handlesInputSplitAcrossChunkBoundaries() {
        let run = runCLI(["explain", "--json"], stdinText: "$s4main3fooyyF\n$s4main9foo\n", chunkSize: 4)
        #expect(jsonLines(run.stdout).count == 2)
    }

    @Test func argumentsTakePrecedenceAndStdinIsUnread() {
        let run = runCLI(["explain", "$s4main3fooyyF"], stdinText: "$s4main9foo\n")
        // Only the argument is explained; the stdin symbol never appears.
        #expect(run.stdout.contains("$s4main3fooyyF"))
        #expect(!run.stdout.contains("$s4main9foo"))
        #expect(!run.stdout.contains("status       malformed"))
    }

    @Test func noArgumentsAndEmptyInputProducesNothing() {
        let run = runCLI(["explain"], stdinText: "")
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.isEmpty)
    }

    @Test func jsonRespectsSlimAcrossStdin() {
        let run = runCLI(["explain", "--json", "--slim"], stdinText: "$s4main3fooyyF\n")
        let lines = jsonLines(run.stdout)
        #expect(lines.count == 1)
        // --slim drops the constant schemaVersion/kind envelope fields.
        #expect(!lines[0].contains("\"schemaVersion\""))
        #expect(lines[0].contains("\"status\":\"demangled\""))
    }
}
