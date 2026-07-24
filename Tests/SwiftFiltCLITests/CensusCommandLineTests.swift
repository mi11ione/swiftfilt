// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// The census verb's command-line grammar: verb recognition (first argument exactly), its flags, and every conflict rejected with a message that names the problem — no flag silently ignored.
@Suite("Census command line")
struct CensusCommandLineTests {
    @Test func censusFirstArgumentSelectsTheVerb() {
        #expect(ParsedCommandLine.parse(["census"]) == .census(CensusInvocation()))
    }

    @Test func censusFlagsParse() {
        #expect(ParsedCommandLine.parse(["census", "--format", "linkmap", "--top", "25", "--json", "--slim", "--color", "never"])
            == .census(CensusInvocation(format: .linkmap, top: 25, json: true, slim: true, color: .never)))
        #expect(ParsedCommandLine.parse(["census", "--format", "bare"])
            == .census(CensusInvocation(format: .bare)))
        #expect(ParsedCommandLine.parse(["census", "--format", "nm"])
            == .census(CensusInvocation(format: .nm)))
    }

    @Test func censusJobsParses() {
        #expect(ParsedCommandLine.parse(["census", "--jobs", "4"])
            == .census(CensusInvocation(jobs: 4)))
        #expect(ParsedCommandLine.parse(["census", "--jobs", "1"])
            == .census(CensusInvocation(jobs: 1)))
    }

    @Test func censusJobsNeedsAValue() {
        guard case let .usageError(message) = ParsedCommandLine.parse(["census", "--jobs"]) else {
            Issue.record("--jobs with no value must be a usage error")
            return
        }
        #expect(message.contains("--jobs needs a value"))
    }

    @Test func censusJobsRejectsNonPositiveOrNonNumericValues() {
        for bad in ["0", "-2", "many", ""] {
            guard case let .usageError(message) = ParsedCommandLine.parse(["census", "--jobs", bad]) else {
                Issue.record("--jobs \(bad) must be a usage error")
                return
            }
            #expect(message.contains("--jobs expects a positive thread count"))
        }
    }

    @Test func censusLaterInArgvStaysASymbol() {
        // Verb position is load-bearing: a later bare word is a symbol
        // argument (and echoes, c++filt semantics).
        let parsed = ParsedCommandLine.parse(["--simplified", "census"])
        #expect(parsed == .run(Invocation(symbols: ["census"], style: .simplified)))
        let run = runCLI(["--", "census"])
        #expect(run.stdout == "census\n")
    }

    @Test func doubleDashForcesCensusToBeASymbol() {
        #expect(ParsedCommandLine.parse(["--", "census"]) == .run(Invocation(symbols: ["census"])))
    }

    @Test func censusRejectsPositionalArguments() {
        for arguments in [["census", "LinkMap.txt"], ["census", "--", "LinkMap.txt"]] {
            let run = runCLI(arguments)
            #expect(run.status == CLI.exitUsage)
            #expect(run.stderr.contains("census reads standard input and takes no arguments (got 'LinkMap.txt')"))
        }
    }

    @Test func censusBareDoubleDashIsHarmless() {
        #expect(ParsedCommandLine.parse(["census", "--"]) == .census(CensusInvocation()))
    }

    @Test func censusRejectsStyleAndOutputFlags() {
        for flag in ["--simplified", "--qualified", "--unqualified"] {
            let run = runCLI(["census", flag])
            #expect(run.status == CLI.exitUsage)
            #expect(run.stderr.contains("\(flag) does not apply to census"))
        }
        for flag in ["--tree", "--classify"] {
            let run = runCLI(["census", flag])
            #expect(run.status == CLI.exitUsage)
            #expect(run.stderr.contains("\(flag) does not apply to census"))
        }
    }

    @Test func censusFormatValidation() {
        var run = runCLI(["census", "--format"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("--format needs a value"))
        run = runCLI(["census", "--format", "elf"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("unknown census format 'elf'"))
    }

    @Test func censusTopValidation() {
        var run = runCLI(["census", "--top"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("--top needs a value"))
        for bad in ["0", "-3", "ten"] {
            run = runCLI(["census", "--top", bad])
            #expect(run.status == CLI.exitUsage)
            #expect(run.stderr.contains("--top expects a positive row count, not '\(bad)'"))
        }
    }

    @Test func censusColorValidation() {
        var run = runCLI(["census", "--color"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("--color needs a value"))
        run = runCLI(["census", "--color", "sometimes"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("unknown color mode 'sometimes'"))
    }

    @Test func censusSlimRequiresJson() {
        let run = runCLI(["census", "--slim"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("--slim shapes --json output"))
    }

    @Test func censusUnknownOptionIsRejected() {
        let run = runCLI(["census", "--verbose"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("unknown census option '--verbose'"))
    }

    @Test func censusOnlyFlagsAreNamedOutsideCensus() {
        for flag in ["--format", "--top"] {
            let run = runCLI([flag, "nm"])
            #expect(run.status == CLI.exitUsage)
            #expect(run.stderr.contains("\(flag) applies to the census verb"))
        }
    }

    @Test func censusHelpAndVersionGlobalsStillWin() {
        #expect(ParsedCommandLine.parse(["census", "--help"]) == .help)
        #expect(ParsedCommandLine.parse(["census", "--version"]) == .version)
        #expect(ParsedCommandLine.parse(["census", "-h"]) == .help)
    }

    @Test func censusUsageErrorsNeverReadStdin() {
        var inputCalls = 0
        let status = CLI.run(
            arguments: ["census", "--top", "0"],
            input: {
                inputCalls += 1
                return nil
            },
            writeOutput: { _ in },
            writeError: { _ in },
            standardOutputIsTTY: false,
        )
        #expect(status == CLI.exitUsage)
        #expect(inputCalls == 0)
    }

    @Test func censusDrainsAllInputChunks() {
        // The runner must consume the injected source to end of input.
        let text = "0000000104ac0340 T _main\n"
        let run = runCLI(["census", "--json"], stdinText: text, chunkSize: 3)
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.contains("\"rows\":1"))
    }

    @Test func emptyStdinYieldsAnEmptyBareCensus() {
        let run = runCLI(["census"])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.contains("census — bare text, count-weighted"))
        #expect(run.stdout.contains("detected: empty input"))
        #expect(run.stdout.contains("(no swift symbols)"))
    }
}
