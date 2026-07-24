// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltCLICore
import Testing

/// The census's self-consistency contract: on every fixture the tally's books balance (each table tiles to its totals); a doctored imbalance is named, reported to stderr, and refuses to print a report (exit 1).
@Suite("Census invariants")
struct CensusInvariantTests {
    private func harvestAndTally(_ path: String, format: CensusFormat) -> (CensusHarvest, CensusTally) {
        let bytes = fixtureBytes(path)
        let harvest = CensusInput.harvest(bytes, format: format, reason: "test")
        return (harvest, CensusTally.tally(harvest))
    }

    @Test(arguments: [
        ("LinkMap.txt", CensusFormat.linkmap),
        ("nm.txt", CensusFormat.nm),
        ("nm-sized.txt", CensusFormat.nm),
    ])
    func fixtureBooksBalance(fixture: (String, CensusFormat)) {
        let (harvest, tally) = harvestAndTally(censusFixturePath(fixture.0), format: fixture.1)
        #expect(tally.violations(against: harvest).isEmpty)
        // The classification buckets tile to the row population.
        #expect(tally.swift.count + tally.nonSwift.count + tally.malformed.count
            + tally.contentAtoms.count == harvest.rows.count)
        #expect(tally.swift.bytes + tally.nonSwift.bytes + tally.malformed.bytes
            + tally.contentAtoms.bytes == harvest.rowBytes)
        // Every table tiles to the swift totals.
        for table in [tally.kinds, tally.modules, tally.identities] {
            #expect(table.values.reduce(0) { $0 + $1.count } == tally.swift.count)
            #expect(table.values.reduce(UInt64(0)) { $0 + $1.bytes } == tally.swift.bytes)
        }
        #expect(tally.machinery.count + tally.human.count == tally.swift.count)
        #expect(tally.specializations.values.reduce(0) { $0 + $1.count }
            + tally.unattributedSpecializations.count == tally.specialized.count)
    }

    @Test func bareBooksBalance() {
        let (harvest, tally) = harvestAndTally(cliInputPath("crash-log.txt"), format: .bare)
        #expect(tally.violations(against: harvest).isEmpty)
        #expect(tally.swift.count == harvest.rows.count)
        #expect(tally.nonSwift.count == 0)
    }

    @Test func bareFormatHasNoContentAtoms() {
        // Content atoms are a structured-format concept (ld maps, nm object
        // dumps); bare text has no atom vocabulary, so even an atom-looking
        // name is a plain non-Swift row when the format is bare.
        #expect(CensusTally.classify("anon", format: .bare) == .nonSwift)
        #expect(CensusTally.classify("_symbolic Sd", format: .bare) == .nonSwift)
        #expect(CensusTally.classify("literal string: x", format: .bare) == .nonSwift)
    }

    @Test func degenerateStackedSpecializationIsUnattributed() {
        // A stacked specialization with no recoverable base entity — two
        // distinct specialization markers and nothing else. swift-demangle
        // agrees it is a specialization ("representation changed of generic
        // specialization <Swift.Int> of ") whose origin does not render, so
        // it belongs in the unattributed residue: counted as specialized,
        // absent from the origin table, and the books still balance.
        let text = "0000000104abc120 T _$sSi_Tg5Tfr0\n"
        let harvest = CensusInput.harvest(Array(text.utf8), format: .nm, reason: "test")
        let tally = CensusTally.tally(harvest)
        #expect(tally.swift.count == 1)
        #expect(tally.specialized.count == 1)
        #expect(tally.unattributedSpecializations.count == 1)
        #expect(tally.specializations.isEmpty)
        #expect(tally.violations(against: harvest).isEmpty)
    }

    @Test func everyDoctoredImbalanceIsNamed() {
        let (harvest, balanced) = harvestAndTally(censusFixturePath("LinkMap.txt"), format: .linkmap)
        // Each mutation breaks exactly the invariant its message names.
        var t = balanced
        t.swift.count += 1
        var violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("classification does not tile") })

        t = balanced
        t.nonSwift.bytes += 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("byte tiling broken") })

        t = balanced
        t.kinds["function"]?.count += 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("kind table count does not tile") })

        t = balanced
        t.kinds["function"]?.bytes += 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("kind table bytes do not tile") })

        t = balanced
        t.modules["Swift"]?.count += 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("module table count does not tile") })

        t = balanced
        t.modules["Swift"]?.bytes += 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("module table bytes do not tile") })

        t = balanced
        t.identities = [:]
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("identity table count does not tile") })
        #expect(violations.contains { $0.contains("identity table bytes do not tile") })

        t = balanced
        t.machinery.count -= 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("machinery/human split count does not tile") })

        t = balanced
        t.human.bytes += 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("machinery/human split bytes do not tile") })

        t = balanced
        t.specialized.count += 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("specialization table count does not tile") })

        t = balanced
        t.specialized.bytes += 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("specialization table bytes do not tile") })

        t = balanced
        t.embeddedMangling.count = t.nonSwift.count + 1
        violations = t.violations(against: harvest)
        #expect(violations.contains { $0.contains("embedded-mangling count exceeds") })
    }

    @Test func lineLedgerImbalanceIsNamed() {
        let (harvest, tally) = harvestAndTally(censusFixturePath("nm.txt"), format: .nm)
        var broken = harvest
        broken.structureLines += 1
        let violations = tally.violations(against: broken)
        #expect(violations.contains { $0.contains("line ledger does not tile") })
    }

    @Test func lineLedgerIsNotCheckedForBareText() {
        // Bare rows are scanner matches, not lines; the ledger tiling is
        // a structured-format contract only.
        let (harvest, tally) = harvestAndTally(cliInputPath("crash-log.txt"), format: .bare)
        var reframed = harvest
        reframed.lines += 5
        #expect(tally.violations(against: reframed).isEmpty)
    }

    @Test func unbalancedBooksRefuseToPrintAndExitOne() {
        let (harvest, balanced) = harvestAndTally(censusFixturePath("LinkMap.txt"), format: .linkmap)
        var doctored = balanced
        doctored.swift.count += 1
        var out: [UInt8] = []
        var err = ""
        let status = CensusCommand.emit(
            harvest: harvest, tally: doctored, invocation: CensusInvocation(),
            writeOutput: { out.append(contentsOf: $0) },
            writeError: { err += $0 },
            standardOutputIsTTY: false,
        )
        #expect(status == CLI.exitInternalError)
        #expect(out.isEmpty, "an unbalanced census must never print a report")
        #expect(err.contains("census internal accounting error: classification does not tile"))
        #expect(err.contains("a bug in swiftfilt, not in your input"))
    }

    @Test func balancedBooksEmitExactlyOnePayload() {
        let (harvest, tally) = harvestAndTally(censusFixturePath("LinkMap.txt"), format: .linkmap)
        var writes = 0
        var err = ""
        let status = CensusCommand.emit(
            harvest: harvest, tally: tally, invocation: CensusInvocation(json: true),
            writeOutput: { _ in writes += 1 },
            writeError: { err += $0 },
            standardOutputIsTTY: false,
        )
        #expect(status == CLI.exitSuccess)
        #expect(writes == 1)
        #expect(err.isEmpty)
    }

    // MARK: Linker plumbing and the duplication table

    @Test func stubAndGotRowsSplitOutOfTheDuplicationTable() {
        // One function, its `.stub`, and its `.got` slot: one logical
        // identity, three physical atoms — the duplication table must not
        // call the plumbing pair "copies", and the plumbing bucket must
        // count exactly the suffixed rows.
        var builder = CensusTally.Builder(format: .nm)
        builder.add(name: "_$s4main3fooyyF", sizeBytes: 100)
        builder.add(name: "_$s4main3fooyyF.stub", sizeBytes: 12)
        builder.add(name: "_$s4main3fooyyF.got", sizeBytes: 8)
        let tally = builder.finish()
        #expect(tally.swift.count == 3)
        #expect(tally.linkerPlumbing.count == 2)
        #expect(tally.linkerPlumbing.bytes == 20)
        #expect(tally.identities.count == 3, "identity + suffix keys three atoms apart")
        #expect(tally.identities.values.allSatisfy { $0.count == 1 })
    }

    @Test func genuineDuplicationStillGroups() {
        // The same physical name twice (ld's real duplicated-code case)
        // still folds to one identity with two copies.
        var builder = CensusTally.Builder(format: .linkmap)
        builder.add(name: "_$s4main3fooyyF", sizeBytes: 100)
        builder.add(name: "_$s4main3fooyyF", sizeBytes: 100)
        let tally = builder.finish()
        #expect(tally.identities.count == 1)
        #expect(tally.identities.values.first?.count == 2)
        #expect(tally.linkerPlumbing.count == 0)
    }

    // MARK: Implausible sizes are surfaced, never silent

    @Test func implausibleSizesWarnInReportAndJSON() {
        let linkMap = """
        # Path: /tmp/adv
        # Arch: arm64
        # Object files:
        [  0] /tmp/adv.o
        # Symbols:
        # Address\tSize    \tFile  Name
        0x100000000\t0xFFFFFFFFFFFFFFFF\t[  0] _$s4main3fooyyF
        0x100000010\t0x0000000000000010\t[  0] _$s4main3baryyF
        """
        let run = runCLI(["census", "--color", "never"], stdin: Array(linkMap.utf8))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.contains("IMPLAUSIBLE row sizes"))
        let json = runCLI(["census", "--json"], stdin: Array(linkMap.utf8))
        #expect(json.stdout.contains("\"implausibleSizes\":1"))
    }

    @Test func corruptedPlumbingSubsetReportsItsViolation() {
        // The linker-plumbing bucket is checked as a subset of swift; a
        // corrupted count surfaces its named violation, never silence.
        var builder = CensusTally.Builder(format: .nm)
        builder.add(name: "_$s4main3fooyyF", sizeBytes: nil)
        var tally = builder.finish()
        tally.linkerPlumbing.add(bytes: 0)
        tally.linkerPlumbing.add(bytes: 0)
        var harvest = CensusHarvest(format: .nm, detectionReason: "test")
        harvest.lines = 1
        harvest.rowCount = 1
        #expect(tally.violations(against: harvest).contains {
            $0.contains("linker-plumbing count exceeds the swift rows")
        })
    }

    @Test func countWeightedPlumbingLineRenders() {
        // An unsized nm listing with stub/got rows: the plumbing line
        // renders count-weighted.
        let nm = """
        0000000000000001 t _$s4main3fooyyF
        0000000000000002 t _$s4main3fooyyF.stub
        0000000000000003 t _$s4main3fooyyF.got
        """
        let run = runCLI(["census", "--format", "nm", "--color", "never"], stdin: Array(nm.utf8))
        #expect(run.status == CLI.exitSuccess)
        #expect(run.stdout.contains("linker plumbing (.stub/.got import glue) among swift rows: 2"))
    }

    @Test func duplicateTableOrdersByBytesThenName() {
        // Two 2-copy identities with equal counts but different bytes
        // (byte tiebreak), and two with identical weights (name
        // tiebreak) — the ranking comparator's full ordering, pinned.
        let linkMap = """
        # Path: /tmp/order
        # Arch: arm64
        # Object files:
        [  0] /tmp/order.o
        # Symbols:
        # Address\tSize    \tFile  Name
        0x100000000\t0x0000000000000010\t[  0] _$s4main1ayyF
        0x100000010\t0x0000000000000010\t[  0] _$s4main1ayyF
        0x100000020\t0x0000000000000020\t[  0] _$s4main1byyF
        0x100000040\t0x0000000000000020\t[  0] _$s4main1byyF
        0x100000060\t0x0000000000000010\t[  0] _$s4main1cyyF
        0x100000070\t0x0000000000000010\t[  0] _$s4main1cyyF
        """
        let run = runCLI(["census", "--color", "never"], stdin: Array(linkMap.utf8))
        #expect(run.status == CLI.exitSuccess)
        let b = run.stdout.range(of: "main.b() -> ()")
        let a = run.stdout.range(of: "main.a() -> ()")
        let c = run.stdout.range(of: "main.c() -> ()")
        #expect(b != nil && a != nil && c != nil)
        if let b, let a, let c {
            #expect(b.lowerBound < a.lowerBound, "more bytes ranks first at equal counts")
            #expect(a.lowerBound < c.lowerBound, "equal weights order by name")
        }
    }
}
