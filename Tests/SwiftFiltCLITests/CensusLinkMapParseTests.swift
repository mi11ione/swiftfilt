// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// LinkMap parse exactness against the real checked-in map and crafted hostile maps: ordinal mapping, dead-stripped separation, content-atom vocabulary, byte tiling, and the never-drop-a-line ledger.
@Suite("Census LinkMap parsing")
struct CensusLinkMapParseTests {
    private func harvestFixture() -> CensusHarvest {
        let bytes = fixtureBytes(censusFixturePath("LinkMap.txt"))
        let detected = CensusInput.detect(bytes, forced: nil)
        #expect(detected.format == .linkmap)
        return CensusInput.harvest(bytes, format: detected.format, reason: detected.reason)
    }

    private func harvest(_ text: String) -> CensusHarvest {
        CensusInput.harvest(Array(text.utf8), format: .linkmap, reason: "forced")
    }

    @Test func realMapParsesCompletely() {
        let harvest = harvestFixture()
        #expect(harvest.unparseableLines == 0)
        #expect(harvest.path == "build/census-fixture")
        #expect(harvest.arch == "arm64")
        #expect(harvest.sizesPresent)
        #expect(harvest.unknownOrdinalRows == 0)
        // Every line accounted for: structure + rows + dead == lines.
        #expect(harvest.structureLines + harvest.rows.count + harvest.deadRowCount == harvest.lines)
        // Row bytes were summed at parse time and match a re-sum.
        let resummed = harvest.rows.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }
        #expect(resummed == harvest.rowBytes)
    }

    @Test func realMapOrdinalsAllResolve() {
        let harvest = harvestFixture()
        // ld always emits `[  0] linker synthesized` first.
        #expect(harvest.objectFiles[0] == "linker synthesized")
        #expect(harvest.objectFiles[1] == "build/main.o")
        #expect(harvest.objectFiles.count >= 3)
    }

    @Test func realMapCarriesTheDeadStrippedPopulation() {
        let harvest = harvestFixture()
        // The fixture program's unspecialized generic `tally` is only
        // reachable through its specializations, so -dead_strip removes
        // it: it must be in the dead ledger and not in the live rows.
        #expect(harvest.deadRowCount > 10)
        #expect(harvest.deadRowBytes > 0)
        let unspecializedTally = "_$s13CensusFixture5tallyySixSlRzSQ7ElementRpzlF"
        #expect(!harvest.rows.contains { $0.name == unspecializedTally })
    }

    @Test func symbolRowParsesAddressSizeOrdinalName() {
        let row = harvest("""
        # Path: a
        # Symbols:
        0x100000A20\t0x00000018\t[  1] _main
        """)
        #expect(row.rows == [CensusRow(name: "_main", size: 0x18)])
        #expect(row.rowBytes == 0x18)
    }

    @Test func namesKeepTheirSpaces() {
        let harvest = harvest("""
        # Symbols:
        0x10\t0x08\t[  1] _symbolic _____ 13CensusFixture3BoxV
        0x18\t0x1B\t[  1] literal string: _TtC13CensusFixture6Ledger
        """)
        #expect(harvest.rows.map(\.name) == [
            "_symbolic _____ 13CensusFixture3BoxV",
            "literal string: _TtC13CensusFixture6Ledger",
        ])
    }

    @Test func deadRowsRequireTheDeadMarkerAndLiveRowsRequireHex() {
        let harvest = harvest("""
        # Symbols:
        <<dead>>\t0x08\t[  1] _wrong_section
        # Dead Stripped Symbols:
        0x10\t0x08\t[  1] _also_wrong
        <<dead>> \t0x0C\t[  1] _really_dead
        """)
        // Each mis-sectioned row is unparseable (counted), never guessed.
        #expect(harvest.unparseableLines == 2)
        #expect(harvest.rows.isEmpty)
        #expect(harvest.deadRowCount == 1)
        #expect(harvest.deadRowBytes == 0x0C)
    }

    @Test func hostileRowsAreCountedNeverDropped() {
        let harvest = harvest("""
        garbage before any header
        # Object files:
        [  1] build/main.o
        not an object file row
        # Symbols:
        0xNOTHEX\t0x08\t[  1] _a
        0x10\t0xZZ\t[  1] _b
        0x10\t0x08\tno ordinal here
        0x10\t0x08\t[  x] _c
        0x10\t0x08\t[  1]_nospace
        0x10\t0x08\t[  1]
        0x10 no tabs at all
        0x20\t0x04\t[  1] _real
        """)
        #expect(harvest.rows == [CensusRow(name: "_real", size: 4)])
        #expect(harvest.unparseableLines == 9)
        #expect(harvest.structureLines + harvest.unparseableLines + harvest.rows.count == harvest.lines)
    }

    @Test func unknownOrdinalsAreSurfaced() {
        let harvest = harvest("""
        # Object files:
        [  1] build/main.o
        # Symbols:
        0x10\t0x08\t[  9] _orphan
        0x18\t0x08\t[  1] _fine
        """)
        #expect(harvest.unknownOrdinalRows == 1)
        #expect(harvest.rows.count == 2)
        let run = runCLI(["census"], stdinText: """
        # Path: x
        # Object files:
        [  1] build/main.o
        # Symbols:
        0x10\t0x08\t[  9] _orphan
        """)
        #expect(run.stdout.contains("rows citing an object-file ordinal the map never declared: 1"))
    }

    @Test func negativeOrdinalsDoNotParse() {
        let harvest = harvest("""
        # Symbols:
        0x10\t0x08\t[ -1] _negative
        """)
        #expect(harvest.rows.isEmpty)
        #expect(harvest.unparseableLines == 1)
    }

    @Test func symbolRowWithoutASizeTabIsUnparseable() {
        // A live symbol row with a valid `0x…` address but only one tab —
        // no size column at all — does not parse; it is counted loudly,
        // never guessed at from a missing field.
        let harvest = harvest("""
        # Symbols:
        0x10\t[  1] _missing_size_column
        """)
        #expect(harvest.rows.isEmpty)
        #expect(harvest.unparseableLines == 1)
    }

    @Test func sectionTableAndUnknownHeadersAreStructure() {
        let harvest = harvest("""
        # Path: build/app
        # Arch: arm64
        # Future Section Nobody Knows:
        # Sections:
        # Address\tSize    \tSegment\tSection
        0x100000A20\t0x00000D34\t__TEXT\t__text
        # Symbols:
        0x10\t0x08\t[  1] _a

        """)
        #expect(harvest.rows.count == 1)
        #expect(harvest.unparseableLines == 0)
        #expect(harvest.structureLines == harvest.lines - 1)
    }

    @Test func contentAtomVocabularyIsGrounded() {
        // Every grounded ld64/ld-prime atom form buckets as content; an
        // unknown future form stays a (non-Swift) symbol row.
        for atom in [
            "literal string: hello world", "literal string: ",
            "_symbolic Sd", "_symbolic _____ 13CensusFixture3BoxV",
            "anon", "CIE", "CFString", "compact unwind info",
            "4-byte-literal", "8-byte-literal", "16-byte-literal",
            "FDE for: _main", "LSDA for: _main",
            "non-lazy-pointer-to-local: _foo", "lazy-pointer-to-local: _foo",
            "l_.str.13.CensusFixture", "l___unnamed_1", "l_entry_point", "ltmp12",
        ] {
            #expect(CensusTally.classify(atom, format: .linkmap) == .contentAtom, "\(atom) should be a content atom")
        }
        for symbol in ["_main", "16-byte-literals", "x-byte-literal", "anonymous", "l"] {
            #expect(CensusTally.classify(symbol, format: .linkmap) == .nonSwift, "\(symbol) should stay a symbol row")
        }
    }

    @Test func localLabelWrappingARealManglingIsSwiftNotAnAtom() {
        // The classifier must resolve `l_$s…Hr` records as Swift before
        // the `l…` local-label atom rule can swallow them.
        let classification = CensusTally.classify("l_$s13CensusFixture5ShapeHr", format: .linkmap)
        guard case let .swift(symbol) = classification else {
            Issue.record("l_$s…Hr should classify as Swift, got \(classification)")
            return
        }
        #expect(symbol.module == "CensusFixture")
        let run = runCLI(["census", "--json"], stdinText: """
        # Path: x
        # Symbols:
        0x10\t0x04\t[  0] l_$s13CensusFixture5ShapeHr
        """)
        #expect(run.stdout.contains("\"swift\":1"))
        #expect(run.stdout.contains("\"contentAtoms\":0"))
    }

    @Test func malformedSwiftPrefixedRowsAreTheirOwnBucket() {
        // `$s` alone is the DemangleError documentation's own canonical
        // malformed case: the prefix is present, nothing parses.
        let run = runCLI(["census", "--json"], stdinText: """
        # Path: x
        # Symbols:
        0x10\t0x20\t[  0] _$s
        0x30\t0x10\t[  0] _$s4main3fooyyF
        """)
        #expect(run.stdout.contains("\"malformed\":1,\"malformedBytes\":32"))
        #expect(run.stdout.contains("\"swift\":1,\"swiftBytes\":16"))
    }

    @Test func hostileSizesSaturateInsteadOfTrapping() {
        // Sizes that overflow a UInt64 sum saturate — deterministically,
        // on both the harvest side and the classification side (a
        // saturating sum of the same values is order-independent), so
        // the books still balance and the absurd input yields an absurd
        // but honest report instead of a trap.
        let run = runCLI(["census", "--json"], stdinText: """
        # Path: x
        # Symbols:
        0x10\t0xFFFFFFFFFFFFFFF0\t[  0] _a
        0x20\t0xFFFFFFFFFFFFFFF0\t[  0] _b
        0x30\t0xFFFFFFFFFFFFFFF0\t[  0] _$s4main3fooyyF
        """)
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stderr.isEmpty)
        #expect(run.stdout.contains("\"rowBytes\":18446744073709551615"))
        #expect(run.stdout.contains("\"nonSwiftBytes\":18446744073709551615"))
    }

    @Test func oversizedSizeFieldsDoNotParse() {
        // A size wider than 64 bits is a corrupt row, counted loudly.
        let harvest = harvest("""
        # Symbols:
        0x10\t0xFFFFFFFFFFFFFFFFF\t[  0] _too_big
        """)
        #expect(harvest.rows.isEmpty)
        #expect(harvest.unparseableLines == 1)
    }

    @Test func forcedLinkMapOnGarbageCountsEveryLineUnparseable() {
        let run = runCLI(["census", "--json", "--format", "linkmap"], stdinText: "just\nsome\nprose\n")
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.contains("\"unparseableLines\":3"))
        #expect(run.stdout.contains("\"rows\":0"))
    }

    @Test func linkMapWithoutPathOrArchRendersPlaceholders() {
        let run = runCLI(["census", "--format", "linkmap"], stdinText: """
        # Symbols:
        0x10\t0x08\t[  0] _$s4main3fooyyF
        """)
        #expect(run.stdout.contains("(no # Path: header) (unknown arch), 0 object files"))
    }
}
