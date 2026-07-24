// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The `explain` verb end to end: argv parsing, the human report for each
// outcome (demangled anatomy, the malformed diagnosis, the not-Swift
// hand-off), the NDJSON schema, and the locked goldens.

import SwiftFilt
import SwiftFiltCLICore
import Testing

/// The curated argument set the `explain` goldens are generated from — one per outcome branch,
/// kept beside the goldens so regeneration and this list never drift.
private let explainGoldenSet = [
    "$s4main6ServerC5start4portySi_tF", // demangled function
    "$s4main3fooyyFSi_Tg5", // demangled specialization (flags, origin)
    "_TtC4main3Foo", // demangled legacy type
    "$s4main9foo", // malformed: truncated identifier
    "$s6modern10fetchThi", // malformed: truncated (multi-digit length)
    "$sXXXXXXXX", // malformed: stray byte
    "$s", // malformed: empty body
    "$s4main3fooyyF trailing junk", // malformed: stray byte + embedded name
    "$s4main6ServerC5start4portySi_tX", // malformed: unfinished production
    "_Z3fooiii", // not Swift: C++
    "_RNvNtC7mycrate3foo3bar", // not Swift: Rust
    "hello_world", // not Swift: plain
]

@Suite("Explain goldens")
struct ExplainGoldenTests {
    @Test func humanReportMatchesTheGolden() {
        let run = runCLI(["explain"] + explainGoldenSet)
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stderr.isEmpty)
        #expect(run.stdout == golden("explain.txt"))
    }

    @Test func jsonReportMatchesTheGolden() {
        let run = runCLI(["explain", "--json"] + explainGoldenSet)
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == golden("explain.ndjson"))
        // Every line is one self-contained object.
        for line in run.stdout.split(separator: "\n") {
            #expect(line.hasPrefix("{\"schemaVersion\":1,\"kind\":\"explain\""))
            #expect(line.hasSuffix("}"))
        }
    }
}

@Suite("Explain argument parsing")
struct ExplainParsingTests {
    @Test func explainVerbSelectsTheExplainInvocation() {
        #expect(ParsedCommandLine.parse(["explain", "$sFoo"]) == .explain(ExplainInvocation(symbols: ["$sFoo"])))
        #expect(ParsedCommandLine.parse(["explain", "--json", "a"]) == .explain(ExplainInvocation(symbols: ["a"], json: true)))
        #expect(ParsedCommandLine.parse(["explain", "--json", "--slim", "a"]) == .explain(ExplainInvocation(symbols: ["a"], json: true, slim: true)))
        #expect(ParsedCommandLine.parse(["explain", "--color", "never", "a"]) == .explain(ExplainInvocation(symbols: ["a"], color: .never)))
    }

    @Test func doubleDashEndsOptionsSoDashSymbolsSurvive() {
        #expect(ParsedCommandLine.parse(["explain", "--", "-x", "census"]) == .explain(ExplainInvocation(symbols: ["-x", "census"])))
    }

    @Test func noSymbolsIsValidAndReadsStandardInput() {
        // No symbol arguments is not an error: explain then reads stdin, one
        // symbol per line. The parse succeeds with an empty symbol list; the
        // stdin behavior itself is covered by ExplainFromStandardInputTests.
        #expect(ParsedCommandLine.parse(["explain"]) == .explain(ExplainInvocation(symbols: [])))
        #expect(ParsedCommandLine.parse(["explain", "--json"]) == .explain(ExplainInvocation(symbols: [], json: true)))
    }

    @Test func filterAndCensusFlagsAreRejected() {
        for flag in ["--simplified", "--qualified", "--unqualified", "--tree", "--classify"] {
            expectUsageError(["explain", flag, "a"], contains: "does not apply to explain")
        }
        for flag in ["--jobs", "--format", "--top"] {
            expectUsageError(["explain", flag, "2", "a"], contains: "does not apply to explain")
        }
    }

    @Test func malformedOptionsAreUsageErrors() {
        expectUsageError(["explain", "--slim", "a"], contains: "--slim shapes --json")
        expectUsageError(["explain", "-x", "a"], contains: "unknown explain option")
        expectUsageError(["explain", "--color"], contains: "--color needs a value")
        expectUsageError(["explain", "--color", "chartreuse", "a"], contains: "unknown color mode")
    }

    private func expectUsageError(_ arguments: [String], contains needle: String) {
        guard case let .usageError(message) = ParsedCommandLine.parse(arguments) else {
            Issue.record("expected a usage error for \(arguments)")
            return
        }
        #expect(message.contains(needle), "message was: \(message)")
    }
}

@Suite("Explain human report branches")
struct ExplainHumanReportTests {
    private func explain(_ argument: String, color: String? = nil) -> String {
        var args = ["explain"]
        if let color { args += ["--color", color] }
        return runCLI(args + [argument]).stdout
    }

    @Test func demangledFlagsCoverEveryCompilerArtifact() {
        #expect(explain("$s4main3FooV3baryyFZ").contains("flags        static"))
        #expect(explain("$s4main3fooyyFTj").contains("flags        thunk, compiler-generated"))
        #expect(explain("$s4main3fooyyFSi_Tg5").contains("flags        specialized"))
        #expect(explain("$s4main3FooVMn").contains("flags        compiler-generated"))
    }

    @Test func aModuleLessSymbolOmitsTheModuleAndPathLines() {
        // A reabstraction thunk carries only signatures — no module, no path.
        let report = explain("$sIeg_Ieg_TR")
        #expect(report.contains("kind         thunk.reabstraction"))
        #expect(!report.contains("\n  module "))
        #expect(!report.contains("\n  path "))
    }

    @Test func aSuffixIsSurfaced() {
        #expect(explain("$s4main3fooyyF.cold.1").contains("suffix       .cold.1"))
    }

    @Test func aSigilLessNameIsRestoredWithANote() {
        let report = explain("s4main3fooyyF")
        #expect(report.contains("note         read as $-prefixed"))
        #expect(report.contains("main.foo() -> ()"))
    }

    @Test func everyMalformedReasonHasItsSentence() {
        #expect(explain("$s4main9foo").contains("declares 9 bytes but only 3 remain"))
        #expect(explain("$s5").contains("implausibly large length, far past the 0 bytes"))
        #expect(explain("$s9x").contains("far past the 1 byte remaining"), "singular byte")
        #expect(explain("$s").contains("only a mangling prefix"))
        #expect(explain("$s4main6ServerC5start4portySi_tX").contains("ends mid-symbol"))
        #expect(explain("$sXXXXXXXX").contains("unexpected byte 'X'"))
        // A legacy failure has no cursor, so no byte position is claimed.
        let legacy = explain("_TtC4main3Fo")
        #expect(legacy.contains("legacy _T grammar could not parse"))
        #expect(!legacy.contains("stopped at byte"))
    }

    @Test func strayControlAndNonASCIIBytesAreNamedByValue() {
        #expect(explain("$s\u{1b}zz").contains("unexpected byte 0x1b"))
        let emoji = explain("$s4main\u{1F600}yyF")
        #expect(emoji.contains("raw non-ASCII byte"))
        #expect(emoji.contains("punycode"))
    }

    @Test func embeddedNamesAreListedAndRendered() {
        let report = explain("$s4main3fooyyF trailing junk")
        #expect(report.contains("contains     1 complete Swift name"))
        #expect(report.contains("$s4main3fooyyF  →  main.foo() -> ()"))
        #expect(report.contains("extract embedded names with the filter"))

        // Two glued names read as the plural, both rendered.
        let two = explain("$s4main3fooyyF x $s4main3baryyF")
        #expect(two.contains("contains     2 complete Swift names"))
        #expect(two.contains("$s4main3baryyF  →  main.bar() -> ()"))
    }

    @Test func notSwiftNamesGetAHandOffHintOrGenericAdvice() {
        #expect(explain("_Z3fooiii").contains("looks like   C++ (Itanium _Z) — try c++filt"))
        #expect(explain("_Z3fooiii").contains("_Z3fooiii | c++filt"))
        #expect(explain("_RNvNtC7mycrate3foo3bar").contains("try rustfilt"))
        #expect(explain("hello_world").contains("hand it to another demangler"))
    }

    @Test func colorAlwaysBoldsTheHeader() {
        let report = explain("$s4main3fooyyF", color: "always")
        #expect(report.contains("\u{1B}[1m$s4main3fooyyF\u{1B}[0m"))
    }
}

@Suite("Explain JSON report branches")
struct ExplainJSONReportTests {
    private func json(_ argument: String, slim: Bool = false) -> String {
        runCLI(["explain", "--json"] + (slim ? ["--slim"] : []) + [argument]).stdout
    }

    @Test func demangledRecordCarriesTheCuratedFields() {
        let record = json("$s4main6ServerC5start4portySi_tF")
        #expect(record.contains("\"status\":\"demangled\""))
        #expect(record.contains("\"era\":\"stableABI\""))
        #expect(record.contains("\"symbolKind\":\"function\""))
        #expect(record.contains("\"module\":\"main\""))
        #expect(record.contains("\"path\":[\"Server\",\"start\"]"))
        #expect(record.contains("\"identityKey\":\"main.Server.start(port: Swift.Int) -> ()\""))
    }

    @Test func aModuleLessRecordOmitsTheModuleKey() {
        #expect(!json("$sIeg_Ieg_TR").contains("\"module\""))
    }

    @Test func malformedRecordsCarryTheReasonAndItsFields() {
        #expect(json("$s4main9foo").contains("\"reason\":\"truncatedIdentifier\",\"declaredLength\":9,\"availableBytes\":3"))
        #expect(json("$sXXXXXXXX").contains("\"reason\":\"unexpectedByte\",\"byte\":88"))
        #expect(json("$s").contains("\"reason\":\"emptyBody\""))
        #expect(json("$s4main6ServerC5start4portySi_tX").contains("\"reason\":\"incompleteInput\""))
        #expect(json("_TtC4main3Fo").contains("\"reason\":\"unparseable\""))
        #expect(json("$s4main3fooyyF trailing junk").contains("\"embeddedSymbols\":[\"$s4main3fooyyF\"]"))
    }

    @Test func notSwiftRecordsCarryTheForeignHintWhenKnown() {
        #expect(json("_Z3fooiii").contains("\"status\":\"notSwiftMangled\",\"foreign\":\"cxxItanium\""))
        #expect(json("_RNvNtC7mycrate3foo3bar").contains("\"foreign\":\"rust\""))
        #expect(!json("hello_world").contains("\"foreign\""))
    }

    @Test func slimDropsTheConstantSchemaVersion() {
        let slim = json("$s4main9foo", slim: true)
        #expect(!slim.contains("schemaVersion"))
        #expect(slim.hasPrefix("{\"kind\":\"explain\""))
    }
}
