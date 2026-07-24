// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The parallel filter's referee: byte-identity against the sequential path in every
// regime (saturated, trickle, coalesced, windowed, classified, colored), ordering,
// the worker-pool contract, and the --jobs surface. The invariant under test:
// parallelism may change WHEN work happens, never a single output byte or its order.

import Foundation
import SwiftFilt
import SwiftFiltCLICore
import Testing

/// A real concurrent pool for tests: one thread per job with a wide
/// stack (the demangle recursion policy applies to every thread that
/// demangles), joined through a DispatchGroup.
final class TestWorkerPool: FilterWorkerPool, @unchecked Sendable {
    let workerCount: Int

    init(workerCount: Int) {
        self.workerCount = workerCount
    }

    func run(jobs: Int, _ body: @escaping @Sendable (Int) -> Void) {
        let group = DispatchGroup()
        for job in 0 ..< jobs {
            group.enter()
            let thread = Thread {
                body(job)
                group.leave()
            }
            thread.stackSize = 16 << 20
            thread.start()
        }
        group.wait()
    }
}

/// A pool that runs jobs inline, in order — the deterministic harness
/// for split/gather logic (the pool contract promises completion and
/// exactly-once, not real threads).
final class InlineWorkerPool: FilterWorkerPool {
    let workerCount: Int
    private(set) var rounds: [Int] = []

    init(workerCount: Int) {
        self.workerCount = workerCount
    }

    func run(jobs: Int, _ body: @escaping @Sendable (Int) -> Void) {
        rounds.append(jobs)
        for job in 0 ..< jobs {
            body(job)
        }
    }
}

/// A deterministic synthetic log: crash-frame, prose, nm, and noise
/// lines cycling over the bundled corpus symbols (SplitMix64 selection),
/// the same density recipe as the benchmark's filter workload.
func syntheticLog(byteCount: Int, seed: UInt64 = 0x5EED) -> [UInt8] {
    let corpus = URL(fileURLWithPath: cliFixturesRoot)
        .deletingLastPathComponent()
        .appendingPathComponent("SwiftDemangling/corpus.tsv").path
    var symbols: [String] = []
    for line in fixtureString(corpus).split(separator: "\n").prefix(2000) {
        guard let tab = line.firstIndex(of: "\t") else { continue }
        symbols.append(String(line[..<tab]))
    }
    precondition(!symbols.isEmpty, "corpus fixture missing")
    var state = seed
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    var out: [UInt8] = []
    out.reserveCapacity(byteCount + 256)
    var frame = 0
    while out.count < byteCount {
        let a = symbols[Int(next() % UInt64(symbols.count))]
        let b = symbols[Int(next() % UInt64(symbols.count))]
        out.append(contentsOf: "\(frame)  App  0x\(String(next(), radix: 16)) \(a) + \(next() % 512)\n".utf8)
        out.append(contentsOf: "prose line \(next() % 1000) with no symbols in it at all\n".utf8)
        out.append(contentsOf: "\(String(next(), radix: 16)) T \(b)\n".utf8)
        out.append(contentsOf: "0x\(String(next(), radix: 16)) \(next() % 100_000)\n".utf8)
        frame += 1
    }
    return out
}

/// Run the CLI in filter mode with an injected pool and availability
/// probe, capturing output and flush counts.
func runParallelCLI(
    _ arguments: [String],
    stdin: [UInt8],
    chunkSize: Int,
    available: @escaping (Int) -> Bool,
    pool: FilterWorkerPool?,
) -> CLIRun {
    var chunks: [[UInt8]] = []
    var start = 0
    while start < stdin.count {
        let end = min(start + chunkSize, stdin.count)
        chunks.append(Array(stdin[start ..< end]))
        start = end
    }
    var next = 0
    var out: [UInt8] = []
    var calls = 0
    var err = ""
    let status = CLI.run(
        arguments: arguments,
        input: {
            guard next < chunks.count else { return nil }
            defer { next += 1 }
            return chunks[next]
        },
        inputAvailable: { available(next) },
        makeWorkerPool: { _ in pool },
        writeOutput: { bytes in
            out.append(contentsOf: bytes)
            calls += 1
        },
        writeError: { err += $0 },
        standardOutputIsTTY: false,
    )
    return CLIRun(status: status, stdoutBytes: out, stderr: err, outputCalls: calls)
}

@Suite("Parallel filter")
struct ParallelFilterTests {
    /// The one referee that matters most: a saturating multi-megabyte
    /// log through real concurrent workers is byte-identical to the
    /// sequential run — plain, styled, colored, and classified.
    @Test(arguments: [
        [] as [String],
        ["--simplified"],
        ["--classify"],
        ["--color", "always"],
    ])
    func saturatedOutputMatchesSequentialByteForByte(_ arguments: [String]) {
        let log = syntheticLog(byteCount: 900 << 10)
        let sequential = runCLI(arguments, stdin: log, chunkSize: 1 << 16)
        let parallel = runParallelCLI(
            arguments, stdin: log, chunkSize: 1 << 16,
            available: { _ in true }, pool: TestWorkerPool(workerCount: 4),
        )
        #expect(parallel.stdoutBytes == sequential.stdoutBytes)
        #expect(parallel.status == CLI.exitSuccess)
    }

    /// Ordering referee: thousands of numbered lines whose demanglings
    /// interleave across spans must come back in exact input order.
    @Test func orderingPreservedAcrossManySpans() {
        var input: [UInt8] = []
        for n in 0 ..< 30000 {
            input.append(contentsOf: "line\(n) $s4main3fooyyF tail\(n)\n".utf8)
        }
        let run = runParallelCLI(
            [], stdin: input, chunkSize: 1 << 15,
            available: { _ in true }, pool: TestWorkerPool(workerCount: 6),
        )
        var expected: [UInt8] = []
        for n in 0 ..< 30000 {
            expected.append(contentsOf: "line\(n) main.foo() -> () tail\(n)\n".utf8)
        }
        #expect(run.stdoutBytes == expected)
    }

    /// Trickle regime: when the availability probe answers false, every
    /// chunk flushes what it completes before the next chunk is read —
    /// the exact sequential liveness contract, pool present or not.
    @Test func tricklePreservesPerChunkFlushes() {
        let text = "one $s4main3fooyyF\ntwo\nthree $s4main3fooyyF!\n"
        let sequential = runCLI([], stdinText: text, chunkSize: 15)
        let trickle = runParallelCLI(
            [], stdin: Array(text.utf8), chunkSize: 15,
            available: { _ in false }, pool: TestWorkerPool(workerCount: 4),
        )
        #expect(trickle.stdoutBytes == sequential.stdoutBytes)
        #expect(trickle.outputCalls == sequential.outputCalls,
                "an unavailable-input trickle must keep the sequential flush cadence")
    }

    /// Saturation regime: available input coalesces into region-sized
    /// rounds — fewer, larger flushes than the chunk count, same bytes.
    @Test func saturatedInputCoalescesReads() {
        let log = syntheticLog(byteCount: 2 << 20, seed: 7)
        let chunkSize = 1 << 16
        let chunkCount = (log.count + chunkSize - 1) / chunkSize
        let run = runParallelCLI(
            [], stdin: log, chunkSize: chunkSize,
            available: { _ in true }, pool: TestWorkerPool(workerCount: 4),
        )
        #expect(run.stdoutBytes == runCLI([], stdin: log).stdoutBytes)
        #expect(run.outputCalls < chunkCount / 4,
                "saturated chunks must coalesce into rounds, not flush per read")
    }

    /// EOF arriving mid-coalesce ends the round cleanly: everything is
    /// still emitted, including the unterminated tail.
    @Test func endOfInputMidCoalesceDrainsEverything() {
        let text = "alpha $s4main3fooyyF\nunterminated tail $s4main3fooyyF"
        let run = runParallelCLI(
            [], stdin: Array(text.utf8), chunkSize: 8,
            available: { _ in true }, pool: TestWorkerPool(workerCount: 2),
        )
        #expect(run.stdout == "alpha main.foo() -> ()\nunterminated tail main.foo() -> ()")
    }

    /// Regime switching mid-stream (saturated bursts between trickles)
    /// never perturbs bytes.
    @Test func alternatingRegimesStayByteIdentical() {
        let log = syntheticLog(byteCount: 600 << 10, seed: 11)
        let run = runParallelCLI(
            [], stdin: log, chunkSize: 1 << 14,
            available: { chunkIndex in (chunkIndex / 5) % 2 == 0 },
            pool: TestWorkerPool(workerCount: 3),
        )
        #expect(run.stdoutBytes == runCLI([], stdin: log).stdoutBytes)
    }

    /// An over-window line (the 4 MiB windowing machinery) with parallel
    /// enabled: newline-free windows take the sequential path inside the
    /// same stream and the output still equals the library ground truth.
    @Test func overWindowLineWithParallelMatchesGroundTruth() {
        let capacity = FilterStream.windowCapacity
        var line = "head $s4main6ServerC5start4portySi_tF "
        line += String(repeating: "junk words ", count: (capacity + (1 << 20)) / 11)
        line += " tail $s4main3fooyyF\n"
        line += "after $s4main3fooyyF\n"
        let input = Array(line.utf8)
        let expected = MangledNameScanner().demangleAll(inBytes: input)
        let run = runParallelCLI(
            [], stdin: input, chunkSize: 1 << 18,
            available: { _ in true }, pool: TestWorkerPool(workerCount: 4),
        )
        #expect(run.stdoutBytes == expected)
    }

    /// The oversized-run discard choreography (raw passthrough until the
    /// run breaks) is untouched by a live parallel rewriter.
    @Test func oversizedRunDiscardSurvivesParallelStream() {
        let capacity = FilterStream.windowCapacity
        let head = String(repeating: "A", count: capacity + 1)
        let input = Array((head + "AA\n$s4main3fooyyF\n").utf8)
        let run = runParallelCLI(
            [], stdin: input, chunkSize: 1 << 18,
            available: { _ in true }, pool: TestWorkerPool(workerCount: 4),
        )
        #expect(run.stdout == head + "AA\nmain.foo() -> ()\n")
    }

    // MARK: Split mechanics (deterministic inline pool)

    private func rewriteThroughStream(_ input: [UInt8], rewriter: ParallelRewriter?) -> [UInt8] {
        var stream = FilterStream(
            mode: .rewrite(classify: false), style: .full,
            palette: Palette(enabled: false), parallel: rewriter,
        )
        var out: [UInt8] = []
        stream.consume(input) { out.append(contentsOf: $0) }
        stream.finish { out.append(contentsOf: $0) }
        return out
    }

    /// Split boundaries land after newlines and cover the region exactly;
    /// jobs never exceed the worker count; output equals sequential.
    @Test func spanSplitCoversRegionExactly() {
        let pool = InlineWorkerPool(workerCount: 3)
        let rewriter = ParallelRewriter(pool: pool, minSpanBytes: 64)
        var input: [UInt8] = []
        for n in 0 ..< 200 {
            input.append(contentsOf: "row\(n) $s4main3fooyyF suffix that pads the line width\n".utf8)
        }
        let out = rewriteThroughStream(input, rewriter: rewriter)
        #expect(out == rewriteThroughStream(input, rewriter: nil))
        #expect(pool.rounds == [3], "one round, all workers")
    }

    /// A region under twice the span floor is not worth a round: the
    /// sequential path runs and the pool is never woken.
    @Test func smallRegionsStaySequential() {
        let pool = InlineWorkerPool(workerCount: 8)
        let rewriter = ParallelRewriter(pool: pool, minSpanBytes: 1 << 20)
        let input = Array("small $s4main3fooyyF\nregion\n".utf8)
        let out = rewriteThroughStream(input, rewriter: rewriter)
        #expect(out == rewriteThroughStream(input, rewriter: nil))
        #expect(pool.rounds.isEmpty)
    }

    /// A big region whose only newline sits at its very end cannot split
    /// (no interior cut point): sequential path, pool untouched.
    @Test func regionWithoutInteriorNewlineStaysSequential() {
        let pool = InlineWorkerPool(workerCount: 4)
        let rewriter = ParallelRewriter(pool: pool, minSpanBytes: 128)
        var input = Array(String(repeating: "x", count: 4096).utf8)
        input.append(contentsOf: " $s4main3fooyyF\n".utf8)
        let out = rewriteThroughStream(input, rewriter: rewriter)
        #expect(out == rewriteThroughStream(input, rewriter: nil))
        #expect(pool.rounds.isEmpty)
    }

    /// Fewer usable cut points than workers: the round runs with the
    /// spans it has (two lines, many workers — two jobs).
    @Test func fewerLinesThanWorkersShrinkTheRound() {
        let pool = InlineWorkerPool(workerCount: 6)
        let rewriter = ParallelRewriter(pool: pool, minSpanBytes: 32)
        let half = String(repeating: "y", count: 300) + " $s4main3fooyyF\n"
        let input = Array((half + half).utf8)
        let out = rewriteThroughStream(input, rewriter: rewriter)
        #expect(out == rewriteThroughStream(input, rewriter: nil))
        #expect(pool.rounds.count == 1)
        #expect(pool.rounds[0] <= 6)
    }

    /// Matches whose rendering is EMPTY in the selected style (`$ss` in
    /// .simplified — validated by .full, empty thereafter) keep their
    /// original bytes inside parallel spans, plain and classified alike —
    /// the same keep-the-bytes contract the sequential path pins.
    @Test func emptyInStyleMatchesKeepTheirBytesAcrossSpans() {
        var input: [UInt8] = []
        for n in 0 ..< 200 {
            input.append(contentsOf: "row\(n) $ss and $s4main3fooyyF padding padding padding\n".utf8)
        }
        for arguments in [["--simplified"], ["--simplified", "--classify"]] {
            let pool = InlineWorkerPool(workerCount: 3)
            let rewriter = ParallelRewriter(pool: pool, minSpanBytes: 64)
            let mode: FilterStream.Mode = .rewrite(classify: arguments.contains("--classify"))
            var parallelStream = FilterStream(
                mode: mode, style: .simplified, palette: Palette(enabled: false), parallel: rewriter,
            )
            var out: [UInt8] = []
            parallelStream.consume(input) { out.append(contentsOf: $0) }
            parallelStream.finish { out.append(contentsOf: $0) }
            #expect(out == runCLI(arguments, stdin: input).stdoutBytes, "\(arguments)")
            #expect(String(decoding: out, as: UTF8.self).contains("row7 $ss and foo"),
                    "the $ss match must keep its bytes while foo rewrites")
            #expect(pool.rounds == [3])
        }
    }

    /// Classified spans run the structured scan per span and splice the
    /// marker-prefixed replacements identically to the sequential path.
    @Test func classifiedParallelSpansMatchSequential() {
        let pool = InlineWorkerPool(workerCount: 3)
        let rewriter = ParallelRewriter(pool: pool, minSpanBytes: 64)
        var input: [UInt8] = []
        for n in 0 ..< 120 {
            input.append(contentsOf: "f\(n) _T013call_protocol1CCAA1PA2aDP3fooSiyFTW pad pad pad\n".utf8)
        }
        var parallelStream = FilterStream(
            mode: .rewrite(classify: true), style: .full,
            palette: Palette(enabled: false), parallel: rewriter,
        )
        var parallelOut: [UInt8] = []
        parallelStream.consume(input) { parallelOut.append(contentsOf: $0) }
        parallelStream.finish { parallelOut.append(contentsOf: $0) }
        var sequentialStream = FilterStream(
            mode: .rewrite(classify: true), style: .full,
            palette: Palette(enabled: false),
        )
        var sequentialOut: [UInt8] = []
        sequentialStream.consume(input) { sequentialOut.append(contentsOf: $0) }
        sequentialStream.finish { sequentialOut.append(contentsOf: $0) }
        #expect(parallelOut == sequentialOut)
        #expect(pool.rounds == [3])
        #expect(String(decoding: parallelOut, as: UTF8.self).contains("{T:"), "classify markers must survive the parallel splice")
    }

    /// The default (product) span floor engages on region scale: a
    /// megabyte region splits, a small one does not.
    @Test func defaultRewriterEngagesOnRegionScale() {
        let pool = InlineWorkerPool(workerCount: 4)
        let rewriter = ParallelRewriter(pool: pool)
        let big = syntheticLog(byteCount: 1 << 20, seed: 3)
        let bigOut = rewriteThroughStream(big, rewriter: rewriter)
        #expect(bigOut == rewriteThroughStream(big, rewriter: nil))
        #expect(pool.rounds.count >= 1)
        #expect(rewriter.roundTargetBytes >= 1 << 20)
    }

    // MARK: Wiring

    /// Modes that keep line-number provenance (tree/JSON) never engage
    /// the pool even when one is offered.
    @Test func treeAndJSONModesNeverEngageThePool() {
        let log = syntheticLog(byteCount: 128 << 10, seed: 5)
        for arguments in [["--json"], ["--tree"]] {
            let sequential = runCLI(arguments, stdin: log, chunkSize: 1 << 16)
            let offered = runParallelCLI(
                arguments, stdin: log, chunkSize: 1 << 16,
                available: { _ in true }, pool: TestWorkerPool(workerCount: 4),
            )
            #expect(offered.stdoutBytes == sequential.stdoutBytes, "\(arguments) must stay sequential")
        }
    }

    /// `--jobs 1` forces the sequential path; a one-worker pool cannot
    /// parallelize either; a `nil` pool factory result stays sequential.
    @Test func jobsOneAndDegeneratePoolsStaySequential() {
        let log = syntheticLog(byteCount: 96 << 10, seed: 9)
        let expected = runCLI([], stdin: log).stdoutBytes
        let jobsOne = runParallelCLI(
            ["--jobs", "1"], stdin: log, chunkSize: 1 << 16,
            available: { _ in true }, pool: TestWorkerPool(workerCount: 8),
        )
        #expect(jobsOne.stdoutBytes == expected)
        let oneWorker = runParallelCLI(
            [], stdin: log, chunkSize: 1 << 16,
            available: { _ in true }, pool: TestWorkerPool(workerCount: 1),
        )
        #expect(oneWorker.stdoutBytes == expected)
        let noPool = runParallelCLI(
            [], stdin: log, chunkSize: 1 << 16,
            available: { _ in true }, pool: nil,
        )
        #expect(noPool.stdoutBytes == expected)
    }

    /// The `--jobs` request reaches the pool factory: explicit values
    /// pass through, no flag requests automatic (0).
    @Test func jobsRequestReachesThePoolFactory() {
        nonisolated(unsafe) var requests: [Int] = []
        let record: (Int) -> FilterWorkerPool? = { requested in
            requests.append(requested)
            return nil
        }
        _ = CLI.run(
            arguments: ["--jobs", "3"], input: { nil }, inputAvailable: { false },
            makeWorkerPool: record, writeOutput: { _ in }, writeError: { _ in },
            standardOutputIsTTY: false,
        )
        _ = CLI.run(
            arguments: [], input: { nil }, inputAvailable: { false },
            makeWorkerPool: record, writeOutput: { _ in }, writeError: { _ in },
            standardOutputIsTTY: false,
        )
        #expect(requests == [3, 0])
    }

    /// The pool contract as the rewriter exercises it: every job index
    /// exactly once, jobs never above workerCount, work visible after
    /// the join.
    @Test func poolRunsEveryJobExactlyOnce() {
        let pool = TestWorkerPool(workerCount: 5)
        final class Counters: @unchecked Sendable {
            let lock = NSLock()
            var seen: [Int] = []
        }
        let counters = Counters()
        pool.run(jobs: 5) { job in
            counters.lock.lock()
            counters.seen.append(job)
            counters.lock.unlock()
        }
        #expect(counters.seen.sorted() == [0, 1, 2, 3, 4])
    }
}
