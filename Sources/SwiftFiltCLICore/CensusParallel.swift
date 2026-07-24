// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Parallel census for the line-independent formats. The per-row demangle
// (the dominant cost of a census) is embarrassingly parallel and the
// aggregation type is an associative monoid, so the input splits into
// line-aligned byte shards, each worker harvests+tallies its shard into its
// own (harvest, tally), and the results merge. The merged result is
// byte-identical to the single-threaded fused pipeline over the whole input:
// the tally cells/tables and the harvest ledgers are additive, so every
// `violations(against:)` invariant is preserved, and the report ranks
// deterministically by weight then name — independent of shard order.

import SwiftFilt

/// The parallel census executor for `bare` and `nm`.
///
/// `linkmap` is deliberately NOT parallelized here: its parse carries a
/// section state machine (`preamble → objectFiles → sections → symbols →
/// deadStripped`) and forward object-file-ordinal references, so a byte-range
/// split would corrupt both, and a parse-then-classify split would reintroduce
/// the per-row staging array the fused pipeline was built to eliminate. Bare
/// and nm are line-independent (a candidate never crosses `\n`), so they shard
/// at line boundaries with no such coupling — and they are the streaming
/// formats where the no-staging memory win matters most.
public enum ParallelCensus {
    /// The smallest shard worth a worker (mirrors the filter's per-worker
    /// target): an input below `2 ×` this stays single-threaded, since the
    /// fork/copy/merge overhead would swamp the per-row saving.
    public static let minShardBytes = 256 << 10

    /// Whether `format` is one this executor handles (the line-independent
    /// formats); `linkmap` is parsed single-threaded.
    public static func supports(_ format: CensusFormat) -> Bool {
        format == .bare || format == .nm
    }

    /// Line-aligned shard ranges over `bytes`: each range is a whole number
    /// of complete lines (cuts land just past a `\n`), at most `workers` of
    /// them. Returns a single whole-input range when the input is too small
    /// to split into two, or when it has no interior line boundary to cut on
    /// (one giant line) — the caller then runs the sequential pipeline.
    /// `minShardBytes` is a parameter (clamped to ≥ 1, never a divide-by-zero
    /// trap) so tests can drive the split path on a small fixture; production
    /// passes the constant above.
    public static func shardRanges(_ bytes: [UInt8], workers: Int, minShardBytes: Int) -> [Range<Int>] {
        let n = bytes.count
        let ideal = min(workers, n / max(1, minShardBytes))
        guard ideal >= 2 else { return [0 ..< n] }
        let newline = UInt8(ascii: "\n")
        var cuts = [0]
        for k in 1 ..< ideal {
            var pos = k * n / ideal
            while pos < n, bytes[pos] != newline {
                pos += 1
            }
            if pos < n { pos += 1 } // the newline closes the earlier shard
            if pos < n, pos > cuts[cuts.count - 1] { cuts.append(pos) }
        }
        cuts.append(n)
        // Cuts are strictly increasing (interior cuts are appended only when
        // greater than the last and less than `n`, then `n` closes them), so
        // every adjacent pair is a non-empty range.
        var ranges: [Range<Int>] = []
        for i in 0 ..< cuts.count - 1 {
            ranges.append(cuts[i] ..< cuts[i + 1])
        }
        return ranges
    }

    /// Harvest+tally `bytes` in `format` (already detected) across `pool`.
    /// Falls back to the single-threaded fused pipeline when the input does
    /// not split into at least two line-aligned shards. Each worker copies
    /// its shard into its own buffer (the filter's proven discipline — a
    /// shared scanned array melted down on cross-thread refcount traffic) and
    /// runs the unmodified `harvestAndTally` on it.
    public static func harvestAndTally(
        _ bytes: [UInt8],
        format: CensusFormat,
        reason: String,
        pool: FilterWorkerPool,
        minShardBytes: Int = minShardBytes,
    ) -> (harvest: CensusHarvest, tally: CensusTally) {
        let ranges = shardRanges(bytes, workers: pool.workerCount, minShardBytes: minShardBytes)
        guard ranges.count >= 2 else {
            return CensusInput.harvestAndTally(bytes, format: format, reason: reason)
        }
        let context = WorkerContext(
            shards: ranges.map { Array(bytes[$0]) }, format: format, reason: reason, count: ranges.count,
        )
        pool.run(jobs: ranges.count) { job in
            context.results[job] = CensusInput.harvestAndTally(
                context.shards[job], format: context.format, reason: context.reason,
            )
        }
        var merged = context.results[0].unsafelyUnwrapped
        for i in 1 ..< ranges.count {
            let shard = context.results[i].unsafelyUnwrapped
            merged = (merged.harvest.merged(with: shard.harvest), merged.tally.merged(with: shard.tally))
        }
        return merged
    }

    /// Per-worker disjoint state: worker `i` reads `shards[i]` and writes
    /// `results[i]` and nothing else, so the unsynchronized array access is
    /// data-race-free by index disjointness — the filter's `WorkerContext`
    /// discipline. The pool's `run` is a join barrier, so every write is
    /// visible before the merge reads.
    private final class WorkerContext: @unchecked Sendable {
        let shards: [[UInt8]]
        let format: CensusFormat
        let reason: String
        var results: [(harvest: CensusHarvest, tally: CensusTally)?]

        init(shards: [[UInt8]], format: CensusFormat, reason: String, count: Int) {
            self.shards = shards
            self.format = format
            self.reason = reason
            results = Array(repeating: nil, count: count)
        }
    }
}
