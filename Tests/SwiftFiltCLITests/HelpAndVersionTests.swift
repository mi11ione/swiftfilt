// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// `--help` and `--version`: the product face carries the usage lines, every flag, real examples, and the exit-code table; the version string is single-sourced from `CLI.version`.
@Suite("Help and version")
struct HelpAndVersionTests {
    @Test func helpCarriesUsageEveryFlagAndExitCodes() {
        let run = runCLI(["--help"])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stderr.isEmpty)
        let help = run.stdout
        #expect(help.contains("swiftfilt [options]"))
        #expect(help.contains("<symbol>"))
        #expect(help.contains("swiftfilt census [options]"))
        #expect(help.contains("swiftfilt explain <symbol>"))
        for flag in ["--simplified", "--qualified", "--unqualified", "--tree",
                     "--classify", "--json", "--slim", "--color", "--version", "--help",
                     "--format", "--top", "--type"]
        {
            #expect(help.contains(flag), "\(flag) missing from help")
        }
        #expect(help.contains("exit codes"))
        #expect(help.contains("1  internal error"))
        #expect(help.contains("2  usage error"))
    }

    @Test func helpDocumentsTheProductContracts() {
        let help = runCLI(["-h"]).stdout
        // The load-bearing sentences: symbols-never-paths, byte-safety,
        // streaming, echo semantics, and the -- escape.
        #expect(help.contains("never file paths"))
        #expect(help.contains("the only stream input"))
        #expect(help.contains("byte-for-byte"))
        #expect(help.contains("c++filt"))
        #expect(help.contains("`--`") || help.contains("--` ends option parsing") || help.contains("-- ends option parsing"))
    }

    @Test func helpShowsRealExamples() {
        let help = runCLI(["--help"]).stdout
        #expect(help.contains("crash.log"))
        #expect(help.contains("tail -f"))
        #expect(help.contains("nm "))
        #expect(help.contains("$s4main3fooyyF"))
        #expect(help.contains("jq"))
        #expect(help.contains("swiftfilt explain '$s4main9foo'"))
    }

    @Test func helpMatchesThePublishedConstant() {
        #expect(runCLI(["--help"]).stdout == CLI.helpText)
    }

    @Test func versionIsSingleSourced() {
        let run = runCLI(["--version"])
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout == "swiftfilt \(CLI.version)\n")
        #expect(CLI.version == "1.0.0")
    }

    @Test func helpShowsCensusExamples() {
        let help = runCLI(["--help"]).stdout
        #expect(help.contains("swiftfilt census < LinkMap.txt"))
        #expect(help.contains("| swiftfilt census"))
        #expect(help.contains("census --json < LinkMap.txt | jq"))
    }

    @Test func helpAndVersionNeverReadStdin() {
        var inputCalls = 0
        for arguments in [["--help"], ["--version"]] {
            _ = CLI.run(
                arguments: arguments,
                input: {
                    inputCalls += 1
                    return nil
                },
                writeOutput: { _ in },
                writeError: { _ in },
                standardOutputIsTTY: false,
            )
        }
        #expect(inputCalls == 0)
    }

    @Test func usageErrorsNeverReadStdin() {
        var inputCalls = 0
        let status = CLI.run(
            arguments: ["--slim"],
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
}
