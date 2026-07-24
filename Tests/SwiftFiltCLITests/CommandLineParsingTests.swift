// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import SwiftFiltCLICore
import Testing

/// The argv grammar: defaults, every flag, the `--` end-of-options marker, and every documented conflict as a usage error — never a silent precedence rule.
@Suite("Command-line parsing")
struct CommandLineParsingTests {
    func parsedInvocation(_ arguments: [String]) -> Invocation? {
        guard case let .run(invocation) = ParsedCommandLine.parse(arguments) else { return nil }
        return invocation
    }

    func usageMessage(_ arguments: [String]) -> String? {
        guard case let .usageError(message) = ParsedCommandLine.parse(arguments) else { return nil }
        return message
    }

    // MARK: Defaults and shapes

    @Test func bareInvocationIsTheFullStyleTextFilter() throws {
        let invocation = try #require(parsedInvocation([]))
        #expect(invocation.symbols.isEmpty)
        #expect(invocation.style == .full)
        #expect(invocation.mode == .text(classify: false))
        #expect(invocation.color == .auto)
    }

    @Test func positionalArgumentsAreSymbolsInOrder() throws {
        let invocation = try #require(parsedInvocation(["$s4main3fooyyF", "notasymbol", "$s4main3fooyyF"]))
        #expect(invocation.symbols == ["$s4main3fooyyF", "notasymbol", "$s4main3fooyyF"])
    }

    @Test func flagsAndSymbolsMixInAnyOrder() throws {
        let invocation = try #require(parsedInvocation(["--simplified", "a", "--color", "never", "b"]))
        #expect(invocation.symbols == ["a", "b"])
        #expect(invocation.style == .simplified)
        #expect(invocation.color == .never)
    }

    @Test func eachStyleFlagSelectsItsPreset() throws {
        #expect(try #require(parsedInvocation(["--simplified"])).style == .simplified)
        #expect(try #require(parsedInvocation(["--qualified"])).style == .qualified)
        #expect(try #require(parsedInvocation(["--unqualified"])).style == .unqualified)
    }

    @Test func outputModeFlagsSelectTheirModes() throws {
        #expect(try #require(parsedInvocation(["--tree"])).mode == .tree)
        #expect(try #require(parsedInvocation(["--classify"])).mode == .text(classify: true))
        #expect(try #require(parsedInvocation(["--json"])).mode == .json(slim: false))
        #expect(try #require(parsedInvocation(["--json", "--slim"])).mode == .json(slim: true))
    }

    @Test func repeatingTheSameStyleFlagIsIdempotent() throws {
        let invocation = try #require(parsedInvocation(["--simplified", "--simplified"]))
        #expect(invocation.style == .simplified)
    }

    @Test func jsonStyleCombinationIsAllowed() throws {
        let invocation = try #require(parsedInvocation(["--json", "--qualified"]))
        #expect(invocation.mode == .json(slim: false))
        #expect(invocation.style == .qualified)
    }

    @Test func classifyStyleCombinationIsAllowed() throws {
        let invocation = try #require(parsedInvocation(["--classify", "--simplified"]))
        #expect(invocation.mode == .text(classify: true))
        #expect(invocation.style == .simplified)
    }

    // MARK: End of options

    @Test func doubleDashEndsOptionParsing() throws {
        let invocation = try #require(parsedInvocation(["--simplified", "--", "--tree", "-h", "--"]))
        #expect(invocation.style == .simplified)
        #expect(invocation.mode == .text(classify: false))
        #expect(invocation.symbols == ["--tree", "-h", "--"])
    }

    @Test func helpAndVersionAfterDoubleDashAreSymbols() throws {
        let helped = try #require(parsedInvocation(["--", "--help"]))
        #expect(helped.symbols == ["--help"])
        let versioned = try #require(parsedInvocation(["--", "--version"]))
        #expect(versioned.symbols == ["--version"])
    }

    // MARK: Globals

    @Test func helpWinsWhereverItAppears() {
        #expect(ParsedCommandLine.parse(["--help"]) == .help)
        #expect(ParsedCommandLine.parse(["-h"]) == .help)
        #expect(ParsedCommandLine.parse(["--json", "sym", "--help"]) == .help)
        // Even alongside an invalid combination: help answers first.
        #expect(ParsedCommandLine.parse(["--simplified", "--qualified", "-h"]) == .help)
    }

    @Test func versionWinsWhereverItAppears() {
        #expect(ParsedCommandLine.parse(["--version"]) == .version)
        #expect(ParsedCommandLine.parse(["--tree", "--version", "sym"]) == .version)
    }

    // MARK: Usage errors

    @Test func conflictingStylesAreAUsageError() throws {
        let message = try #require(usageMessage(["--simplified", "--qualified"]))
        #expect(message.contains("--simplified") && message.contains("--qualified"))
        #expect(message.contains("mutually exclusive"))
        #expect(usageMessage(["--unqualified", "--simplified"]) != nil)
        #expect(usageMessage(["--qualified", "--unqualified"]) != nil)
    }

    @Test func treeConflictsAreUsageErrors() throws {
        #expect(try #require(usageMessage(["--tree", "--json"])).contains("--tree"))
        #expect(try #require(usageMessage(["--tree", "--classify"])).contains("--classify"))
        #expect(try #require(usageMessage(["--tree", "--simplified"])).contains("--simplified"))
    }

    @Test func classifyWithJSONIsAUsageError() throws {
        let message = try #require(usageMessage(["--classify", "--json"]))
        #expect(message.contains("--classify") && message.contains("--json"))
    }

    @Test func slimWithoutJSONIsAUsageError() throws {
        let message = try #require(usageMessage(["--slim"]))
        #expect(message.contains("--slim") && message.contains("--json"))
    }

    @Test func unknownOptionIsAUsageError() throws {
        let message = try #require(usageMessage(["--frobnicate"]))
        #expect(message.contains("--frobnicate"))
        #expect(message.contains("--"), "the message should point at the -- escape hatch")
        #expect(usageMessage(["-x"]) != nil)
        #expect(usageMessage(["-"]) != nil)
    }

    @Test func colorValueIsValidated() throws {
        #expect(try #require(parsedInvocation(["--color", "always"])).color == .always)
        #expect(try #require(parsedInvocation(["--color", "never"])).color == .never)
        #expect(try #require(parsedInvocation(["--color", "auto"])).color == .auto)
        #expect(try #require(usageMessage(["--color"])).contains("--color"))
        #expect(try #require(usageMessage(["--color", "sometimes"])).contains("sometimes"))
    }

    @Test func colorValueIsNeverMistakenForASymbol() throws {
        let invocation = try #require(parsedInvocation(["--color", "never", "never"]))
        #expect(invocation.symbols == ["never"])
        #expect(invocation.color == .never)
    }

    @Test func jobsValueIsValidated() throws {
        #expect(try #require(parsedInvocation([])).jobs == nil)
        #expect(try #require(parsedInvocation(["--jobs", "1"])).jobs == 1)
        #expect(try #require(parsedInvocation(["--jobs", "8"])).jobs == 8)
        #expect(try #require(usageMessage(["--jobs"])).contains("--jobs"))
        #expect(try #require(usageMessage(["--jobs", "0"])).contains("0"))
        #expect(try #require(usageMessage(["--jobs", "-2"])).contains("-2"))
        #expect(try #require(usageMessage(["--jobs", "many"])).contains("many"))
    }

    @Test func jobsWithProvenanceModesIsAUsageError() throws {
        #expect(try #require(usageMessage(["--jobs", "4", "--tree"])).contains("--tree"))
        #expect(try #require(usageMessage(["--json", "--jobs", "4"])).contains("--json"))
        // --classify rewrites in place, so it parallelizes like plain text.
        #expect(try #require(parsedInvocation(["--jobs", "4", "--classify"])).jobs == 4)
    }

    @Test func jobsAppliesToCensus() {
        // Census parallelizes the per-row demangle over a large bare/nm
        // listing, so --jobs is accepted; the byte output is identical
        // at every thread count. (Detailed --jobs grammar lives in the census
        // command-line suite.)
        #expect(ParsedCommandLine.parse(["census", "--jobs", "4"]) == .census(CensusInvocation(jobs: 4)))
    }

    // MARK: Exit codes through the runner

    @Test func usageErrorsExitTwoAndWriteOnlyToStderr() {
        let run = runCLI(["--simplified", "--qualified"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stdoutBytes.isEmpty)
        #expect(run.stderr.contains("swiftfilt: error:"))
        #expect(run.stderr.contains("run 'swiftfilt --help' for usage"))
    }

    @Test func successPathsExitZero() {
        #expect(runCLI(["notasymbol"]).status == CLI.exitSuccess)
        #expect(runCLI([], stdinText: "no symbols\n").status == CLI.exitSuccess)
        #expect(runCLI(["--help"]).status == CLI.exitSuccess)
        #expect(runCLI(["--version"]).status == CLI.exitSuccess)
    }

    @Test func exitCodeConstantsAreTheDocumentedValues() {
        #expect(CLI.exitSuccess == 0)
        #expect(CLI.exitUsage == 2)
    }
}
