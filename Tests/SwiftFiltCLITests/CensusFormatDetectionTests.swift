// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// The census format-autodetection matrix: each input shape resolves to the right parser, ambiguity resolves to bare, and the reasoning is carried into the report and the JSON `detection` field.
@Suite("Census format detection")
struct CensusFormatDetectionTests {
    private func detect(_ text: String, forced: CensusFormat? = nil) -> (format: CensusFormat, reason: String) {
        CensusInput.detect(lines: CensusInput.splitLines(Array(text.utf8)), forced: forced)
    }

    @Test func linkMapHeaderDetectsLinkMap() {
        let detected = detect("# Path: build/app\n# Arch: arm64\n")
        #expect(detected.format == .linkmap)
        #expect(detected.reason.contains("# Path:"))
    }

    @Test func blankLinesBeforeLinkMapHeaderStillDetect() {
        #expect(detect("\n\n# Path: build/app\n").format == .linkmap)
    }

    @Test func pureNmRowsDetectNm() {
        let detected = detect("""
        0000000104abc120 T _$s10AppIntents0aB8XPCErrorO9errorCodeSivg
                         U _swift_retain
        0000000104ac0340 T _main
        """)
        #expect(detected.format == .nm)
        #expect(detected.reason == "all 3 sampled lines are nm rows")
    }

    @Test func fatBinaryArchHeadersAreAllowedInNmDetection() {
        let detected = detect("""
        MyApp (for architecture arm64):
        0000000104ac0340 T _main

        MyApp (for architecture arm64e):
        0000000104ac0340 T _main
        """)
        #expect(detected.format == .nm)
    }

    @Test func archHeadersAloneAreNotNm() {
        // Headers but zero rows: nothing says symbols; bare is honest.
        let detected = detect("MyApp (for architecture arm64):\n")
        #expect(detected.format == .bare)
        #expect(detected.reason.contains("no nm rows in the sample"))
    }

    @Test func proseFallsToBareWithTheOffendingLineNamed() {
        let detected = detect("""
        0000000104ac0340 T _main
        Thread 0 Crashed:
        """)
        #expect(detected.format == .bare)
        #expect(detected.reason.contains("line 2 of the sample is not an nm row"))
    }

    @Test func crashLogDetectsBare() {
        let crash = fixtureString(cliInputPath("crash-log.txt"))
        #expect(detect(crash).format == .bare)
    }

    @Test func emptyInputIsBare() {
        let detected = detect("")
        #expect(detected.format == .bare)
        #expect(detected.reason == "empty input; treated as bare text")
    }

    @Test func forcedFormatSkipsDetection() {
        for format in CensusFormat.allCases {
            let detected = detect("anything at all", forced: format)
            #expect(detected.format == format)
            #expect(detected.reason == "format forced by --format \(format.rawValue)")
        }
    }

    @Test func realFixturesDetectTheirFormats() {
        #expect(detect(fixtureString(censusFixturePath("LinkMap.txt"))).format == .linkmap)
        #expect(detect(fixtureString(censusFixturePath("nm.txt"))).format == .nm)
        #expect(detect(fixtureString(censusFixturePath("nm-sized.txt"))).format == .nm)
    }

    @Test func detectionSamplingStopsAtTheLimit() {
        // 200 nm rows then prose: the sample is exhausted before the
        // prose, so the input detects as nm — and the prose line is then
        // counted (loudly) as unparseable by the parser, never dropped.
        let rows = (0 ..< CensusInput.detectionSampleLimit)
            .map { "000000010000a\(String($0, radix: 16)) T _f\($0)" }
        let text = rows.joined(separator: "\n") + "\nnot an nm row\n"
        let detected = detect(text)
        #expect(detected.format == .nm)
        let run = runCLI(["census", "--json"], stdinText: text)
        #expect(run.stdout.contains("\"unparseableLines\":1"))
    }

    @Test func reportCarriesDetectionReasoning() {
        let run = runCLI(["census"], stdinText: "no symbols here\n")
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.contains("census — bare text, count-weighted"))
        #expect(run.stdout.contains("detected: no linkmap header and line 1 of the sample is not an nm row"))
    }

    @Test func jsonCarriesDetectionReasoning() {
        let run = runCLI(["census", "--json", "--format", "nm"], stdinText: "0000 T _main\n")
        #expect(run.stdout.contains("\"detection\":\"format forced by --format nm\""))
    }

    @Test func splitLinesHandlesCarriageReturnsAndFinalLine() {
        #expect(CensusInput.splitLines(Array("a\r\nb\nc".utf8)) == ["a", "b", "c"])
        #expect(CensusInput.splitLines(Array("a\n".utf8)) == ["a"])
        #expect(CensusInput.splitLines(Array("a\r".utf8)) == ["a"])
        #expect(CensusInput.splitLines(Array("\n\n".utf8)) == ["", ""])
        #expect(CensusInput.splitLines([]) == [])
    }

    /// The bare harvest counts lines without decoding them; an
    /// unterminated final line counts exactly as `splitLines` counts it.
    @Test func bareCensusCountsAnUnterminatedFinalLine() {
        let unterminated = Array("$s4main3fooyyF\nplain text tail".utf8)
        let harvest = CensusInput.harvest(unterminated, format: .bare, reason: "test")
        #expect(harvest.lines == 2)
        #expect(harvest.lines == CensusInput.splitLines(unterminated).count)
        let terminated = CensusInput.harvest(Array("$s4main3fooyyF\n".utf8), format: .bare, reason: "test")
        #expect(terminated.lines == 1)
    }
}
