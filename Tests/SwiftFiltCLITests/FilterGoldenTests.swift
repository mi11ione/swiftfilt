// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import SwiftFiltCLICore
import Testing

/// Filter mode against locked goldens built from real material (crash log, `nm`, linker error, ANSI build log; every symbol a real corpus symbol). The plain rewrite is also held byte-equal to the library's `demangleAll` — the CLI adds wiring, never its own demangling opinion.
@Suite("Filter-mode goldens")
struct FilterGoldenTests {
    @Test func crashLogRewritesToGolden() {
        let run = runCLI([], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == golden("crash-log.full.txt"))
        #expect(run.stderr.isEmpty)
    }

    @Test func crashLogSimplifiedMatchesGolden() {
        let run = runCLI(["--simplified"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        #expect(run.stdout == golden("crash-log.simplified.txt"))
    }

    @Test func crashLogClassifyMatchesGolden() {
        let run = runCLI(["--classify"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        #expect(run.stdout == golden("crash-log.classify.txt"))
    }

    @Test func crashLogTreesMatchGolden() {
        let run = runCLI(["--tree"], stdin: fixtureBytes(cliInputPath("crash-log.txt")))
        #expect(run.stdout == golden("crash-log.tree.txt"))
    }

    @Test func nmOutputRewritesToGolden() {
        let run = runCLI([], stdin: fixtureBytes(cliInputPath("nm-output.txt")))
        #expect(run.stdout == golden("nm-output.full.txt"))
    }

    @Test func linkerErrorRewritesToGolden() {
        let run = runCLI([], stdin: fixtureBytes(cliInputPath("linker-error.txt")))
        #expect(run.stdout == golden("linker-error.full.txt"))
    }

    @Test func ansiBuildLogRewritesToGoldenPreservingEscapes() {
        let input = fixtureBytes(cliInputPath("ansi-build-log.txt"))
        #expect(input.contains(0x1B), "the fixture must carry real escape bytes")
        let run = runCLI([], stdin: input)
        #expect(run.stdout == golden("ansi-build-log.full.txt"))
        #expect(run.stdoutBytes.contains(0x1B), "input escapes pass through")
    }

    @Test func goldensCarryTheCorpusLockedRenderings() {
        // The goldens are grounded in the engine's corpus fixtures: the
        // exact `swift-demangle` renderings corpus.tsv locks must appear.
        let full = golden("crash-log.full.txt")
        #expect(full.contains("AppIntents.AppIntentsXPCError.errorCode.getter : Swift.Int"))
        #expect(full.contains("generic specialization <Swift.Int> of main.foo() -> ()"))
        #expect(full.contains("@objc foo.bar.bas(zim: foo.zim) -> ()"))
        #expect(full.contains(
            "protocol witness for call_protocol.P.foo() -> Swift.Int in conformance call_protocol.C : call_protocol.P in call_protocol",
        ))
        #expect(full.contains("merged abc.testit(Swift.Int) -> ()"))
        #expect(!full.contains("$s4main3fooyyFSi_Tg5"), "no mangled name survives the rewrite")
    }

    // MARK: The CLI rewrite is the library rewrite

    @Test func plainFilterEqualsLibraryDemangleAllOnEveryFixture() {
        for fixture in ["crash-log.txt", "nm-output.txt", "linker-error.txt", "ansi-build-log.txt"] {
            let input = fixtureBytes(cliInputPath(fixture))
            for (flags, style) in [([String](), DemangleStyle.full), (["--simplified"], .simplified),
                                   (["--qualified"], .qualified), (["--unqualified"], .unqualified)]
            {
                let run = runCLI(flags, stdin: input)
                let library = MangledNameScanner().demangleAll(inBytes: input, style: style)
                #expect(run.stdoutBytes == library, "\(fixture) \(flags) diverges from the library filter")
            }
        }
    }

    // MARK: Framing edges

    @Test func emptyInputProducesNoOutput() {
        let run = runCLI([], stdin: [])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdoutBytes.isEmpty)
        #expect(run.outputCalls == 0)
    }

    @Test func finalLineWithoutNewlineStaysWithoutNewline() {
        let run = runCLI([], stdinText: "tail frame $s4main3fooyyF")
        #expect(run.stdout == "tail frame main.foo() -> ()")
    }

    @Test func newlineOnlyInputRoundTrips() {
        #expect(runCLI([], stdinText: "\n\n\n").stdout == "\n\n\n")
    }

    @Test func crlfLineEndingsSurvive() {
        // `\r` is not a mangling character: the symbol never swallows it
        // and the terminator round-trips.
        let run = runCLI([], stdinText: "frame $s4main3fooyyF\r\nnext\r\n")
        #expect(run.stdout == "frame main.foo() -> ()\r\nnext\r\n")
    }

    @Test func chunkBoundariesNeverChangeTheOutput() {
        // Byte-at-a-time delivery must produce the identical stream: no
        // symbol is ever split by framing.
        let input = fixtureBytes(cliInputPath("crash-log.txt"))
        let whole = runCLI([], stdin: input)
        for size in [1, 2, 3, 7, 64, 4096] {
            let chunked = runCLI([], stdin: input, chunkSize: size)
            #expect(chunked.stdoutBytes == whole.stdoutBytes, "chunk size \(size) diverged")
        }
    }

    @Test func longLinesRewriteInPlace() {
        // A 512 KiB single line with the symbol deep inside: still one
        // line out, still rewritten (well under the window cap; the
        // over-cap behavior has its own suite).
        let padding = String(repeating: "x", count: 256 << 10)
        let line = padding + " $s4main3fooyyF " + padding + "\n"
        let run = runCLI([], stdinText: line, chunkSize: 64 << 10)
        #expect(run.stdout == padding + " main.foo() -> () " + padding + "\n")
    }

    @Test func multipleMatchesOnOneLineAllRewrite() {
        let run = runCLI([], stdinText: "$s4main3fooyyF and _$s4main6ServerC5start4portySi_tF\n")
        #expect(run.stdout == "main.foo() -> () and main.Server.start(port: Swift.Int) -> ()\n")
    }

    @Test func matchesRenderingEmptyInTheSelectedStyleKeepTheirBytes() {
        // `$ss` (the bare Swift module) demangles but renders empty in
        // .simplified — `swift-demangle -simplified` echoes it too. The
        // filter keeps the original bytes rather than deleting the match,
        // in plain and classify rewrites alike; the validating full style
        // rewrites it.
        #expect(runCLI(["--simplified"], stdinText: "x $ss y\n").stdout == "x $ss y\n")
        #expect(runCLI(["--simplified", "--classify"], stdinText: "x $ss y\n").stdout == "x $ss y\n")
        #expect(runCLI([], stdinText: "x $ss y\n").stdout == "x Swift y\n")
    }
}
