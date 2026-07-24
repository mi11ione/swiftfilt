// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// nm-shape parsing: BSD/llvm-nm unsized rows, `--print-size` sized rows, undefined rows, the size-vs-type-character ambiguity (single hex letters are types, never sizes), and the honesty counters for mixed dumps.
@Suite("Census nm parsing")
struct CensusNmParseTests {
    private func harvest(_ text: String) -> CensusHarvest {
        CensusInput.harvest(Array(text.utf8), format: .nm, reason: "forced")
    }

    @Test func unsizedRowsParseAddressTypeName() {
        let harvest = harvest("0000000104abc120 T _$s4main3fooyyF\n")
        #expect(harvest.rows == [CensusRow(name: "_$s4main3fooyyF", size: nil)])
        #expect(!harvest.sizesPresent)
        #expect(harvest.rowsWithoutSize == 0)
    }

    @Test func sizedRowsParseTheSizeColumn() {
        let harvest = harvest("0000000000001139 0000000000000010 T _foo\n")
        #expect(harvest.rows == [CensusRow(name: "_foo", size: 0x10)])
        #expect(harvest.sizesPresent)
    }

    @Test func undefinedRowsHaveNoAddressAndAreCounted() {
        let harvest = harvest("""
                         U _swift_retain
        0000000104ac0340 T _main
                         u _weak_thing
        """)
        #expect(harvest.rows.count == 3)
        #expect(harvest.undefinedRows == 2)
    }

    @Test func singleHexLetterIsATypeCharacterNeverASize() {
        // `d`/`b`/`a`/`c` are both hex digits and nm type classes; the
        // one-letter second field must parse as the type.
        let harvest = harvest("0000000100008000 d _$s4main3barSivpZ\n")
        #expect(harvest.rows == [CensusRow(name: "_$s4main3barSivpZ", size: nil)])
        #expect(!harvest.sizesPresent)
    }

    @Test func namesKeepTheirSpaces() {
        let harvest = harvest("0000000100001924 s _symbolic _____ 13CensusFixture3BoxV\n")
        #expect(harvest.rows.map(\.name) == ["_symbolic _____ 13CensusFixture3BoxV"])
    }

    @Test func mixedSizedDumpCountsTheSizelessRows() {
        let harvest = harvest("""
        0000000000001139 0000000000000010 T _foo
                         U _swift_retain
        """)
        #expect(harvest.sizesPresent)
        #expect(harvest.rowsWithoutSize == 1)
        #expect(harvest.rowBytes == 0x10)
    }

    @Test func archHeadersAndBlanksAreStructure() {
        let harvest = harvest("""
        MyApp (for architecture arm64):
        0000000104ac0340 T _main

        MyApp (for architecture arm64e):
        0000000104ac0340 T _main
        """)
        #expect(harvest.rows.count == 2)
        #expect(harvest.structureLines == 3)
        #expect(harvest.unparseableLines == 0)
    }

    @Test func garbageLinesAreCountedUnparseable() {
        let harvest = harvest("""
        0000000104ac0340 T _main
        prose that is not a row
        0000 ZZ T _bad_size_and_not_a_type
        0000000104ac0340 Tx _no_space_after_type
        0000000104ac0340 T
        nonhex!! T _x
        """)
        #expect(harvest.rows.count == 1)
        #expect(harvest.unparseableLines == 5)
        #expect(harvest.structureLines + harvest.unparseableLines + harvest.rows.count == harvest.lines)
    }

    @Test func degenerateTypeAndNameShapesAreCountedUnparseable() {
        // The type-and-name guards are each reachable, never dropped:
        // a non-type first character in the undefined (no-address) shape,
        let nonTypeCharacter = harvest("  9 not_a_symbol_type_char\n")
        #expect(nonTypeCharacter.rows.isEmpty)
        #expect(nonTypeCharacter.unparseableLines == 1)
        // and a valid type character followed by a space but an empty name
        // (the line ends right after `<type> `).
        let emptyName = harvest("0000000104ac0340 T" + " " + "\n")
        #expect(emptyName.rows.isEmpty)
        #expect(emptyName.unparseableLines == 1)
    }

    @Test func archHeaderProbeHandlesShortAndUnmatchedParentheticalLines() {
        // The fat-binary arch-header probe runs its substring search only
        // on lines ending `):`. That search must handle a line shorter
        // than the ` (for architecture ` needle (the short arm) and a long
        // line that never matches (the no-match arm); neither is an arch
        // header, so each falls through and counts as an unparseable row.
        let shorterThanNeedle = harvest("x):\n")
        #expect(shorterThanNeedle.rows.isEmpty)
        #expect(shorterThanNeedle.unparseableLines == 1)
        #expect(shorterThanNeedle.structureLines == 0)
        let longButUnmatched = harvest("an ordinary parenthesized group):\n")
        #expect(longButUnmatched.rows.isEmpty)
        #expect(longButUnmatched.unparseableLines == 1)
        #expect(longButUnmatched.structureLines == 0)
    }

    @Test func oversizedSizeFieldFallsBackToAnUnsizedRow() {
        // A 17+-hex-digit "size" cannot be a UInt64; the row still
        // counts (type char + name parse), weighed as size-less — a row
        // is never dropped for a bad number.
        let harvest = harvest("""
        0000000000001139 0000000000000010 T _foo
        0000000000002000 FFFFFFFFFFFFFFFFF T _huge
        """)
        #expect(harvest.rows.count == 2)
        #expect(harvest.rows[1] == CensusRow(name: "_huge", size: nil))
        #expect(harvest.rowsWithoutSize == 1)
    }

    @Test func elfStyleNamesWithoutUnderscoresClassify() {
        // ELF symbol tables carry no Mach-O underscore: bare `$s…` still
        // demangles, and a C name starting with `l` must remain a
        // non-Swift symbol (the `l…` local-label atom rule is
        // linkmap-only vocabulary).
        let run = runCLI(["census", "--json"], stdinText: """
        0000000000001139 0000000000000010 T $s4main3fooyyF
        0000000000002000 0000000000000020 T lstat
        0000000000003000 0000000000000008 t ltmp99
        """)
        #expect(run.stdout.contains("\"swift\":1,\"swiftBytes\":16"))
        #expect(run.stdout.contains("\"nonSwift\":2"))
        #expect(run.stdout.contains("\"contentAtoms\":0"))
    }

    @Test func nmSymbolicAtomsAreTheOneNmContentForm() {
        #expect(CensusTally.classify("_symbolic Sd", format: .nm) == .contentAtom)
        #expect(CensusTally.classify("anon", format: .nm) == .nonSwift)
        #expect(CensusTally.classify("literal string: x", format: .nm) == .nonSwift)
    }

    @Test func realNmFixtureParsesCompletely() {
        let harvest = harvest(fixtureString(censusFixturePath("nm.txt")))
        #expect(harvest.unparseableLines == 0)
        #expect(harvest.undefinedRows > 10)
        #expect(!harvest.sizesPresent)
        #expect(harvest.structureLines + harvest.rows.count == harvest.lines)
    }

    @Test func realSizedNmFixtureParsesCompletely() {
        let harvest = harvest(fixtureString(censusFixturePath("nm-sized.txt")))
        #expect(harvest.unparseableLines == 0)
        #expect(harvest.sizesPresent)
        #expect(harvest.undefinedRows == 4)
        #expect(harvest.rowsWithoutSize == 4)
        let resummed = harvest.rows.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }
        #expect(resummed == harvest.rowBytes)
    }

    @Test func sizedAndUnsizedDumpsOfTheSameBinaryAgreeOnTheSwiftPopulation() {
        // nm-sized.txt is generated from the LinkMap's live rows; the
        // linkmap census and the sized-nm census must agree on the
        // total Swift byte count (same names, same sizes).
        let map = fixtureBytes(censusFixturePath("LinkMap.txt"))
        let mapHarvest = CensusInput.harvest(map, format: .linkmap, reason: "")
        let sized = fixtureBytes(censusFixturePath("nm-sized.txt"))
        let sizedHarvest = CensusInput.harvest(sized, format: .nm, reason: "")
        let mapTally = CensusTally.tally(mapHarvest)
        let sizedTally = CensusTally.tally(sizedHarvest)
        #expect(mapTally.swift.bytes == sizedTally.swift.bytes)
        #expect(mapTally.machinery.bytes == sizedTally.machinery.bytes)
    }
}
