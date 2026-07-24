// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The `census` verb: drain standard input, detect and parse it, tally
// the population, verify the tally's own books, and print the report or
// the NDJSON stream. Aggregation needs the whole input, so census is the
// one mode that is not line-streaming — output follows end of input.

import SwiftFilt

/// One parsed `swiftfilt census` invocation.
@frozen
public struct CensusInvocation: Sendable, Hashable {
    /// The forced input format, or `nil` to auto-detect from content.
    public var format: CensusFormat?
    /// Rows per ranked table in the human report (`--top`, default 10).
    /// JSON output is never capped.
    public var top: Int
    /// `--json`: emit the NDJSON census objects instead of the report.
    public var json: Bool
    /// `--slim`: the compact NDJSON projection (with `json`).
    public var slim: Bool
    /// `--color` policy (human-report headings only; JSON is never
    /// colored).
    public var color: ColorMode
    /// `--jobs`: `nil` chooses automatically (one worker per CPU for a
    /// large enough `bare`/`nm` input), `1` forces the single-threaded
    /// pipeline, higher values cap the pool. The output is byte-identical
    /// whichever path runs; `--jobs` changes only where the per-row
    /// demangle happens.
    public var jobs: Int?

    public init(
        format: CensusFormat? = nil,
        top: Int = 10,
        json: Bool = false,
        slim: Bool = false,
        color: ColorMode = .auto,
        jobs: Int? = nil,
    ) {
        self.format = format
        self.top = top
        self.json = json
        self.slim = slim
        self.color = color
        self.jobs = jobs
    }
}

/// The census runner.
public enum CensusCommand {
    /// Run a census invocation end to end: drain `input`, parse, tally,
    /// and emit through ``emit(harvest:tally:invocation:writeOutput:writeError:standardOutputIsTTY:)``.
    public static func run(
        _ invocation: CensusInvocation,
        input: () -> [UInt8]?,
        makeWorkerPool: ((Int) -> FilterWorkerPool?)? = nil,
        writeOutput: ([UInt8]) -> Void,
        writeError: (String) -> Void,
        standardOutputIsTTY: Bool,
    ) -> Int32 {
        var bytes: [UInt8] = []
        while let chunk = input() {
            bytes.append(contentsOf: chunk)
        }
        // The fused pipeline: detection decodes only its sample, and every
        // parsed row goes straight to the classifier — no retained line
        // array, no staged row array (at a million rows those two were the
        // bulk of peak memory beyond the input buffer itself).
        let detected = CensusInput.detect(bytes, forced: invocation.format)
        let (harvest, tally) = harvestAndTally(
            bytes, detected: detected, invocation: invocation, makeWorkerPool: makeWorkerPool,
        )
        return emit(
            harvest: harvest, tally: tally, invocation: invocation,
            writeOutput: writeOutput, writeError: writeError,
            standardOutputIsTTY: standardOutputIsTTY,
        )
    }

    /// Harvest+tally the whole input, single-threaded or sharded across a
    /// worker pool. Parallel engages only when `--jobs` did not force `1`, a
    /// pool with at least two workers is available, and the format is one
    /// `ParallelCensus` handles (`bare`/`nm` — `linkmap`'s stateful parse
    /// stays single-threaded). The two paths return byte-identical results:
    /// the sharded tally/harvest merge is additive, so a run's numbers — and
    /// the report ranked from them — do not depend on the thread count.
    public static func harvestAndTally(
        _ bytes: [UInt8],
        detected: (format: CensusFormat, reason: String),
        invocation: CensusInvocation,
        makeWorkerPool: ((Int) -> FilterWorkerPool?)?,
    ) -> (harvest: CensusHarvest, tally: CensusTally) {
        if invocation.jobs != 1, ParallelCensus.supports(detected.format), let makeWorkerPool,
           let pool = makeWorkerPool(invocation.jobs ?? 0), pool.workerCount >= 2
        {
            return ParallelCensus.harvestAndTally(
                bytes, format: detected.format, reason: detected.reason, pool: pool,
            )
        }
        return CensusInput.harvestAndTally(bytes, format: detected.format, reason: detected.reason)
    }

    /// Verify the tally's books against its harvest and emit. A tiling
    /// violation is an internal accounting bug: every violation goes to
    /// stderr and the run exits ``CLI/exitInternalError`` — a census
    /// whose own numbers do not add up is never printed as if they did.
    public static func emit(
        harvest: CensusHarvest,
        tally: CensusTally,
        invocation: CensusInvocation,
        writeOutput: ([UInt8]) -> Void,
        writeError: (String) -> Void,
        standardOutputIsTTY: Bool,
    ) -> Int32 {
        let violations = tally.violations(against: harvest)
        guard violations.isEmpty else {
            for violation in violations {
                writeError("swiftfilt: census internal accounting error: \(violation)\n")
            }
            writeError("swiftfilt: this is a bug in swiftfilt, not in your input; please report it\n")
            return CLI.exitInternalError
        }
        if invocation.json {
            let records = JSONText.censusLines(harvest: harvest, tally: tally, slim: invocation.slim)
            writeOutput(Array((records.joined(separator: "\n") + "\n").utf8))
        } else {
            let palette = Palette(
                enabled: invocation.color.resolved(standardOutputIsTTY: standardOutputIsTTY),
            )
            let report = CensusReport.render(harvest: harvest, tally: tally, top: invocation.top, palette: palette)
            writeOutput(Array(report.utf8))
        }
        return CLI.exitSuccess
    }
}
