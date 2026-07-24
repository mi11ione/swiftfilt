// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swiftfilt-parity differential` — the C2 backend-equivalence gate.
//
// Stage C2 routes the string→string demangling path onto the bump-arena
// `ArenaBuilder` backend. That path MUST render byte-for-byte identically to
// the `SwiftSymbol` value backend for every symbol, in every style — the two
// backends run the same generic demangler + node-printer bodies over two node
// representations, so any divergence is an arena bug, never an expected
// deviation. This subcommand proves it over the full corpus:
//
//   arena       = SwiftFilt.demangle(mangled, style:)         (the product path)
//   session     = one DemangleSession per batch, reset-reused per symbol
//   swiftSymbol = SwiftDemanglerPrinter().print(
//                     SwiftDemangler().demangle(symbol: adapted), style:)
//   scanner     = MangledNameScanner.demangleAll(inBytes:) over the symbol
//                 embedded mid-buffer, vs a splice computed from the
//                 structured scan (matches(inBytes:) + its validated render)
//
// per style (full / simplified / qualified / unqualified): arena vs
// swiftSymbol, and session vs arena, each pair `nil`-agreeing or byte-equal;
// plus one scanner-window comparison per symbol. The session leg is the
// engine-reuse referee: one engine demangles the whole batch back-to-back,
// so any state leaking across a reset (nodes, words, substitutions, printer
// state) diverges from the fresh-engine render and fails here. The scanner
// leg is the windowed-parse referee: the production filter parses each
// candidate as a *window* of the scan buffer through one reused engine,
// while the structured scan parses a fresh copy through the value backend —
// independent representations, byte-equal splices required. No external
// oracle, no KNOWN-DEVIATIONS: the contract is exactly zero mismatches.
// Streamed with bounded memory and concurrent large-stack batches (deep
// symbols nest past the cooperative pool's stack).

import Foundation
import SwiftFilt

public func runDifferentialCommand(_ args: [String]) async -> Int32 {
    var limit = Int.max
    var skip = 0
    var batchSize = 8192
    var jobs = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    var showRows = 25
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--limit":
            index += 1
            limit = parseCount("--limit", in: args, at: index, for: "differential", minimum: 1)
        case "--skip":
            index += 1
            skip = parseCount("--skip", in: args, at: index, for: "differential")
        case "--batch":
            index += 1
            batchSize = parseCount("--batch", in: args, at: index, for: "differential", minimum: 1)
        case "--jobs":
            index += 1
            jobs = parseCount("--jobs", in: args, at: index, for: "differential", minimum: 1)
        case "--inline-rows":
            index += 1
            showRows = parseCount("--inline-rows", in: args, at: index, for: "differential")
        default:
            eprint("differential: unknown option \(args[index])")
            return 2
        }
        index += 1
    }

    guard let source = SymbolSource.resolve(for: "differential") else { return 2 }
    print("[differential] source: \(source.descriptionLine)")
    print("[differential] arena vs SwiftSymbol + session vs one-shot (4 styles) + scanner-window vs structured splice (9 comparisons/symbol); contract: 0 mismatches")
    print("[differential] batch=\(grouped(batchSize)) jobs=\(jobs)\(skip == 0 ? "" : " skip=\(grouped(skip))")\(limit == .max ? "" : " limit=\(grouped(limit))")")

    let started = Date()
    let sequence: BatchSequence
    let totalHint: Int?
    switch source {
    case let .fixtures(symbols):
        let capped = Array(symbols.dropFirst(skip).prefix(limit))
        sequence = BatchSequence(symbols: capped, batchSize: batchSize)
        totalHint = capped.count
    case let .manifest(path):
        guard let reader = ManifestBatchReader(path: path, batchSize: batchSize, limit: limit, skip: skip) else {
            eprint("differential: could not open \(path)")
            return 2
        }
        sequence = BatchSequence(reader: reader)
        totalHint = nil
    }

    let result = await sweepDifferential(batches: sequence, totalHint: totalHint, jobs: jobs)
    let elapsed = Date().timeIntervalSince(started)

    print("")
    print("[differential] symbols: \(grouped(result.symbols)) · comparisons: \(grouped(result.comparisons)) (4 styles × {arena↔swiftSymbol, session↔arena} + scanner-window) · time \(secondsText(elapsed))")
    if !result.harnessErrors.isEmpty {
        for error in result.harnessErrors.prefix(showRows) {
            eprint("[differential] harness error: \(error)")
        }
        print("[differential] RESULT: HARNESS ERROR (\(grouped(result.harnessErrors.count)))")
        return 2
    }
    if result.mismatches == 0 {
        print("[differential] RESULT: PASS — arena == SwiftSymbol on every symbol × style (\(grouped(result.comparisons)) comparisons, 0 mismatches)")
        return 0
    }
    print("[differential] RESULT: FAIL — \(grouped(result.mismatches)) mismatch(es):")
    for row in result.mismatchRows.prefix(showRows) {
        print("  \(row)")
    }
    if result.mismatchRows.count > showRows { print("  …and \(grouped(result.mismatchRows.count - showRows)) more captured (of \(grouped(result.mismatches)) total)") }
    return 1
}

/// A differential sweep's tally: how many symbols and style-comparisons ran,
/// how many diverged, and a bounded sample of the divergences.
struct DifferentialResult: Sendable {
    var symbols = 0
    var comparisons = 0
    var mismatches = 0
    var mismatchRows: [String] = []
    var harnessErrors: [String] = []
}

private struct DifferentialBatchOutcome: Sendable {
    let index: Int
    var symbols = 0
    var comparisons = 0
    var mismatches = 0
    var mismatchRows: [String] = []
    var harnessError: String?
    init(index: Int) {
        self.index = index
    }
}

/// The four styles the string path renders, paired product-tier ↔ node-tier.
private let differentialStyles: [(DemangleStyle, SwiftDemanglerPrinter.Style)] = [
    (.full, .full), (.simplified, .simplified), (.qualified, .qualified), (.unqualified, .unqualified),
]

/// Drive all batches through a bounded TaskGroup, folding outcomes in batch
/// order, with periodic progress. Returns the aggregate tally.
private func sweepDifferential(batches: BatchSequence, totalHint: Int?, jobs: Int) async -> DifferentialResult {
    var result = DifferentialResult()
    var nextToAbsorb = 0
    var pending: [Int: DifferentialBatchOutcome] = [:]
    var lastProgress = Date()
    let progressEvery = 15.0
    // Cap retained divergence samples so a pathological run cannot blow memory.
    let rowCap = 200

    await withTaskGroup(of: DifferentialBatchOutcome.self) { group in
        var inFlight = 0
        var dispatched = 0
        func fill() {
            while inFlight < jobs, let batch = batches.next() {
                let batchIndex = dispatched
                dispatched += 1
                group.addTask { await diffBackendsBatch(batch, index: batchIndex) }
                inFlight += 1
            }
        }
        func absorbReady() {
            while let outcome = pending.removeValue(forKey: nextToAbsorb) {
                nextToAbsorb += 1
                result.symbols += outcome.symbols
                result.comparisons += outcome.comparisons
                result.mismatches += outcome.mismatches
                if result.mismatchRows.count < rowCap {
                    result.mismatchRows.append(contentsOf: outcome.mismatchRows.prefix(rowCap - result.mismatchRows.count))
                }
                if let error = outcome.harnessError { result.harnessErrors.append(error) }
            }
            if Date().timeIntervalSince(lastProgress) > progressEvery {
                lastProgress = Date()
                let total = totalHint.map { "/\(grouped($0))" } ?? ""
                print("[differential] processed \(grouped(result.symbols))\(total) symbols, mismatches so far: \(grouped(result.mismatches))")
            }
        }
        fill()
        while inFlight > 0, let outcome = await group.next() {
            inFlight -= 1
            pending[outcome.index] = outcome
            absorbReady()
            fill()
        }
        absorbReady()
    }
    return result
}

/// Compare one batch on a large-stack worker: for each symbol, the arena
/// product render vs the `SwiftSymbol` reference render, and the reused
/// `DemangleSession` render vs the one-shot arena render, in all four styles.
/// The session lives for the whole batch — thousands of diverse symbols
/// through one reset-reused engine, back-to-back, so cross-symbol state
/// contamination cannot hide.
private func diffBackendsBatch(_ symbols: [String], index: Int) async -> DifferentialBatchOutcome {
    await onLargeStack {
        var outcome = DifferentialBatchOutcome(index: index)
        let printer = SwiftDemanglerPrinter()
        let engine = SwiftDemangler()
        let session = DemangleSession()
        let scanner = MangledNameScanner()
        let windowPrefix = Array("< ".utf8)
        let windowSuffix = Array(" >".utf8)
        for mangled in symbols {
            outcome.symbols += 1
            // The `SwiftSymbol` reference is built once per symbol (the `__T`
            // Mach-O adapter matches the product string path) and printed per
            // style; the arena path is the product `demangle(_:style:)` itself.
            let adapted = mangled.hasPrefix("__T") ? String(mangled.dropFirst()) : mangled
            let referenceTree = engine.demangle(symbol: adapted)
            for (arenaStyle, referenceStyle) in differentialStyles {
                outcome.comparisons += 2
                let arena = SwiftFilt.demangle(mangled, style: arenaStyle)
                let reference: String?
                if let referenceTree {
                    let rendered = printer.print(referenceTree, style: referenceStyle)
                    reference = rendered.isEmpty ? nil : rendered
                } else {
                    reference = nil
                }
                if arena != reference {
                    outcome.mismatches += 1
                    if outcome.mismatchRows.count < 50 {
                        outcome.mismatchRows.append("\(mangled) [\(arenaStyle)]: arena=`\(arena ?? "<nil>")` swiftSymbol=`\(reference ?? "<nil>")`")
                    }
                }
                let reused = session.demangle(mangled, style: arenaStyle)
                if reused != arena {
                    outcome.mismatches += 1
                    if outcome.mismatchRows.count < 50 {
                        outcome.mismatchRows.append("\(mangled) [\(arenaStyle)]: session=`\(reused ?? "<nil>")` one-shot=`\(arena ?? "<nil>")`")
                    }
                }
            }
            // Scanner-window leg: the production filter (windowed candidate
            // parse on one reused arena engine) over the symbol embedded
            // mid-buffer, vs the splice the *structured* scan produces (the
            // value backend, a fresh parse per candidate — an independent
            // representation sharing only the candidate-boundary logic).
            // Splice semantics mirror `demangleAll` for `.full`: every match
            // replaced by its validated (non-empty by gate) rendering.
            outcome.comparisons += 1
            let line = windowPrefix + Array(mangled.utf8) + windowSuffix
            let produced = scanner.demangleAll(inBytes: line)
            var expected: [UInt8] = []
            var cursor = 0
            for match in scanner.matches(inBytes: line) {
                expected.append(contentsOf: line[cursor ..< match.byteRange.lowerBound])
                expected.append(contentsOf: Array(match.demangled(.full).utf8))
                cursor = match.byteRange.upperBound
            }
            expected.append(contentsOf: line[cursor...])
            if produced != expected {
                outcome.mismatches += 1
                if outcome.mismatchRows.count < 50 {
                    outcome.mismatchRows.append("\(mangled) [scanner-window]: filter=`\(String(decoding: produced, as: UTF8.self))` structured=`\(String(decoding: expected, as: UTF8.self))`")
                }
            }
        }
        return outcome
    }
}
