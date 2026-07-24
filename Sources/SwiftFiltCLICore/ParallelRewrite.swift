// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Parallel filter rewriting: a saturated-input region of complete lines is
// split at newline boundaries into per-worker spans, each span rewritten on
// its own engine, and the results written strictly in span order — so the
// output bytes are identical to the sequential path's while the demangling
// work spreads across cores. Line independence is what makes this sound:
// a mangled-name candidate can never contain or cross a `\n` (newline is
// not a mangling character and every candidate gate rejects it), so a
// newline-aligned split can never split a candidate, and the concatenation
// of per-span rewrites equals the whole-region rewrite byte for byte —
// pinned by test against the sequential scan and by the CLI goldens.

import SwiftFilt

/// A pool of worker threads the filter's parallel rewrite runs on.
///
/// The CLI executable provides the real implementation (platform threads
/// with the same wide-stack policy as the main demangler thread — the
/// demangle/print recursion needs deep stacks on EVERY thread that runs
/// it); tests provide their own. `SwiftFiltCLICore` stays platform-free.
public protocol FilterWorkerPool: AnyObject {
    /// How many jobs can make progress simultaneously. A pool answering
    /// less than 2 disables parallel rewriting.
    var workerCount: Int { get }

    /// Run `body(0) … body(jobs-1)` concurrently and return when every
    /// call has completed. `jobs` is at most ``workerCount``. Each job
    /// index is invoked exactly once; the completed work must be visible
    /// to the caller on return (a join barrier — `body` never outlives
    /// the call despite the `@escaping` the worker handoff requires).
    func run(jobs: Int, _ body: @escaping @Sendable (Int) -> Void)
}

/// One worker's buffers: the span-input copy and the rewritten output,
/// both reused round after round (capacity kept) so steady-state rounds
/// allocate no large buffers at all — per-round megabyte alloc/free churn
/// was the parallel filter's peak-RSS driver. A final class so each worker
/// mutates only its own box while the boxes array itself is shared
/// read-only.
final class SpanBox {
    /// The worker's private copy of its span. Workers never scan the
    /// shared region directly: every candidate bind and splice slice
    /// reference-counts the scanned array, and one array shared by every
    /// worker melted down on its atomic refcount (measured: retain/release
    /// became 55% of all samples at 10 workers, wall time 2× sequential).
    var input: [UInt8] = []
    /// The span's rewritten bytes, gathered in span order by the caller.
    var output: [UInt8] = []
}

/// The pieces a worker touches, smuggled across the `@Sendable` boundary.
///
/// Soundness: `engines[i]` and `boxes[i]` are touched only by job `i`
/// (disjoint access by construction — the arrays themselves are only read),
/// `region` and `spans` are immutable for the round, and the pool's join
/// barrier orders every worker write before the caller's gather reads.
private struct WorkerContext: @unchecked Sendable {
    let engines: [ArenaDemangleEngine]
    let boxes: [SpanBox]
    let region: [UInt8]
    let spans: [Range<Int>]
    let style: DemangleStyle
    let palette: Palette
    let classify: Bool
}

/// The parallel rewrite engine a ``FilterStream`` in rewrite mode consults:
/// splits a complete-lines region into newline-aligned spans, rewrites them
/// concurrently (one reusable ``ArenaDemangleEngine`` per worker slot), and
/// gathers the results in span order. Regions too small to split (or with
/// no interior newline — a windowed slice of one oversized line) return
/// `false` and take the sequential path unchanged.
///
/// Not `Sendable` — it is one filter stream's mutable state (the engines
/// and result boxes persist across rounds so steady-state rounds allocate
/// only their outputs). The pool it drives is the only concurrent piece.
public final class ParallelRewriter {
    let pool: FilterWorkerPool
    /// The minimum bytes a span must carry for the cross-thread handoff to
    /// be profitable (measured: a span this size costs ≈0.5 ms of rewrite
    /// against ≈10–40 µs of pool dispatch).
    let minSpanBytes: Int
    /// How many buffered bytes the CLI read loop coalesces toward before
    /// handing the filter one region — sized so every worker gets spans
    /// well past ``minSpanBytes`` (memory stays bounded by this plus the
    /// rewritten output, ≈2.5× this figure).
    public let roundTargetBytes: Int

    private var engines: [ArenaDemangleEngine] = []
    private var boxes: [SpanBox] = []
    private let scanner = MangledNameScanner()

    /// - Parameters:
    ///   - pool: The worker pool rounds run on.
    ///   - minSpanBytes: The span floor (see ``minSpanBytes``); the
    ///     default is the measured product setting, and tests lower it to
    ///     exercise splitting without megabyte fixtures.
    public init(pool: FilterWorkerPool, minSpanBytes: Int = 64 << 10) {
        self.pool = pool
        self.minSpanBytes = minSpanBytes
        roundTargetBytes = max(1 << 20, pool.workerCount * (256 << 10))
    }

    /// Rewrite the complete-lines region `bytes[range]` into `pending`
    /// across the pool, or return `false` when the region is not worth
    /// splitting — the caller then runs its sequential rewrite. Output
    /// bytes are identical either way.
    func rewrite(_ bytes: [UInt8], in range: Range<Int>, classify: Bool, style: DemangleStyle, palette: Palette, into pending: inout [UInt8]) -> Bool {
        guard let spans = spanBoundaries(bytes, in: range) else { return false }
        ensureSlots(spans.count)
        let context = WorkerContext(
            engines: engines, boxes: boxes, region: bytes, spans: spans,
            style: style, palette: palette, classify: classify,
        )
        pool.run(jobs: spans.count) { job in
            ParallelRewriter.rewriteSpan(context, job: job)
        }
        for box in boxes[0 ..< spans.count] {
            pending.append(contentsOf: box.output)
            // Rewind (keeping capacity) so the next round's buffers are
            // already sized; the boxes ARE the steady-state footprint,
            // bounded by the round size.
            box.output.removeAll(keepingCapacity: true)
        }
        return true
    }

    /// Newline-aligned span boundaries covering `region[range]` exactly,
    /// one span per worker the region can feed at ``minSpanBytes`` or
    /// better — `nil` when fewer than two spans result (small region, or
    /// no interior newline to cut at).
    private func spanBoundaries(_ region: [UInt8], in range: Range<Int>) -> [Range<Int>]? {
        let workers = pool.workerCount
        let ideal = min(workers, range.count / minSpanBytes)
        guard ideal >= 2 else { return nil }
        let newline = UInt8(ascii: "\n")
        var cuts = [range.lowerBound]
        for k in 1 ..< ideal {
            let target = max(range.lowerBound + range.count * k / ideal, cuts[cuts.count - 1])
            // The cut goes AFTER the first newline at or past the ideal
            // point; if none remains, the last span absorbs the rest.
            var i = target
            while i < range.upperBound, region[i] != newline {
                i += 1
            }
            guard i < range.upperBound else { break }
            let cut = i + 1
            if cut > cuts[cuts.count - 1], cut < range.upperBound {
                cuts.append(cut)
            }
        }
        guard cuts.count >= 2 else { return nil }
        cuts.append(range.upperBound)
        var spans: [Range<Int>] = []
        spans.reserveCapacity(cuts.count - 1)
        for k in 0 ..< cuts.count - 1 {
            spans.append(cuts[k] ..< cuts[k + 1])
        }
        return spans
    }

    /// Grow the per-worker engine and result slots to `count`. Engines are
    /// built once and reused round after round (their arena slabs and
    /// printer buffers stay warm — the same amortization the sequential
    /// stream's single engine gets).
    private func ensureSlots(_ count: Int) {
        while engines.count < count {
            engines.append(ArenaDemangleEngine())
            boxes.append(SpanBox())
        }
    }

    /// Rewrite one span — the exact per-splice contract of the sequential
    /// paths (`FilterStream.rewrittenPlain` / `rewrittenClassified`),
    /// producing this span's output bytes into its box.
    ///
    /// The worker copies its span into ITS OWN reused input buffer and
    /// never touches the shared region again: every slice, scan-buffer bind,
    /// and identifier range then reference-counts a worker-local array (see
    /// ``SpanBox`` — sharing the region melted down on cross-worker refcount
    /// traffic). The copy is ~0.1 ms per round; bytes out are identical.
    private static func rewriteSpan(_ context: WorkerContext, job: Int) {
        let box = context.boxes[job]
        box.input.removeAll(keepingCapacity: true)
        box.input.append(contentsOf: context.region[context.spans[job]])
        let bytes = box.input
        if context.classify {
            classifiedSpan(context, bytes: bytes, into: &box.output)
            return
        }
        var cursor = 0
        MangledNameScanner().scanRendered(
            inBytes: bytes, style: context.style, engine: context.engines[job],
        ) { range, replacement in
            guard !replacement.isEmpty else { return }
            box.output.append(contentsOf: bytes[cursor ..< range.lowerBound])
            box.output.append(contentsOf: context.palette.demangled(replacement).utf8)
            cursor = range.upperBound
        }
        box.output.append(contentsOf: bytes[cursor...])
    }

    /// The classify variant: the structured scan over the span copy (the
    /// `SwiftSymbol` trees feed the marker computation), spliced exactly as
    /// `FilterStream.rewrittenClassified` splices.
    private static func classifiedSpan(_ context: WorkerContext, bytes: [UInt8], into out: inout [UInt8]) {
        var cursor = 0
        for match in MangledNameScanner().matches(inBytes: bytes) {
            let replacement = SymbolText.classifiedReplacement(match, demangled: match.demangled(context.style))
            guard !replacement.isEmpty else { continue }
            out.append(contentsOf: bytes[cursor ..< match.byteRange.lowerBound])
            out.append(contentsOf: context.palette.demangled(replacement).utf8)
            cursor = match.byteRange.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
    }
}
