// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// The census report's rendering edges: empty tables, weight-honesty (no bytes column on count-weighted input), percentage math on degenerate and hostile magnitudes, TTY color, and the payload-kind name vocabulary.
@Suite("Census report rendering")
struct CensusReportRenderingTests {
    /// A minimal balanced harvest/tally to render against — the render path validates
    /// nothing, so the doctored fields exercise the formatting arms directly.
    private func emptyLinkMapHarvest(sized: Bool = true) -> CensusHarvest {
        var harvest = CensusHarvest(format: .linkmap, detectionReason: "test")
        harvest.sizesPresent = sized
        return harvest
    }

    @Test func emptyTablesSayNone() {
        let report = CensusReport.render(
            harvest: emptyLinkMapHarvest(), tally: CensusTally(), top: 10,
            palette: Palette(enabled: false),
        )
        #expect(report.contains("swift by kind\n  (none)"))
        #expect(report.contains("swift by module\n  (none)"))
        #expect(report.contains("specialized generic origins\n  (none)"))
        #expect(report.contains("duplicated logical functions\n  (none)"))
        #expect(report.contains("(no swift symbols)"))
    }

    @Test func unattributableSpecializationsAreReported() {
        var tally = CensusTally()
        tally.unattributedSpecializations = CensusWeight(count: 2, bytes: 64)
        let report = CensusReport.render(
            harvest: emptyLinkMapHarvest(), tally: tally, top: 10,
            palette: Palette(enabled: false),
        )
        #expect(report.contains("unattributable specializations (origin not recoverable): 2 (64 bytes)"))
    }

    @Test func countWeightedReportsShowNoBytesAnywhere() {
        let run = runCLI(["census", "--color", "never"], stdin: fixtureBytes(censusFixturePath("nm.txt")))
        #expect(!run.stdout.contains("bytes"))
        #expect(run.stdout.contains("count  kind"))
        #expect(run.stdout.contains("copies  generic origin"))
    }

    @Test func sizeWeightedReportsLabelTheBytesColumn() {
        let run = runCLI(["census", "--color", "never"], stdin: fixtureBytes(censusFixturePath("LinkMap.txt")))
        #expect(run.stdout.contains("count  bytes  kind"))
        #expect(run.stdout.contains("copies  bytes  generic origin"))
        #expect(run.stdout.contains("copies  bytes  identity"))
    }

    @Test func percentIsZeroWhenSwiftBytesAreZero() {
        // Sized input whose Swift rows are all zero-sized: the share line
        // must not divide by zero.
        var tally = CensusTally()
        tally.swift = CensusWeight(count: 2, bytes: 0)
        tally.human = CensusWeight(count: 2, bytes: 0)
        tally.kinds = ["function": CensusWeight(count: 2, bytes: 0)]
        let report = CensusReport.render(
            harvest: emptyLinkMapHarvest(), tally: tally, top: 10,
            palette: Palette(enabled: false),
        )
        #expect(report.contains("machinery is 0.0% of swift bytes (0 of 2 symbols)"))
    }

    @Test func percentSurvivesHostileMagnitudes() {
        // Byte totals near UInt64.max would overflow the naive
        // permille multiply; the pre-scaling path must stay exact-ish
        // and, above all, not trap.
        var tally = CensusTally()
        tally.swift = CensusWeight(count: 1, bytes: .max)
        tally.machinery = CensusWeight(count: 1, bytes: .max)
        let report = CensusReport.render(
            harvest: emptyLinkMapHarvest(), tally: tally, top: 10,
            palette: Palette(enabled: false),
        )
        #expect(report.contains("machinery is 100.0% of swift bytes"))
    }

    @Test func percentSurvivesHugePartOverTinyTotal() {
        // A doctored part >> total (only reachable through doctoring —
        // the tally's books would never balance) must still not trap.
        var tally = CensusTally()
        tally.swift = CensusWeight(count: 1, bytes: 100)
        tally.machinery = CensusWeight(count: 1, bytes: .max)
        let report = CensusReport.render(
            harvest: emptyLinkMapHarvest(), tally: tally, top: 10,
            palette: Palette(enabled: false),
        )
        #expect(report.contains("machinery is "))
    }

    @Test func groupedNumbersUseCommas() {
        var tally = CensusTally()
        tally.swift = CensusWeight(count: 1_234_567, bytes: 9_876_543_210)
        tally.human = tally.swift
        let report = CensusReport.render(
            harvest: emptyLinkMapHarvest(), tally: tally, top: 10,
            palette: Palette(enabled: false),
        )
        #expect(report.contains("1,234,567"))
        #expect(report.contains("9,876,543,210"))
    }

    @Test func headingsAreBoldOnATTYAndPlainWhenPiped() {
        let input = fixtureBytes(censusFixturePath("LinkMap.txt"))
        let tty = runCLI(["census"], stdin: input, tty: true).stdout
        #expect(tty.contains("\u{1B}[1mcensus — Xcode LinkMap, size-weighted\u{1B}[0m"))
        #expect(tty.contains("\u{1B}[1minput\u{1B}[0m"))
        let piped = runCLI(["census"], stdin: input, tty: false).stdout
        #expect(!piped.contains("\u{1B}["))
        let forced = runCLI(["census", "--color", "always"], stdin: input, tty: false).stdout
        #expect(forced.contains("\u{1B}[1m"))
        let never = runCLI(["census", "--color", "never"], stdin: input, tty: true).stdout
        #expect(!never.contains("\u{1B}["))
    }

    @Test func jsonIsNeverColored() {
        let run = runCLI(["census", "--json", "--color", "always"], stdin: fixtureBytes(censusFixturePath("nm.txt")))
        #expect(!run.stdout.contains("\u{1B}["))
    }

    @Test func paletteHeadingHandlesEmptyAndDisabled() {
        #expect(Palette(enabled: true).heading("") == "")
        #expect(Palette(enabled: false).heading("x") == "x")
        #expect(Palette(enabled: true).heading("x") == "\u{1B}[1mx\u{1B}[0m")
    }

    @Test func payloadKindsRenderQualifiedTableNames() {
        // Oracle-verified manglings (xcrun swift-demangle agrees on every
        // one) covering the payload-carrying kind families and the
        // machinery kinds the headline split documents.
        let rows = [
            "$s4main1xSivpfi", //   variable initialization expression
            "$s4main3fooyyFfA_", // default argument 0
            "$s4main5ColorO3redyA2CmFWC", // enum case record
            "$s4main3barSivpZ", //  static variable
        ]
        let text = rows.map { "0000000104ac0340 T _\($0)" }.joined(separator: "\n")
        let run = runCLI(["census", "--json"], stdinText: text)
        #expect(run.stdout.contains("\"name\":\"variableInitializer\",\"count\":1"))
        #expect(run.stdout.contains("\"name\":\"defaultArgument\",\"count\":1"))
        #expect(run.stdout.contains("\"name\":\"enumCase\",\"count\":1"))
        #expect(run.stdout.contains("\"name\":\"variable\",\"count\":1"))
        // All four but the variable are machinery.
        #expect(run.stdout.contains("\"machinery\":3,\"human\":1"))
    }

    @Test func accessorAndThunkAndMetadataKindsQualify() {
        // Real manglings from the shipped fixtures: a getter, a dispatch
        // thunk (.stub suffix form), and metadata records.
        let text = """
        0000000104abc120 T _$s10AppIntents0aB8XPCErrorO9errorCodeSivg
        0000000104abc124 T _$ss23CustomStringConvertibleP11descriptionSSvgTj.stub
        0000000104abc128 s _$sSSN
        """
        let run = runCLI(["census", "--json"], stdinText: text)
        #expect(run.stdout.contains("\"name\":\"accessor.getter\""))
        #expect(run.stdout.contains("\"name\":\"thunk.dispatch\""))
        #expect(run.stdout.contains("\"name\":\"metadata.typeMetadata\""))
    }

    @Test func moduleLessSymbolsGetTheExplicitBucket() {
        // A reabstraction thunk carries no module statically.
        let run = runCLI(["census", "--json"], stdinText: "0000 T _$sS2iIegyd_S2iIegnr_TR\n")
        #expect(run.stdout.contains("\"table\":\"modules\",\"name\":\"(no module)\",\"count\":1"))
    }
}
