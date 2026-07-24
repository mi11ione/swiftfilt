// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFiltParityCore
import Testing

/// TSV/fixture parsing edges: the parity tool's readers must count what they skip, never silently reshape a fixture.
@Suite("Parity fixture and manifest parsing")
struct ParityParsingTests {
    private func write(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "/parity-fixture-\(UInt64.random(in: 0 ... .max)).tsv"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func corpusFixtureRowsParseAndMalformedRowsAreCounted() throws {
        let path = try write("""
        # comment
        $sA\tfullA\tsimpleA\tqualA
        broken row with no tabs
        $sB\tfullB\tsimpleB\tqualB\textra
        $sC\tfullC\tsimpleC\tqualC
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (rows, malformed) = try loadCorpusFixture(path: path)
        #expect(rows.count == 2)
        #expect(rows[0].mangled == "$sA")
        #expect(rows[1].noSugar == "qualC")
        #expect(malformed == [3, 4], "the 1-tab and 5-column rows are surfaced, not skipped")
    }

    @Test func emptyColumnsSurviveFixtureParsing() throws {
        // `omittingEmptySubsequences: false` keeps empty cells positional.
        let path = try write("$sA\t\tsimpleA\tqualA")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (rows, _) = try loadCorpusFixture(path: path)
        #expect(rows.count == 1)
        #expect(rows[0].compact.isEmpty)
        #expect(rows[0].simplified == "simpleA")
    }

    @Test func pairAndLegacyFixturesEnforceTheirColumnCounts() throws {
        let pairPath = try write("$sA\texpectedA\n$sB\tone\ttwo")
        defer { try? FileManager.default.removeItem(atPath: pairPath) }
        let (pairs, pairMalformed) = try loadPairFixture(path: pairPath)
        #expect(pairs.count == 1)
        #expect(pairMalformed == [2])

        let legacyPath = try write("_TA\tfull\tsimple\n_TB\tonly-two")
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        let (legacy, legacyMalformed) = try loadLegacyFixture(path: legacyPath)
        #expect(legacy.count == 1)
        #expect(legacyMalformed == [2])
    }

    @Test func manifestReaderStreamsColumnZeroInBatches() throws {
        var contents = "# mangled_string\tfirst_binary\toccurrences\n"
        for index in 0 ..< 25 {
            contents += "$sSym\(index)\t/bin/x\t\(index)\n"
        }
        contents += "\n" // blank line: empty column 0, skipped
        contents += "$sTail\t/bin/y\t1" // no trailing newline
        let path = try write(contents)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = try #require(ManifestBatchReader(path: path, batchSize: 10, limit: .max))
        var batches: [[String]] = []
        while let batch = reader.next() {
            batches.append(batch)
        }
        #expect(batches.map(\.count) == [10, 10, 6])
        #expect(batches[0][0] == "$sSym0")
        #expect(batches[2].last == "$sTail", "the final unterminated line is read")
        #expect(reader.emittedCount == 26)
    }

    @Test func manifestReaderHonorsLimit() throws {
        var contents = ""
        for index in 0 ..< 50 {
            contents += "$sSym\(index)\tx\t1\n"
        }
        let path = try write(contents)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = try #require(ManifestBatchReader(path: path, batchSize: 8, limit: 20))
        var total = 0
        while let batch = reader.next() {
            total += batch.count
        }
        #expect(total == 20)
    }

    @Test func manifestReaderSkipResumesExactlyWhereALimitedChunkEnded() throws {
        // The chunked-acceptance contract: chunk k = (skip: k*C, limit: C);
        // consecutive chunks partition the corpus with no gap and no
        // overlap, and comments/blank rows never shift the boundary.
        var contents = "# header\n"
        for index in 0 ..< 30 {
            contents += "$sSym\(index)\tx\t1\n"
            if index == 10 { contents += "# interleaved comment\n" }
        }
        let path = try write(contents)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var stitched: [String] = []
        for chunk in 0 ..< 3 {
            let reader = try #require(ManifestBatchReader(path: path, batchSize: 4, limit: 10, skip: chunk * 10))
            while let batch = reader.next() {
                stitched.append(contentsOf: batch)
            }
        }
        #expect(stitched == (0 ..< 30).map { "$sSym\($0)" })
    }

    @Test func treeBlocksParseByHeaderAndTrimTrailingBlanks() throws {
        let path = try write("""
        Demangling for $sA
        kind=Global
          kind=Structure, text="A"

        Demangling for $sB
        kind=Global
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let blocks = try loadTreeBlocks(path: path)
        #expect(blocks.count == 2)
        #expect(blocks["$sA"] == "kind=Global\n  kind=Structure, text=\"A\"")
        #expect(blocks["$sB"] == "kind=Global")
    }

    @Test func oracleDeclineRuleMatchesEchoAndUnderscoreStrippedEcho() {
        #expect(oracleDeclined("$sNotASymbol", mangled: "$sNotASymbol"))
        #expect(oracleDeclined("$sfoo", mangled: "_$sfoo"), "one leading Mach-O underscore strips")
        #expect(!oracleDeclined("main.foo() -> ()", mangled: "$s4main3fooyyF"))
        #expect(!oracleDeclined("sfoo", mangled: "_$sfoo"), "only the underscore form strips")
    }
}

/// Oracle plumbing that must not depend on a live toolchain: the sentinel-segmented tree splitting and the classify marker extraction.
@Suite("Oracle output alignment")
struct OracleAlignmentTests {
    private let boundary = Oracle.treeRowSentinel

    @Test func treeBlocksSegmentBySentinelAcrossDeclinedSymbols() {
        let output = """
        Demangling for $sA
        kind=Global
          kind=Structure, text="A"

        \(boundary)
        notASymbolEchoed
        \(boundary)
        Demangling for $sB
        <<NULL>>

        \(boundary)

        """
        let blocks = Oracle.splitTreeBlocks(output, symbols: ["$sA", "notASymbolEchoed", "$sB"])
        #expect(blocks?.count == 3)
        #expect(blocks?[0] == "kind=Global\n  kind=Structure, text=\"A\"")
        #expect(blocks?[1].isEmpty == true, "an echoed symbol has no tree")
        #expect(blocks?[2] == "<<NULL>>")
    }

    @Test func sentinelCountMismatchRefusesToGuess() {
        // Fewer sentinel echoes than inputs = malformed stream: nil, so the
        // caller aborts loudly instead of misattributing verdicts.
        let output = "Demangling for $sA\nkind=Global\n\(boundary)\n"
        #expect(Oracle.splitTreeBlocks(output, symbols: ["$sA", "$sB"]) == nil)
        // More sentinels than inputs likewise.
        let extra = "\(boundary)\n\(boundary)\n\(boundary)\n"
        #expect(Oracle.splitTreeBlocks(extra, symbols: ["$sA", "$sB"]) == nil)
    }

    @Test func doubleUnderscoreHeadersAlignInAllThreeForms() {
        // The tool strips one `_` from a `__…` name before the header; in
        // stdin filter mode the residual `_` is glued onto the header line
        // itself (`_Demangling for _TM…`). All three observed forms align.
        let output = """
        _Demangling for _TMKey
        kind=Global
          kind=Suffix, text="ey"

        \(boundary)
        Demangling for _TOther
        kind=Global
        \(boundary)
        Demangling for $sB
        kind=Global
        \(boundary)

        """
        let blocks = Oracle.splitTreeBlocks(output, symbols: ["__TMKey", "__TOther", "$sB"])
        #expect(blocks?[0] == "kind=Global\n  kind=Suffix, text=\"ey\"")
        #expect(blocks?[1] == "kind=Global", "the plain stripped header aligns too")
        #expect(blocks?[2] == "kind=Global")
    }

    @Test func partialSpanHeadersYieldNoTreeNeverDerailLaterRows() {
        // A C name with `:` demangles only piecewise: the tool emits a
        // header for the SPAN, not the whole name. That row must yield no
        // tree (the whole name did not demangle) — and the rows after it
        // must still segment correctly (the pre-sentinel design lost every
        // subsequent row in the batch to exactly this line shape).
        let output = """
        _Demangling for _TISInputModeIdentifierFromInputMode
        <<NULL>>
        \(boundary)
        Demangling for $sGood
        kind=Global
          kind=Structure, text="Good"
        \(boundary)

        """
        let blocks = Oracle.splitTreeBlocks(output, symbols: ["__TISInputModeIdentifierFromInputMode:._TISModeArray", "$sGood"])
        #expect(blocks?[0].isEmpty == true, "a partial-span header is not a whole-name tree")
        #expect(blocks?[1] == "kind=Global\n  kind=Structure, text=\"Good\"")
    }

    @Test func junkBodyAfterAHeaderIsNotATree() {
        let output = "Demangling for $sA\nnot a node line\n\(boundary)\n"
        let blocks = Oracle.splitTreeBlocks(output, symbols: ["$sA"])
        #expect(blocks?[0].isEmpty == true)
    }

    @Test func leadingBraceTokensExtractOnlyTheLeadingRun() {
        #expect(leadingBraceTokens("{T:$s3foo,C} @objc foo") == "{T:$s3foo,C}")
        #expect(leadingBraceTokens("{N} echoed") == "{N}")
        #expect(leadingBraceTokens("plain demangling {not a marker}").isEmpty)
        #expect(leadingBraceTokens("").isEmpty)
    }

    @Test func firstDifferingLineFindsTheDivergentNode() {
        let mine = "kind=Global\n  kind=Structure, text=\"A\""
        let theirs = "kind=Global\n  kind=Enum, text=\"A\""
        #expect(firstDifferingLine(mine, theirs, wantFirst: true) == "  kind=Structure, text=\"A\"")
        #expect(firstDifferingLine(mine, theirs, wantFirst: false) == "  kind=Enum, text=\"A\"")
        let longer = "kind=Global\nextra"
        #expect(firstDifferingLine(longer, "kind=Global", wantFirst: false) == "<none>")
    }
}

/// The gate must gate: the selfcheck subcommand run end-to-end, plus the live-leg selection grammar.
@Suite("Gate-gates proof and leg selection")
struct GateGatesTests {
    @Test func selfCheckSubcommandPasses() {
        #expect(runSelfCheckCommand([]) == 0)
    }

    @Test func selfCheckRejectsOptions() {
        #expect(runSelfCheckCommand(["--bogus"]) == 2)
    }

    @Test func legSelectionParsesAndRejects() {
        let all = LiveLegs(spec: "full,simplified,qualified,tree,classify,decline,unqualified")
        #expect(all?.names.count == 7)
        let subset = LiveLegs(spec: "full,decline")
        #expect(subset?.names == ["full", "decline"])
        #expect(LiveLegs(spec: "full,bogus") == nil)
        #expect(LiveLegs(spec: "") == nil)
    }

    @Test func usageAndVersionExitCleanly() async {
        #expect(await parityMain(["--help"]) == 0)
        #expect(await parityMain(["--version"]) == 0)
        #expect(await parityMain(["no-such-subcommand"]) == 2)
        #expect(await parityMain([]) == 2)
    }
}
