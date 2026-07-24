// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The parallel census referee: a sharded census (any thread count) is byte-identical to
// the single-threaded pipeline, in report and JSON, across the line-independent formats —
// the invariant is that `--jobs` changes only WHERE the per-row demangle happens, never a
// number. Plus the merge algebra (associative tally + additive harvest, sizeless-shard edge),
// the line-aligned shard splitter, and the parallelize-or-not dispatch.

import SwiftFilt
import SwiftFiltCLICore
import Testing

@Suite("Parallel census")
struct ParallelCensusTests {
    /// A diverse symbol set that lands rows in many classification buckets:
    /// functions, a variable, type metadata, a specialization, a non-Swift C
    /// name, a malformed Swift-prefixed name, and a content-atom label.
    private static let symbols = [
        "$s4main3fooyyF", "$s4main3baryyF", "$s4main1xSivp", "$s4main1PP",
        "$s4main5ThingVMn", "$sSiN", "$s4main7GenericVyxGMa", "_platform_memmove",
        "$sSSXX", "l_.str.7", "$s4main8consumeryyF", "$s4main1yyyF",
    ]

    /// An `nm --print-size` dump: `address size type name`, with a contiguous
    /// block of undefined (`U`, sizeless) rows so a small-shard split can
    /// isolate an all-sizeless shard — the one case the harvest merge must
    /// re-gate `rowsWithoutSize` for.
    private func nmDump(rows: Int) -> [UInt8] {
        func hex(_ value: Int, width: Int) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        var lines: [String] = []
        var address = 0x1000
        for i in 0 ..< rows {
            let symbol = Self.symbols[i % Self.symbols.count]
            if (200 ..< 260).contains(i) {
                lines.append("                 U \(symbol)") // undefined block (sizeless)
            } else {
                let size = (i * 7 % 4096) + 1
                lines.append("\(hex(address, width: 16)) \(hex(size, width: 4)) t \(symbol)")
                address += size
            }
        }
        return Array((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Bare text: crash-frame-shaped lines carrying manglings.
    private func bareText(rows: Int) -> [UInt8] {
        var lines: [String] = []
        for i in 0 ..< rows {
            lines.append("\(i)  MyApp  0x0010\(String(i, radix: 16))  \(Self.symbols[i % Self.symbols.count]) + \(i)")
        }
        return Array((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func rendered(_ result: (harvest: CensusHarvest, tally: CensusTally)) -> (report: String, json: String) {
        let report = CensusReport.render(
            harvest: result.harvest, tally: result.tally, top: 25, palette: Palette(enabled: false),
        )
        let json = JSONText.censusLines(harvest: result.harvest, tally: result.tally, slim: false).joined(separator: "\n")
        return (report, json)
    }

    // MARK: Byte-identity — the core invariant

    @Test(arguments: [CensusFormat.nm, CensusFormat.bare])
    func shardedIsByteIdenticalToSequential(_ format: CensusFormat) {
        let bytes = format == .nm ? nmDump(rows: 3000) : bareText(rows: 3000)
        let reason = "test"
        let sequential = CensusInput.harvestAndTally(bytes, format: format, reason: reason)
        // Small `minShardBytes` forces a real multi-shard split on a modest
        // fixture; several workers exercise the multi-way merge.
        let pool = InlineWorkerPool(workerCount: 7)
        let parallel = ParallelCensus.harvestAndTally(
            bytes, format: format, reason: reason, pool: pool, minShardBytes: 200,
        )
        // The tally has no size column for bare, sizes for nm; both must match.
        let (seqReport, seqJSON) = rendered(sequential)
        let (parReport, parJSON) = rendered(parallel)
        #expect(parReport == seqReport)
        #expect(parJSON == seqJSON)
        // The books must still balance on the merged result.
        #expect(parallel.tally.violations(against: parallel.harvest).isEmpty)
        // The split actually happened (more than one shard ran).
        #expect(pool.rounds.contains { $0 >= 2 })
    }

    // MARK: Shard splitter

    @Test func shardRangesReturnsOneRangeWhenTooSmallToSplit() {
        let bytes = Array("a\nb\nc\n".utf8)
        // minShardBytes large relative to input ⇒ ideal < 2 ⇒ one range.
        #expect(ParallelCensus.shardRanges(bytes, workers: 8, minShardBytes: 1 << 20) == [0 ..< bytes.count])
    }

    @Test func shardRangesCutsOnlyAtLineBoundaries() {
        // Ten 8-byte lines; small min forces several shards. Every cut must
        // land just after a '\n', so each range starts a fresh line.
        let bytes = Array((0 ..< 10).map { "line\($0)0" }.joined(separator: "\n").utf8) + [UInt8(ascii: "\n")]
        let ranges = ParallelCensus.shardRanges(bytes, workers: 4, minShardBytes: 8)
        #expect(ranges.count >= 2)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == bytes.count)
        // Contiguous, non-overlapping cover.
        for i in 1 ..< ranges.count {
            #expect(ranges[i].lowerBound == ranges[i - 1].upperBound)
            // Each interior cut sits right after a newline.
            #expect(bytes[ranges[i].lowerBound - 1] == UInt8(ascii: "\n"))
        }
    }

    @Test func shardRangesFallsBackToOneRangeForAGiantSingleLine() {
        // No interior newline to cut on: the ideal points all run off the end,
        // so no interior cut is taken and the whole input is one range.
        let bytes = Array(String(repeating: "x", count: 5000).utf8)
        #expect(ParallelCensus.shardRanges(bytes, workers: 8, minShardBytes: 100) == [0 ..< bytes.count])
    }

    @Test func harvestAndTallyFallsBackWhenInputDoesNotSplit() {
        // ranges.count < 2 ⇒ the executor runs the sequential pipeline.
        let bytes = nmDump(rows: 5)
        let pool = InlineWorkerPool(workerCount: 8)
        let parallel = ParallelCensus.harvestAndTally(
            bytes, format: .nm, reason: "test", pool: pool, minShardBytes: 1 << 20,
        )
        let sequential = CensusInput.harvestAndTally(bytes, format: .nm, reason: "test")
        #expect(rendered(parallel).report == rendered(sequential).report)
        #expect(pool.rounds.isEmpty) // never handed jobs
    }

    // MARK: Format support

    @Test func supportsTheLineIndependentFormatsOnly() {
        #expect(ParallelCensus.supports(.bare))
        #expect(ParallelCensus.supports(.nm))
        #expect(!ParallelCensus.supports(.linkmap))
    }

    // MARK: Merge algebra

    @Test func weightCombineAddsCountsAndBytes() {
        var a = CensusWeight(count: 2, bytes: 10)
        a.combine(CensusWeight(count: 3, bytes: 5))
        #expect(a == CensusWeight(count: 5, bytes: 15))
    }

    @Test func tallyMergeIsTheUnionOfTwoDisjointTallies() {
        var left = CensusTally.Builder(format: .nm)
        left.add(name: "$s4main3fooyyF", sizeBytes: 10)
        var right = CensusTally.Builder(format: .nm)
        right.add(name: "$s4main3baryyF", sizeBytes: 20)
        right.add(name: "$s4main3fooyyF", sizeBytes: 5)
        let merged = left.finish().merged(with: right.finish())
        // One tally built from all three rows in one Builder is the reference.
        var whole = CensusTally.Builder(format: .nm)
        whole.add(name: "$s4main3fooyyF", sizeBytes: 10)
        whole.add(name: "$s4main3baryyF", sizeBytes: 20)
        whole.add(name: "$s4main3fooyyF", sizeBytes: 5)
        let reference = whole.finish()
        #expect(merged.swift == reference.swift)
        #expect(merged.modules == reference.modules)
        #expect(merged.identities == reference.identities)
        #expect(merged.machinery == reference.machinery && merged.human == reference.human)
    }

    @Test func harvestMergeReGatesRowsWithoutSizeAcrossAnUnsizedShard() {
        // A sized shard (rowsWithoutSize == 1 of 3) merged with a shard that
        // carried no sizes at all (so its own rowsWithoutSize is 0 by
        // definition, though all 4 of its rows are unsized). The union has
        // sizes present, so the merged rowsWithoutSize must count all 5
        // unsized rows (1 + 4), not 1.
        var sized = CensusHarvest(format: .nm, detectionReason: "test")
        sized.rowCount = 3
        sized.sizesPresent = true
        sized.rowsWithoutSize = 1
        var unsized = CensusHarvest(format: .nm, detectionReason: "test")
        unsized.rowCount = 4
        unsized.sizesPresent = false
        unsized.rowsWithoutSize = 0
        let merged = sized.merged(with: unsized)
        #expect(merged.sizesPresent)
        #expect(merged.rowCount == 7)
        #expect(merged.rowsWithoutSize == 5)
        // Two unsized shards merge to sizesPresent == false, rowsWithoutSize 0.
        let bothUnsized = unsized.merged(with: unsized)
        #expect(!bothUnsized.sizesPresent)
        #expect(bothUnsized.rowsWithoutSize == 0)
    }

    @Test func harvestMergeCarriesLinkmapFieldsTotally() {
        // The merge is total: it carries the linkmap-only fields even though
        // the executor only ever merges the bare/nm formats (where they are
        // empty), so no field is silently dropped.
        var left = CensusHarvest(format: .linkmap, detectionReason: "test")
        left.path = "/bin/app"
        left.objectFiles = [0: "a.o"]
        left.deadRowCount = 2
        left.deadRowBytes = 40
        var right = CensusHarvest(format: .linkmap, detectionReason: "test")
        right.arch = "arm64"
        right.objectFiles = [1: "b.o"]
        right.unknownOrdinalRows = 3
        let merged = left.merged(with: right)
        #expect(merged.path == "/bin/app")
        #expect(merged.arch == "arm64")
        #expect(merged.objectFiles == [0: "a.o", 1: "b.o"])
        #expect(merged.deadRowCount == 2 && merged.deadRowBytes == 40)
        #expect(merged.unknownOrdinalRows == 3)
    }

    // MARK: Parallelize-or-not dispatch (CensusCommand.harvestAndTally)

    private func dispatch(
        jobs: Int?, format: CensusFormat, pool factory: ((Int) -> FilterWorkerPool?)?,
    ) -> (harvest: CensusHarvest, tally: CensusTally) {
        let bytes = format == .linkmap ? linkMapBytes : nmDump(rows: 40)
        var invocation = CensusInvocation()
        invocation.jobs = jobs
        return CensusCommand.harvestAndTally(
            bytes, detected: (format, "test"), invocation: invocation, makeWorkerPool: factory,
        )
    }

    private let linkMapBytes = Array("""
    # Path: /bin/app
    # Arch: arm64
    # Object files:
    [  0] /a.o
    # Symbols:
    0x1000\t0x10\t[  0] _$s4main3fooyyF
    """.utf8)

    @Test func dispatchGoesSequentialWhenJobsIsOne() {
        // A pool is offered but --jobs 1 forces the single-threaded path.
        let pool = InlineWorkerPool(workerCount: 8)
        _ = dispatch(jobs: 1, format: .nm, pool: { _ in pool })
        #expect(pool.rounds.isEmpty)
    }

    @Test func dispatchGoesSequentialForLinkmap() {
        let pool = InlineWorkerPool(workerCount: 8)
        let result = dispatch(jobs: nil, format: .linkmap, pool: { _ in pool })
        #expect(pool.rounds.isEmpty)
        #expect(result.harvest.format == .linkmap)
    }

    @Test func dispatchGoesSequentialWithNoPoolFactory() {
        // No makeWorkerPool at all ⇒ sequential (the library-embedded caller).
        let result = dispatch(jobs: nil, format: .nm, pool: nil)
        #expect(!result.harvest.format.rawValue.isEmpty)
    }

    @Test func dispatchGoesSequentialWhenTheFactoryDeclines() {
        // A factory that returns nil (platform could not build a pool).
        _ = dispatch(jobs: 4, format: .nm, pool: { _ in nil })
    }

    @Test func dispatchGoesSequentialWithASingleWorker() {
        let pool = InlineWorkerPool(workerCount: 1)
        _ = dispatch(jobs: nil, format: .nm, pool: { _ in pool })
        #expect(pool.rounds.isEmpty)
    }

    @Test func dispatchEngagesTheParallelPathWhenAllConditionsHold() {
        // jobs != 1, nm, pool with >= 2 workers ⇒ the executor runs (it may
        // still fall back internally on this small input; the branch is taken).
        let pool = InlineWorkerPool(workerCount: 4)
        let result = dispatch(jobs: 4, format: .nm, pool: { _ in pool })
        #expect(result.tally.violations(against: result.harvest).isEmpty)
    }
}
