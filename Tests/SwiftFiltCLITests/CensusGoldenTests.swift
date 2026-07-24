// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFiltCLICore
import Testing

/// The census aggregation goldens: every checked-in fixture (real LinkMap, nm dump, sized nm dump, crash log as bare text) through the in-process CLI, byte-compared to the locked goldens — human report and NDJSON, full and slim — plus determinism and the slim-is-a-faithful-subset contract.
@Suite("Census goldens")
struct CensusGoldenTests {
    private static let goldenRuns: [(input: String, flags: [String], golden: String)] = [
        (censusFixturePath("LinkMap.txt"), ["census", "--color", "never"], "census-linkmap.txt"),
        (censusFixturePath("LinkMap.txt"), ["census", "--color", "never", "--top", "3"], "census-linkmap.top3.txt"),
        (censusFixturePath("LinkMap.txt"), ["census", "--json"], "census-linkmap.ndjson"),
        (censusFixturePath("LinkMap.txt"), ["census", "--json", "--slim"], "census-linkmap.slim.ndjson"),
        (censusFixturePath("nm.txt"), ["census", "--color", "never"], "census-nm.txt"),
        (censusFixturePath("nm.txt"), ["census", "--json", "--slim"], "census-nm.slim.ndjson"),
        (censusFixturePath("nm-sized.txt"), ["census", "--color", "never"], "census-nm-sized.txt"),
        (censusFixturePath("nm-sized.txt"), ["census", "--json"], "census-nm-sized.ndjson"),
        (cliInputPath("crash-log.txt"), ["census", "--color", "never"], "census-bare.txt"),
        (cliInputPath("crash-log.txt"), ["census", "--json"], "census-bare.ndjson"),
    ]

    @Test(arguments: 0 ..< 10)
    func goldenRunMatchesByteForByte(index: Int) {
        let run = Self.goldenRuns[index]
        let input = fixtureBytes(run.input)
        #expect(!input.isEmpty, "fixture missing: \(run.input) — run Scripts/build-census-fixtures.sh")
        let result = runCLI(run.flags, stdin: input)
        #expect(result.status == CLI.exitSuccess)
        #expect(result.stderr.isEmpty)
        #expect(result.stdoutBytes == goldenBytes(run.golden),
                "\(run.golden) drifted from \(run.flags.joined(separator: " "))")
    }

    @Test func rerunsAreByteIdentical() {
        let input = fixtureBytes(censusFixturePath("LinkMap.txt"))
        for flags in [["census", "--color", "never"], ["census", "--json"]] {
            let first = runCLI(flags, stdin: input).stdoutBytes
            let second = runCLI(flags, stdin: input).stdoutBytes
            #expect(first == second)
        }
    }

    @Test func chunkedInputChangesNothing() {
        // Census drains the whole stream before parsing; framing must
        // not depend on chunk boundaries.
        let input = fixtureBytes(censusFixturePath("LinkMap.txt"))
        let whole = runCLI(["census", "--json"], stdin: input).stdoutBytes
        let chunked = runCLI(["census", "--json"], stdin: input, chunkSize: 7).stdoutBytes
        #expect(whole == chunked)
    }

    @Test func slimIsAFaithfulSubsetOfFull() throws {
        // Every slim line is its full twin with `schemaVersion` (and the
        // summary's `detection`) removed — nothing else changes, nothing
        // reorders. String surgery on the full record must reproduce the
        // slim record exactly.
        let input = fixtureBytes(censusFixturePath("LinkMap.txt"))
        let full = runCLI(["census", "--json"], stdin: input).stdout.split(separator: "\n")
        let slim = runCLI(["census", "--json", "--slim"], stdin: input).stdout.split(separator: "\n")
        #expect(full.count == slim.count)
        #expect(!full.isEmpty)
        for (fullLine, slimLine) in zip(full, slim) {
            var expected = fullLine.replacingOccurrences(of: "\"schemaVersion\":1,", with: "")
            if let start = expected.range(of: ",\"detection\":\"") {
                // The detection value is a JSON string with no escapes in
                // these fixtures; drop the whole field.
                let tail = expected[start.upperBound...]
                let end = try #require(tail.firstIndex(of: "\""))
                expected.removeSubrange(start.lowerBound ... end)
            }
            #expect(String(slimLine) == expected)
        }
    }

    @Test func topShapesTheHumanTablesOnly() {
        let input = fixtureBytes(censusFixturePath("LinkMap.txt"))
        let top1 = runCLI(["census", "--color", "never", "--top", "1"], stdin: input).stdout
        #expect(top1.contains("duplicated logical functions (top 1 of "))
        #expect(top1.contains("more duplicated functions)"))
        // JSON is complete regardless of --top.
        let jsonDefault = runCLI(["census", "--json"], stdin: input).stdoutBytes
        let jsonTop1 = runCLI(["census", "--json", "--top", "1"], stdin: input).stdoutBytes
        #expect(jsonDefault == jsonTop1)
    }

    @Test func residualRowsKeepTheTableSumsComplete() throws {
        // With --top 1 the residual row must carry exactly the hidden
        // rows' totals: shown + residual == the whole table.
        let input = fixtureBytes(censusFixturePath("LinkMap.txt"))
        let json = runCLI(["census", "--json"], stdin: input).stdout
        var moduleCounts: [Int] = []
        for line in json.split(separator: "\n") where line.contains("\"table\":\"modules\"") {
            let marker = "\"count\":"
            let start = try #require(line.range(of: marker)?.upperBound)
            let digits = line[start...].prefix { $0.isNumber }
            try moduleCounts.append(#require(Int(digits)))
        }
        let top1 = runCLI(["census", "--color", "never", "--top", "1"], stdin: input).stdout
        let section = try #require(top1.components(separatedBy: "\n\n").first { $0.hasPrefix("swift by module") })
        let residualLine = try #require(section.split(separator: "\n").first { $0.contains("more modules)") })
        let firstToken = try #require(residualLine.split(separator: " ").first)
        let residualCount = try #require(Int(firstToken.replacingOccurrences(of: ",", with: "")))
        #expect(residualCount == moduleCounts.dropFirst().reduce(0, +))
    }

    @Test func bareGoldenCountsEveryOccurrence() {
        // The crash log's specialized frame and its origin both appear;
        // bare mode counts occurrences, so the identity table groups
        // them under one key with two copies.
        let json = runCLI(["census", "--json"], stdin: fixtureBytes(cliInputPath("crash-log.txt"))).stdout
        #expect(json.contains("\"kind\":\"census\",\"format\":\"bare\",\"weight\":\"count\""))
        #expect(!json.contains("\"rowBytes\""))
    }
}
