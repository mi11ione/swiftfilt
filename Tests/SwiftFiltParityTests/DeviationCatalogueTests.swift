// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFiltParityCore
import Testing

/// The KNOWN-DEVIATIONS table grammar: what parses into an entry, what is ignored, and how malformed rows fail safe (toward gating, never silent classification).
@Suite("Deviations table parsing")
struct DeviationTableParsingTests {
    @Test func parsesAWellFormedEntryRow() {
        let entries = DeviationCatalogue.parse(markdown: """
        | id | status | matcher | evidence |
        |---|---|---|---|
        | `old-suffix` | expected | `leg=roundtrip; class=oldform-suffix` | evidence text |
        """)
        #expect(entries.count == 1)
        #expect(entries[0].id == "old-suffix")
        #expect(entries[0].status == .expected)
        #expect(entries[0].constraints.count == 2)
        #expect(entries[0].constraints[0].key == "leg")
        #expect(entries[0].constraints[0].value == "roundtrip")
        #expect(entries[0].constraints[1].key == "class")
        #expect(entries[0].constraints[1].value == "oldform-suffix")
    }

    @Test func parsesOpenDefectStatus() {
        let entries = DeviationCatalogue.parse(markdown: """
        | `bug-1` | open-defect | `leg=full; class=render-mismatch; mangled.prefix=$s3foo` | recorded bug |
        """)
        #expect(entries.count == 1)
        #expect(entries[0].status == .openDefect)
    }

    @Test func headerSeparatorAndProseRowsAreIgnored() {
        let entries = DeviationCatalogue.parse(markdown: """
        # Known Deviations
        prose describing the contract
        | id | status | matcher | evidence |
        |---|---|---|---|
        not a table row at all
        """)
        #expect(entries.isEmpty)
    }

    @Test func unknownStatusRowsAreDropped() {
        let entries = DeviationCatalogue.parse(markdown: """
        | `x` | tolerated | `leg=full` | never |
        | `y` | Expected | `leg=full` | case-sensitive |
        """)
        #expect(entries.isEmpty, "only `expected` and `open-defect` are statuses")
    }

    @Test func entryWithEmptyMatcherIsDropped() {
        // An entry with no parseable clauses can never match anything;
        // keeping it would imply coverage it does not provide.
        let entries = DeviationCatalogue.parse(markdown: """
        | `empty` | expected | `` | no clauses |
        | `junk` | expected | `;;;` | no clauses either |
        """)
        #expect(entries.isEmpty)
    }

    @Test func valuesMayContainEquals() {
        // `maxSplits: 1` keeps regex values with `=` intact.
        let entries = DeviationCatalogue.parse(markdown: """
        | `rx` | expected | `mangled.regex=^x=y$` | regex with equals |
        """)
        #expect(entries.count == 1)
        #expect(entries[0].constraints[0].value == "^x=y$")
    }

    @Test func missingFileYieldsEmptyCatalogueSoEverythingGates() {
        let catalogue = DeviationCatalogue.load(from: "/nonexistent/KNOWN-DEVIATIONS.md")
        #expect(catalogue.entries.isEmpty)
        #expect(catalogue.classify(Divergence(leg: "full", klass: "render-mismatch", mangled: "$s", swiftfilt: "a", oracle: "b")) == nil)
    }

    @Test func repoTableParsesAndEveryEntryHasEvidence() throws {
        // The committed table itself must stay machine-readable and every
        // entry must carry non-empty evidence and a verbatim reproducer.
        let path = repositoryRoot().appendingPathComponent("KNOWN-DEVIATIONS.md").path
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("Oracle version for all evidence"))
        let catalogue = DeviationCatalogue.load(from: path)
        for entry in catalogue.entries {
            #expect(!entry.constraints.isEmpty, "\(entry.id): entry without clauses")
        }
        // Every table row that declares a status must have parsed.
        let statusRows = contents.split(separator: "\n").filter {
            $0.hasPrefix("|") && ($0.contains("| expected |") || $0.contains("| open-defect |"))
        }
        #expect(statusRows.count == catalogue.entries.count, "a committed entry failed to parse")
    }
}

/// The matcher mini-language: every clause, ANDing, and fail-safe behavior for unknown keys and bad regexes.
@Suite("Deviations matcher semantics")
struct DeviationMatcherTests {
    private func divergence(
        leg: String = "full", klass: String = "render-mismatch",
        mangled: String = "$s4main3fooyyF", swiftfilt: String = "mine", oracle: String = "theirs",
    ) -> Divergence {
        Divergence(leg: leg, klass: klass, mangled: mangled, swiftfilt: swiftfilt, oracle: oracle)
    }

    private func entry(_ constraints: [(String, String)]) -> DeviationEntry {
        DeviationEntry(id: "t", status: .expected, constraints: constraints)
    }

    @Test func legAndClassMatchExactly() {
        #expect(entry([("leg", "full")]).matches(divergence()))
        #expect(!entry([("leg", "tree")]).matches(divergence()))
        #expect(entry([("class", "render-mismatch")]).matches(divergence()))
        #expect(!entry([("class", "tree-mismatch")]).matches(divergence()))
    }

    @Test func prefixAndSuffixClauses() {
        #expect(entry([("mangled.prefix", "$s4main")]).matches(divergence()))
        #expect(!entry([("mangled.prefix", "$s5other")]).matches(divergence()))
        #expect(entry([("mangled.suffix", "yyF")]).matches(divergence()))
        #expect(!entry([("mangled.suffix", "Tj")]).matches(divergence()))
    }

    @Test func regexMustMatchTheEntireMangledName() {
        #expect(entry([("mangled.regex", #"\$s4main.*F"#)]).matches(divergence()))
        // A partial match is not enough — anchored to the whole name.
        #expect(!entry([("mangled.regex", "4main")]).matches(divergence()))
        #expect(!entry([("mangled.regex", #"\$s4main"#)]).matches(divergence()))
    }

    @Test func invalidRegexNeverMatches() {
        #expect(!entry([("mangled.regex", "([unclosed")]).matches(divergence()))
    }

    @Test func containsClausesCheckBothSides() {
        #expect(entry([("oracle.contains", "their")]).matches(divergence()))
        #expect(!entry([("oracle.contains", "mine")]).matches(divergence()))
        #expect(entry([("swiftfilt.contains", "mine")]).matches(divergence()))
        #expect(!entry([("swiftfilt.contains", "their")]).matches(divergence()))
    }

    @Test func allClausesMustHold() {
        let both = entry([("leg", "full"), ("mangled.prefix", "$s4main")])
        #expect(both.matches(divergence()))
        #expect(!both.matches(divergence(leg: "tree")), "one failing clause defeats the entry")
        #expect(!both.matches(divergence(mangled: "$s5other1xV")))
    }

    @Test func unknownClauseKeyNeverMatches() {
        // A typo in the table must surface as gating rows, never classify.
        #expect(!entry([("mangledprefix", "$s4main")]).matches(divergence()))
        #expect(!entry([("leg", "full"), ("bogus.key", "x")]).matches(divergence()))
    }

    @Test func emptyConstraintListNeverMatches() {
        #expect(!entry([]).matches(divergence()))
    }

    @Test func catalogueReturnsFirstMatch() {
        let catalogue = DeviationCatalogue(entries: [
            DeviationEntry(id: "narrow", status: .expected, constraints: [("leg", "full"), ("mangled.prefix", "$s4main")]),
            DeviationEntry(id: "broad", status: .expected, constraints: [("leg", "full")]),
        ], path: "<in-memory>")
        #expect(catalogue.classify(divergence())?.id == "narrow")
        #expect(catalogue.classify(divergence(mangled: "$s5other1xV"))?.id == "broad")
        #expect(catalogue.classify(divergence(leg: "tree")) == nil)
    }
}

/// The gating contract: catalogued rows never gate, everything else does, counts stay exact past the stored-row cap, and harness errors can never exit clean.
@Suite("Run report gating behavior")
struct RunReportGatingTests {
    private let emptyCatalogue = DeviationCatalogue(entries: [], path: "<in-memory>")

    @Test func cleanRunExitsZero() {
        var report = RunReport(instrument: "test", catalogue: emptyCatalogue)
        report.countComparison(leg: "full", by: 10)
        #expect(report.exitCode == 0)
        #expect(report.render().contains("UNEXPLAINED DIVERGENCES: 0"))
    }

    @Test func anyUncataloguedDivergenceGates() {
        var report = RunReport(instrument: "test", catalogue: emptyCatalogue)
        report.record(Divergence(leg: "full", klass: "render-mismatch", mangled: "$sX", swiftfilt: "a", oracle: "b"))
        #expect(report.exitCode == 1)
        #expect(report.gatingTotal == 1)
        let rendered = report.render()
        #expect(rendered.contains("GATING"))
        #expect(rendered.contains("$sX"), "the offending row is named")
    }

    @Test func cataloguedDivergenceDoesNotGateAndIsReported() {
        let catalogue = DeviationCatalogue(entries: [
            DeviationEntry(id: "known-x", status: .expected, constraints: [("class", "render-mismatch")]),
        ], path: "<in-memory>")
        var report = RunReport(instrument: "test", catalogue: catalogue)
        report.record(Divergence(leg: "full", klass: "render-mismatch", mangled: "$sX", swiftfilt: "a", oracle: "b"))
        #expect(report.exitCode == 0)
        #expect(report.catalogued["known-x"] == 1)
        #expect(report.render().contains("known-x"))
    }

    @Test func openDefectIsNonGatingButLoud() {
        let catalogue = DeviationCatalogue(entries: [
            DeviationEntry(id: "defect-1", status: .openDefect, constraints: [("class", "render-mismatch")]),
        ], path: "<in-memory>")
        var report = RunReport(instrument: "test", catalogue: catalogue)
        report.record(Divergence(leg: "full", klass: "render-mismatch", mangled: "$sX", swiftfilt: "a", oracle: "b"))
        #expect(report.exitCode == 0)
        #expect(report.render().contains("OPEN DEFECT"))
    }

    @Test func harnessErrorsNeverExitClean() {
        var report = RunReport(instrument: "test", catalogue: emptyCatalogue)
        report.recordHarnessError("oracle timed out")
        #expect(report.exitCode == 2)
        #expect(report.render().contains("HARNESS ERROR"))
    }

    @Test func countsStayExactPastTheStoredRowCap() {
        var report = RunReport(instrument: "test", catalogue: emptyCatalogue, storedRowCap: 5)
        for index in 0 ..< 12 {
            report.record(Divergence(leg: "full", klass: "render-mismatch", mangled: "$s\(index)", swiftfilt: "a", oracle: "b"))
        }
        #expect(report.gatingTotal == 12, "counts are exact")
        #expect(report.gating.count == 5, "stored rows are capped")
        #expect(report.exitCode == 1)
    }

    @Test func staleEntriesAreSurfacedOnlyForLegsTheRunCompared() {
        let catalogue = DeviationCatalogue(entries: [
            DeviationEntry(id: "never-hits", status: .expected, constraints: [("class", "no-such-class")]),
            DeviationEntry(id: "this-leg", status: .expected, constraints: [("leg", "full"), ("class", "no-such-class")]),
            DeviationEntry(id: "other-instrument", status: .expected, constraints: [("leg", "roundtrip"), ("class", "remangle-nil")]),
        ], path: "<in-memory>")
        var report = RunReport(instrument: "test", catalogue: catalogue)
        report.countComparison(leg: "full", by: 3)
        let rendered = report.render()
        #expect(rendered.contains("never-hits"), "an unpinned entry is judged by every run")
        #expect(rendered.contains("this-leg"), "an entry on a compared leg that matched nothing is stale")
        #expect(!rendered.contains("other-instrument"), "an entry pinned to another instrument's leg is not this run's to judge")
    }

    @Test func gatingRowsWriteEscapedTSV() throws {
        var report = RunReport(instrument: "test", catalogue: emptyCatalogue)
        report.record(Divergence(leg: "full", klass: "render-mismatch", mangled: "$sTab\tName", swiftfilt: "line1\nline2", oracle: "b"))
        let directory = NSTemporaryDirectory() + "/parity-test-\(UInt64.random(in: 0 ... .max))"
        let path = try #require(report.writeGatingRows(toDirectory: directory))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written.contains("$sTab\\tName"))
        #expect(written.contains("line1\\nline2"))
        #expect(written.split(separator: "\n").count == 2, "header + one row")
    }
}
