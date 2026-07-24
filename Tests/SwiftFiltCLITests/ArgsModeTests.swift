// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import SwiftFiltCLICore
import Testing

/// Symbol-args mode: one line per argument, echo-through for non-symbols (c++filt semantics), the four styles, classify markers, and tree blocks; expected strings are corpus-locked.
@Suite("Symbol-args mode")
struct ArgsModeTests {
    @Test func eachArgumentDemanglesOntoItsOwnLine() {
        let run = runCLI(["$s4main3fooyyF", "$s10AppIntents0aB8XPCErrorO9errorCodeSivg"])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == """
        main.foo() -> ()
        AppIntents.AppIntentsXPCError.errorCode.getter : Swift.Int

        """)
    }

    @Test func nonDemanglingArgumentsEchoUnchanged() {
        // c++filt semantics: junk, a C++ mangling, and a bare Swift prefix
        // all echo unchanged, and echoing is success.
        let echoes = runCLI(["notasymbol", "_ZN3fooEv", "$s"])
        #expect(echoes.stdout == "notasymbol\n_ZN3fooEv\n$s\n")
        #expect(echoes.status == CLI.exitSuccess)
        #expect(echoes.stderr.isEmpty)
    }

    @Test func mixedSymbolsAndJunkKeepArgumentOrder() {
        let run = runCLI(["notasymbol", "$s4main3fooyyF", "junk2"])
        #expect(run.stdout == "notasymbol\nmain.foo() -> ()\njunk2\n")
    }

    @Test func emptyArgumentEchoesAsEmptyLine() {
        #expect(runCLI([""]).stdout == "\n")
    }

    @Test func doubleDashPassesDashSymbolsThrough() {
        let run = runCLI(["--", "-notaflag"])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == "-notaflag\n")
    }

    @Test func stdinIsNeverReadInArgsMode() {
        // The input closure must not be called: arguments are always
        // symbols, never paths, and never a reason to consume the pipe.
        var inputCalls = 0
        let status = CLI.run(
            arguments: ["$s4main3fooyyF"],
            input: {
                inputCalls += 1
                return nil
            },
            writeOutput: { _ in },
            writeError: { _ in },
            standardOutputIsTTY: false,
        )
        #expect(status == CLI.exitSuccess)
        #expect(inputCalls == 0)
    }

    // MARK: Styles

    @Test func stylesRenderTheCorpusLockedForms() {
        let symbol = "$s4main6ServerC5start4portySi_tF"
        #expect(runCLI([symbol]).stdout == "main.Server.start(port: Swift.Int) -> ()\n")
        #expect(runCLI(["--simplified", symbol]).stdout == "Server.start(port:)\n")
        #expect(runCLI(["--qualified", symbol]).stdout == "main.Server.start(port: Swift.Int) -> ()\n")
        // Unqualified drops every context, the type included: leaf name
        // plus sugared signature.
        #expect(runCLI(["--unqualified", symbol]).stdout == "start(port: Int) -> ()\n")
    }

    @Test func styleMatchesTheLibraryRenderingForEveryStyle() {
        // The CLI line is exactly the product API's rendering.
        let symbol = "$s7Testing4JSONO6decode_4fromxxm_SWtKSeRzlFZxyKXEfU_"
        for (flags, style) in [([String](), DemangleStyle.full), (["--simplified"], .simplified),
                               (["--qualified"], .qualified), (["--unqualified"], .unqualified)]
        {
            let expected = SwiftFilt.demangle(symbol, style: style)
            #expect(runCLI(flags + [symbol]).stdout == (expected ?? symbol) + "\n")
        }
    }

    // MARK: Classify

    @Test func classifyPrefixesTheSwiftDemangleMarkers() {
        // Shapes pinned against `swift-demangle -classify` (see the
        // oracle suite for the live cross-check): thunk-with-target,
        // witness (target underivable: `{T:}`), plain symbol (no
        // marker), non-symbol (`{N}` before the echo).
        let run = runCLI([
            "--classify",
            "_$s3foo3barC3bas3zimyAaEC_tFTo",
            "_T013call_protocol1CCAA1PA2aDP3fooSiyFTW",
            "$s4main3fooyyF",
            "notasymbol",
        ])
        #expect(run.stdout == """
        {T:_$s3foo3barC3bas3zimyAaEC_tF,C} @objc foo.bar.bas(zim: foo.zim) -> ()
        {T:} protocol witness for call_protocol.P.foo() -> Swift.Int in conformance call_protocol.C : call_protocol.P in call_protocol
        main.foo() -> ()
        {N} notasymbol

        """)
    }

    @Test func classifyComposesWithStyles() {
        let run = runCLI(["--classify", "--simplified", "_$s3foo3barC3bas3zimyAaEC_tFTo"])
        #expect(run.stdout == "{T:_$s3foo3barC3bas3zimyAaEC_tF,C} @objc bar.bas(zim:)\n")
    }

    @Test func classifyStripsOneMachOUnderscoreBeforeMarkers() {
        // `swift-demangle` de-underscores a `__…` argument BEFORE classifying
        // (swift-demangle.cpp `demangle()`), so a Mach-O `__T…` name never earns a
        // spurious `{N}` — the markers come from its `_T…` body. Pinned by
        // swiftfilt-parity's 13M-corpus run.
        let run = runCLI(["--classify", "__TMQualityOfServiceKey"])
        #expect(run.stdout == "type metadata for some with unmangled suffix \"alityOfServiceKey\"\n")
        // A doubled-underscore thunk keeps its thunk markers.
        let thunk = runCLI(["--classify", "__T03foo3barC3basyAA3zimCAE_tFTo"])
        #expect(thunk.stdout.hasPrefix("{T:"), "markers computed on the de-underscored body: \(thunk.stdout)")
    }

    // MARK: Tree

    @Test func treeBlockMatchesTheEngineDumpWithHeaderAndSeparator() {
        let run = runCLI(["--tree", "$s4main3fooyyF"])
        let tree = SwiftDemangler().demangle(symbol: "$s4main3fooyyF")
        #expect(run.stdout == "Demangling for $s4main3fooyyF\n" + (tree?.treeDump() ?? "") + "\n")
    }

    @Test func treeOfNonDemanglingArgumentEchoes() {
        // Documented divergence from swift-demangle's `<<NULL>>`
        // placeholder: c++filt echo semantics extend to trees.
        let run = runCLI(["--tree", "notasymbol", "$s4main3fooyyF"])
        #expect(run.stdout.hasPrefix("notasymbol\nDemangling for $s4main3fooyyF\n"))
        #expect(run.status == CLI.exitSuccess)
    }

    @Test func treeHandlesEveryFixtureSymbol() {
        // Every crash-log fixture symbol produces a headered block ending
        // with the blank separator.
        let symbols = [
            "$s10AppIntents0aB8XPCErrorO9errorCodeSivg",
            "$s7Testing4JSONO6decode_4fromxxm_SWtKSeRzlFZxyKXEfU_",
            "$s4main3fooyyFSi_Tg5",
            "_$s3foo3barC3bas3zimyAaEC_tFTo",
            "_T013call_protocol1CCAA1PA2aDP3fooSiyFTW",
            "_T03abc6testitySiFTm",
        ]
        let run = runCLI(["--tree"] + symbols)
        for symbol in symbols {
            #expect(run.stdout.contains("Demangling for \(symbol)\nkind=Global\n"))
        }
        #expect(run.stdout.hasSuffix("\n\n"))
    }

    // MARK: Sigil-less arguments (swift-demangle's convenience, mirrored)

    @Test func bareSigilLessManglingDemangles() {
        // Verified against `swift-demangle` 2026-07-24: `s…`/`S…`/`e…`
        // forms retry with `$` restored; everything else echoes.
        #expect(runCLI(["s4main3fooyyF"]).stdout == "main.foo() -> ()\n")
        #expect(runCLI(["S4main3fooyyF"]).stdout == "main.foo() -> ()\n")
        #expect(runCLI(["sSi"]).stdout == "Swift.Int\n")
        #expect(runCLI(["4main3fooyyF"]).stdout == "4main3fooyyF\n")
        #expect(runCLI(["T04main3fooyyF"]).stdout == "T04main3fooyyF\n")
    }

    @Test func sigilLessTwinFlowsIntoJSONAndTree() {
        // The record and tree carry the form that demangled — the twin —
        // while echoes always keep the user's own bytes.
        let json = runCLI(["--json", "s4main3fooyyF"])
        #expect(json.stdout.contains("\"mangled\":\"$s4main3fooyyF\""))
        let tree = runCLI(["--tree", "s4main3fooyyF"])
        #expect(tree.stdout.hasPrefix("Demangling for $s4main3fooyyF\n"))
    }

    @Test func filterModeNeverAppliesTheSigilLessRetry() {
        // The scanner requires a real prefix: embedded sigil-less text
        // passes through, exactly as swift-demangle's filter does.
        let run = runCLI([], stdin: Array("x s4main3fooyyF y\n".utf8))
        #expect(run.stdout == "x s4main3fooyyF y\n")
    }

    // MARK: File-path arguments earn a hint (stdout stays c++filt-pure)

    @Test func fileNamedByAnArgumentHintsOnStderr() {
        let run = runCLI(["crash.log"], fileExists: { $0 == "crash.log" })
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == "crash.log\n", "stdout stays pure c++filt echo")
        #expect(run.stderr.contains("names a file"))
        #expect(run.stderr.contains("swiftfilt < crash.log"))
    }

    @Test func demanglingArgumentsNeverProbeTheFileSystem() {
        var probed = false
        let run = runCLI(["$s4main3fooyyF"], fileExists: { _ in probed = true; return true })
        #expect(run.stdout == "main.foo() -> ()\n")
        #expect(run.stderr.isEmpty)
        #expect(!probed, "a demangling argument needs no existence probe")
    }

    @Test func fileProbeDefaultsToOffForEmbedders() {
        // The public entry's default probe answers false: embedders that
        // never wire a filesystem get pure c++filt behavior, no hint.
        var out: [UInt8] = []
        var err = ""
        let status = CLI.run(
            arguments: ["definitely-a-file.txt"],
            input: { nil },
            writeOutput: { out.append(contentsOf: $0) },
            writeError: { err += $0 },
            standardOutputIsTTY: false,
        )
        #expect(status == CLI.exitSuccess)
        #expect(String(decoding: out, as: UTF8.self) == "definitely-a-file.txt\n")
        #expect(err.isEmpty)
    }
}
