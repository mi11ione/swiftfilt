// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// `swiftfilt --type` — demangle bare type manglings (the `swift-demangle -type` form). Inputs are arguments or stdin lines; output composes with the render styles; a non-type echoes back unchanged; entity-oriented output modes are rejected, not silently ignored.
@Suite("Type mode (--type)")
struct TypeModeCLITests {
    @Test func demanglesTypeArgumentsOnePerLine() {
        let run = runCLI(["--type", "SaySiG", "SiSg", "Si_Sdt"])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stderr.isEmpty)
        #expect(run.stdout == "[Swift.Int]\nSwift.Int?\n(Swift.Int, Swift.Double)\n")
    }

    @Test func composesWithRenderStyles() {
        #expect(runCLI(["--type", "SiSg"]).stdout == "Swift.Int?\n")
        #expect(runCLI(["--type", "--simplified", "SiSg"]).stdout == "Int?\n")
        #expect(runCLI(["--type", "--qualified", "SiSg"]).stdout == "Swift.Optional<Swift.Int>\n")
        #expect(runCLI(["--type", "--qualified", "SaySiG"]).stdout == "Swift.Array<Swift.Int>\n")
    }

    /// A string that is not exactly one valid type echoes back unchanged —
    /// c++filt semantics, never the reference's `<<invalid type>>`.
    @Test(arguments: ["xyz", "$sSi", "_$sSi", "$s4main3fooyyF"])
    func nonTypesEchoUnchanged(_ input: String) {
        let run = runCLI(["--type", input])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == input + "\n")
    }

    @Test func readsTypesFromStandardInputWhenNoArguments() {
        // Empty lines are skipped; a non-type line echoes.
        let run = runCLI(["--type"], stdinText: "SaySiG\n\nSo8NSObjectC\nnothere\n")
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == "[Swift.Int]\n__C.NSObject\nnothere\n")
    }

    @Test func argumentsTakePrecedenceOverStandardInput() {
        // With type arguments present, stdin is not read.
        let run = runCLI(["--type", "Si"], stdinText: "SS\n")
        #expect(run.stdout == "Swift.Int\n")
    }

    @Test func standardInputSplitsAcrossChunkBoundaries() {
        let run = runCLI(["--type"], stdinText: "SaySiG\nSiSg\n", chunkSize: 3)
        #expect(run.stdout == "[Swift.Int]\nSwift.Int?\n")
    }

    @Test func standardInputAcceptsCRLFLineEndings() {
        let run = runCLI(["--type"], stdinText: "SaySiG\r\nSiSg\r\n")
        #expect(run.stdout == "[Swift.Int]\nSwift.Int?\n")
    }

    @Test func standardInputReadsAFinalLineWithoutATrailingNewline() {
        let run = runCLI(["--type"], stdinText: "SaySiG")
        #expect(run.stdout == "[Swift.Int]\n")
    }

    @Test(arguments: [
        ["--type", "--json", "Si"],
        ["--type", "--tree", "Si"],
        ["--type", "--classify", "Si"],
        ["--type", "--jobs", "2", "Si"],
    ])
    func entityOutputModesAreRejected(_ arguments: [String]) {
        let run = runCLI(arguments)
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("--type"))
    }

    @Test func theVerbsDoNotAcceptType() {
        #expect(runCLI(["census", "--type"]).status == CLI.exitUsage)
        #expect(runCLI(["explain", "--type", "Si"]).status == CLI.exitUsage)
    }
}
