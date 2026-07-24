// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The opt-in decline record on the --json stream (symbol-args mode): --include-declines turns
// a symbol argument that doesn't demangle from silence into a kind:"decline" object carrying
// explain's diagnosis, so a --json batch reports which arguments failed and why. The default
// stream is unchanged, and the flag's boundaries (needs --json, needs symbol arguments) are named.

import SwiftFiltCLICore
import Testing

@Suite("JSON decline records")
struct JSONDeclineRecordTests {
    private func lines(_ run: CLIRun) -> [String] {
        run.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: The record content

    @Test func declineRecordCarriesTheMalformedDiagnosisForATruncatedSymbol() throws {
        // A frame truncated in a log column: the record is the explain
        // diagnosis, tagged kind:"decline", with the parse stop position and
        // the truncated-identifier reason a boolean flag could not carry.
        let run = runCLI(["--json", "--include-declines", "$s4main9foo"])
        #expect(run.status == CLI.exitSuccess)
        let record = try #require(lines(run).first)
        #expect(record.contains("\"kind\":\"decline\""))
        #expect(record.contains("\"mangled\":\"$s4main9foo\""))
        #expect(record.contains("\"status\":\"malformed\""))
        #expect(record.contains("\"era\":\"stableABI\""))
        #expect(record.contains("\"reason\":\"truncatedIdentifier\""))
        #expect(record.contains("\"stoppedAtByteOffset\":"))
    }

    @Test func declineRecordMarksANonSwiftNameNotSwiftMangled() throws {
        let run = runCLI(["--json", "--include-declines", "plain_c_name"])
        let record = try #require(lines(run).first)
        #expect(record.contains("\"kind\":\"decline\""))
        #expect(record.contains("\"status\":\"notSwiftMangled\""))
    }

    @Test func declineRecordNamesAKnownForeignScheme() throws {
        // A C++ Itanium name is not Swift, but the diagnosis names the scheme
        // to hand it to — the same foreign field explain emits.
        let run = runCLI(["--json", "--include-declines", "_Z3foov"])
        let record = try #require(lines(run).first)
        #expect(record.contains("\"status\":\"notSwiftMangled\""))
        #expect(record.contains("\"foreign\":\"cxxItanium\""))
    }

    // MARK: Batch partial-failure — the point of the flag

    @Test func aBatchInterleavesSymbolAndDeclineRecordsInOrder() {
        let run = runCLI(["--json", "--include-declines", "$s4main3fooyyF", "$s4main9foo", "plain_c_name"])
        let recorded = lines(run)
        #expect(recorded.count == 3)
        #expect(recorded[0].contains("\"mangled\":\"$s4main3fooyyF\"") && recorded[0].contains("\"demangled\":\"main.foo() -> ()\""))
        #expect(recorded[0].contains("\"kind\":\"function\"")) // a symbol record, not a decline
        #expect(recorded[1].contains("\"kind\":\"decline\""))
        #expect(recorded[2].contains("\"kind\":\"decline\""))
    }

    // MARK: The default stream is unchanged

    @Test func withoutTheFlagDeclinesAreStillSilentlyOmitted() {
        let run = runCLI(["--json", "$s4main3fooyyF", "$s4main9foo", "plain_c_name"])
        let recorded = lines(run)
        #expect(recorded.count == 1) // only the one that demangles
        #expect(recorded[0].contains("\"mangled\":\"$s4main3fooyyF\""))
        #expect(!run.stdout.contains("decline"))
    }

    // MARK: --slim projection

    @Test func slimDeclineRecordDropsOnlyTheConstantSchemaVersion() throws {
        let full = runCLI(["--json", "--include-declines", "$s4main9foo"])
        let slim = runCLI(["--json", "--slim", "--include-declines", "$s4main9foo"])
        let fullRecord = try #require(lines(full).first)
        let slimRecord = try #require(lines(slim).first)
        #expect(fullRecord.contains("\"schemaVersion\":1"))
        #expect(!slimRecord.contains("schemaVersion"))
        // Every other field survives byte-for-byte: dropping the leading
        // schemaVersion field (and its comma) yields the slim record.
        #expect("{" + fullRecord.dropFirst("{\"schemaVersion\":1,".count) == slimRecord)
    }

    // MARK: Boundaries — named, never silent

    @Test func includeDeclinesNeedsJSON() {
        let run = runCLI(["--include-declines", "$s4main9foo"])
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("--include-declines adds decline records to --json output"))
    }

    @Test func includeDeclinesNeedsSymbolArgumentsNotTheFilter() {
        // No symbol arguments ⇒ filter mode, which has no declines to surface.
        let run = runCLI(["--json", "--include-declines"], stdinText: "some log text\n")
        #expect(run.status == CLI.exitUsage)
        #expect(run.stderr.contains("surfaces declined symbol arguments"))
        #expect(run.stderr.contains("swiftfilt explain"))
    }

    @Test func includeDeclinesParsesIntoTheInvocation() {
        #expect(ParsedCommandLine.parse(["--json", "--include-declines", "sym"])
            == .run(Invocation(symbols: ["sym"], mode: .json(slim: false), includeDeclines: true)))
    }
}
