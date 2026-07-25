// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swiftfilt-parity roundtrip` — demangle → remangle (the shipped
// `SwiftMangler`) → compare against the original mangled name.
//
// The supported-input rule, derived from the grammar and the reference
// implementation rather than asserted by fiat:
//   * pass 1 (engine-only): a remangling that is byte-exact, or that
//     re-demangles to the identical tree (lossless canonicalization, and
//     every legacy input that converts to `$s` losslessly), passes.
//   * pass 2 (oracle adjudication): every other row — nil remangles and
//     non-identity conversions — is re-driven through the reference
//     remangler (`swift-demangle -remangle-new`). A conversion the
//     reference reproduces byte-for-byte is `conversion-oracle-confirmed`
//     (apple's own converter emits the same bytes; this includes the
//     Suffix-carrying trees whose `$s` form does not re-demangle even
//     when apple emits it — measured, not assumed). A nil where the
//     reference also errors is `remangle-mutual-decline`. Everything else
//     gates: `remangle-nil` (the reference converts, SwiftFilt cannot),
//     `remangle-diverges-from-oracle` (both convert, differently), and
//     `conversion-not-confirmed` / `remangle-nil-oracle-blind` (the
//     oracle cannot even demangle the input, so nothing confirms the
//     engine's behavior). No oracle ⇒ pass-2 rows gate as
//     `conversion-unadjudicated` — never a silent pass.

import Foundation
import SwiftFilt

public func runRoundtripCommand(_ args: [String]) async -> Int32 {
    var limit = Int.max
    var skip = 0
    var tag: String?
    var batchSize = 16384
    var jobs = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    var inlineRows = 25
    var oracleOverride: String?
    var timeout = 120.0
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--limit":
            index += 1
            limit = parseCount("--limit", in: args, at: index, for: "roundtrip", minimum: 1)
        case "--skip":
            index += 1
            skip = parseCount("--skip", in: args, at: index, for: "roundtrip")
        case "--tag":
            index += 1
            guard args.indices.contains(index), !args[index].isEmpty else {
                eprint("roundtrip: --tag needs a non-empty value")
                return 2
            }
            tag = args[index]
        case "--batch":
            index += 1
            batchSize = parseCount("--batch", in: args, at: index, for: "roundtrip", minimum: 1)
        case "--jobs":
            index += 1
            jobs = parseCount("--jobs", in: args, at: index, for: "roundtrip", minimum: 1)
        case "--inline-rows":
            index += 1
            inlineRows = parseCount("--inline-rows", in: args, at: index, for: "roundtrip")
        case "--oracle":
            index += 1
            oracleOverride = args.indices.contains(index) ? args[index] : nil
        case "--timeout":
            index += 1
            timeout = Double(parseCount("--timeout", in: args, at: index, for: "roundtrip", minimum: 1))
        default:
            eprint("roundtrip: unknown option \(args[index])")
            return 2
        }
        index += 1
    }

    guard let source = SymbolSource.resolve(for: "roundtrip") else { return 2 }
    let catalogue = DeviationCatalogue.load()
    var report = RunReport(instrument: tag.map { "roundtrip-\($0)" } ?? "roundtrip", catalogue: catalogue)
    let oracle = if let oracleOverride { oracleOverride } else { await Oracle.locate() }
    let oracleIdentity: String? = if let oracle { await "\(oracle) [\(Oracle.identity(oracle))]" } else { nil }
    report.note("symbols: \(source.descriptionLine)\(skip == 0 ? "" : " skip=\(grouped(skip))")\(limit == .max ? "" : " limit=\(grouped(limit))")")
    if oracle == nil {
        report.note("oracle: NONE — non-identity conversions gate as conversion-unadjudicated")
    }
    print("[roundtrip] source: \(source.descriptionLine)")
    if let oracleIdentity {
        print("[roundtrip] adjudication oracle: \(oracleIdentity)")
    }

    let started = Date()
    var totals = RoundtripTotals()
    var candidates: [RoundtripCandidate] = []
    let batches: BatchSequence
    switch source {
    case let .fixtures(symbols):
        batches = BatchSequence(symbols: Array(symbols.dropFirst(skip).prefix(limit)), batchSize: batchSize)
    case let .manifest(path):
        guard let reader = ManifestBatchReader(path: path, batchSize: batchSize, limit: limit, skip: skip) else {
            eprint("roundtrip: could not open \(path)")
            return 2
        }
        batches = BatchSequence(reader: reader)
    }

    // Pass 1: engine-only identity floor.
    await withTaskGroup(of: RoundtripBatch.self) { group in
        var inFlight = 0
        var dispatched = 0
        var nextToAbsorb = 0
        var pending: [Int: RoundtripBatch] = [:]
        var lastProgress = Date()
        func fill() {
            while inFlight < jobs, let batch = batches.next() {
                let batchIndex = dispatched
                dispatched += 1
                group.addTask {
                    await onLargeStack { roundtripBatch(batch, index: batchIndex) }
                }
                inFlight += 1
            }
        }
        func absorbReady() {
            while let outcome = pending.removeValue(forKey: nextToAbsorb) {
                nextToAbsorb += 1
                totals.absorb(outcome.totals)
                candidates.append(contentsOf: outcome.candidates)
            }
            if Date().timeIntervalSince(lastProgress) > 15 {
                lastProgress = Date()
                print("[roundtrip] pass 1: \(grouped(totals.seen)) symbols, adjudication candidates so far: \(grouped(candidates.count))")
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

    // Pass 2: oracle adjudication of every non-identity row.
    var confirmedConversions = 0
    var confirmedSuffixConversions = 0
    var mutualDeclines = 0
    if !candidates.isEmpty {
        print("[roundtrip] pass 2: adjudicating \(grouped(candidates.count)) non-identity rows against the reference remangler")
        guard let oracle else {
            for candidate in candidates {
                report.record(Divergence(
                    leg: "roundtrip", klass: "conversion-unadjudicated", mangled: candidate.mangled,
                    swiftfilt: candidate.remangled ?? "<remangle returned nil>",
                    oracle: "<no swift-demangle available to adjudicate>",
                ))
            }
            return finishRoundtrip(&report, totals: totals, candidates: candidates.count,
                                   confirmed: 0, confirmedSuffix: 0, mutualDeclines: 0,
                                   started: started, inlineRows: inlineRows, oracleIdentity: nil)
        }
        var start = 0
        let adjudicationChunk = 4096
        while start < candidates.count {
            let chunk = Array(candidates[start ..< min(start + adjudicationChunk, candidates.count)])
            start += chunk.count
            guard let verdicts = await referenceRemangle(chunk.map(\.mangled), oracle: oracle, timeout: timeout) else {
                report.recordHarnessError("swift-demangle -remangle-new adjudication failed for a \(chunk.count)-row chunk starting \(chunk.first?.mangled ?? "")")
                continue
            }
            // The decline reference: which of these can the oracle demangle
            // at all (an echo from -remangle-new is only an identity
            // remangling when the oracle actually demangles the symbol).
            guard let compactLines = await Oracle.lines(chunk.map(\.mangled), oracle: oracle, flags: ["-compact"], timeout: timeout) else {
                report.recordHarnessError("swift-demangle -compact adjudication failed for a \(chunk.count)-row chunk starting \(chunk.first?.mangled ?? "")")
                continue
            }
            for (idx, candidate) in chunk.enumerated() {
                var oracleRemangled = verdicts[idx]
                // The stdin filter rewrites the SPAN of a Mach-O `__…`
                // name (from the second underscore) and echoes the first,
                // so its remangling is `_` + the whole-name remangling —
                // the same convention the render legs ground in
                // swift-demangle.cpp's `__` strip. Normalize before
                // comparing.
                if candidate.mangled.hasPrefix("__"), let theirs = oracleRemangled,
                   let mine = candidate.remangled, theirs == "_" + mine
                {
                    oracleRemangled = String(theirs.dropFirst())
                }
                let oracleDemangles = !oracleDeclined(compactLines[idx], mangled: candidate.mangled)
                switch (candidate.remangled, oracleRemangled) {
                case let (.some(mine), .some(theirs)) where mine == theirs:
                    if oracleDemangles || theirs != candidate.mangled {
                        confirmedConversions += 1
                        if candidate.treeHasSuffix { confirmedSuffixConversions += 1 }
                    } else {
                        // The oracle echoed a symbol it cannot demangle —
                        // its "agreement" is no opinion at all.
                        report.record(Divergence(
                            leg: "roundtrip", klass: "conversion-not-confirmed", mangled: candidate.mangled,
                            swiftfilt: mine, oracle: "<oracle cannot demangle the input; no adjudication>",
                        ))
                    }
                case let (.some(mine), .some(theirs)):
                    report.record(Divergence(
                        leg: "roundtrip", klass: "remangle-diverges-from-oracle", mangled: candidate.mangled,
                        swiftfilt: mine, oracle: theirs,
                    ))
                case let (.some(mine), .none):
                    report.record(Divergence(
                        leg: "roundtrip", klass: "conversion-not-confirmed", mangled: candidate.mangled,
                        swiftfilt: mine, oracle: "<reference remangler errored>",
                    ))
                case (.none, .none):
                    mutualDeclines += 1
                case let (.none, .some(theirs)):
                    if oracleDemangles || theirs != candidate.mangled {
                        report.record(Divergence(
                            leg: "roundtrip", klass: "remangle-nil", mangled: candidate.mangled,
                            swiftfilt: "<remangle returned nil>", oracle: theirs,
                        ))
                    } else {
                        report.record(Divergence(
                            leg: "roundtrip", klass: "remangle-nil-oracle-blind", mangled: candidate.mangled,
                            swiftfilt: "<remangle returned nil>", oracle: "<oracle cannot demangle the input>",
                        ))
                    }
                }
            }
        }
    }

    return finishRoundtrip(&report, totals: totals, candidates: candidates.count,
                           confirmed: confirmedConversions, confirmedSuffix: confirmedSuffixConversions,
                           mutualDeclines: mutualDeclines, started: started, inlineRows: inlineRows,
                           oracleIdentity: oracleIdentity)
}

private func finishRoundtrip(
    _ report: inout RunReport, totals: RoundtripTotals, candidates: Int,
    confirmed: Int, confirmedSuffix: Int, mutualDeclines: Int,
    started: Date, inlineRows: Int, oracleIdentity: String?,
) -> Int32 {
    report.countComparison(leg: "roundtrip", by: totals.demangled)
    report.note("symbols processed: \(grouped(totals.seen)) in \(secondsText(Date().timeIntervalSince(started)))")
    report.note("""
    round-trip outcome (exact counts):
      demangled: \(grouped(totals.demangled)) of \(grouped(totals.seen)) (\(grouped(totals.declined)) declined — non-Swift or unparseable, no round-trip to hold)
      byte-exact: \(grouped(totals.byteExact))
      canonicalized (re-demangles to the identical tree): current-grammar=\(grouped(totals.canonicalizedCurrent)) legacy-to-$s=\(grouped(totals.canonicalizedLegacy))
      oracle-adjudicated conversions: \(grouped(candidates)) candidate(s) → confirmed=\(grouped(confirmed)) (of which Suffix-carrying trees=\(grouped(confirmedSuffix))) mutual-decline=\(grouped(mutualDeclines))
    """)
    if let tsv = report.writeGatingRows(toDirectory: repositoryRoot().appendingPathComponent(".build/parity-reports").path) {
        report.note("gating rows TSV: \(tsv)")
    }
    print(report.render(inlineRowLimit: inlineRows, oracleIdentity: oracleIdentity))
    return report.exitCode
}

/// Run the reference remangler over one chunk. Successful conversions
/// come back 1:1 on stdout; a failing row surfaces on stderr as
/// `Error: (…) unable to re-mangle <symbol>` — and the tool ABORTS the
/// stream there (measured: rows after the first error are never
/// processed). So the loop is: map the successful prefix 1:1, mark the
/// errored row nil, verify the errored name is exactly the next
/// unaccounted symbol, and resubmit the tail. Returns one `String?` per
/// input (nil = the reference errored on that row), or nil for an
/// unreconstructable invocation (timeout, invariant violation) — the
/// caller records a loud harness error, never a guess.
public func referenceRemangle(_ symbols: [String], oracle: String, timeout: Double) async -> [String?]? {
    var results: [String?] = []
    results.reserveCapacity(symbols.count)
    var remaining = symbols[...]
    while !remaining.isEmpty {
        let stdin = Data((remaining.joined(separator: "\n") + "\n").utf8)
        guard let proc = await runSubprocess(oracle, ["-remangle-new"], stdin: stdin, timeoutSeconds: timeout),
              !proc.timedOut
        else { return nil }
        var stdoutLines = proc.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if stdoutLines.last == "" { stdoutLines.removeLast() }
        let firstError: String? = proc.stderr.split(separator: "\n").lazy.compactMap { line -> String? in
            guard let range = line.range(of: "unable to re-mangle ") else { return nil }
            return String(line[range.upperBound...])
        }.first
        guard let firstError else {
            // No error: the whole remainder must have mapped 1:1.
            guard stdoutLines.count == remaining.count else { return nil }
            results.append(contentsOf: stdoutLines.map(\.self))
            return results
        }
        // Aborted at the errored row: the successful prefix maps 1:1 and
        // the very next symbol must be the one stderr names.
        let errorIndex = remaining.startIndex + stdoutLines.count
        guard errorIndex < remaining.endIndex, remaining[errorIndex] == firstError else { return nil }
        results.append(contentsOf: stdoutLines.map(\.self))
        results.append(nil)
        remaining = remaining[remaining.index(after: errorIndex)...]
    }
    return results
}

struct RoundtripTotals: Sendable {
    var seen = 0
    var declined = 0
    var demangled = 0
    var byteExact = 0
    var canonicalizedCurrent = 0
    var canonicalizedLegacy = 0

    mutating func absorb(_ other: RoundtripTotals) {
        seen += other.seen
        declined += other.declined
        demangled += other.demangled
        byteExact += other.byteExact
        canonicalizedCurrent += other.canonicalizedCurrent
        canonicalizedLegacy += other.canonicalizedLegacy
    }
}

/// One row pass 1 could not settle: the engine's remangling (nil when the
/// remangler declined) and whether the tree carries an unmangled Suffix.
struct RoundtripCandidate: Sendable {
    let mangled: String
    let remangled: String?
    let treeHasSuffix: Bool
}

struct RoundtripBatch: Sendable {
    let index: Int
    var totals = RoundtripTotals()
    var candidates: [RoundtripCandidate] = []
}

/// True when the tree carries an unmangled `Suffix` node anywhere —
/// trailing bytes no demangler could parse, which no `$s` production can
/// express (measured: apple's own remangler emits mangled+suffix bytes
/// that its own demangler then rejects).
func treeContainsSuffix(_ symbol: SwiftSymbol) -> Bool {
    if symbol.kind == .Suffix { return true }
    for child in symbol.children where treeContainsSuffix(child) {
        return true
    }
    return false
}

/// True for inputs in a pre-`$s` grammar (legacy `_T`/`_Tt`/`__T` and the
/// Swift 4 `_T0` era) — the forms that re-mangle to the modern grammar by
/// design and can never be byte-exact.
func isLegacyMangling(_ mangled: String) -> Bool {
    var name = Substring(mangled)
    if name.hasPrefix("__T") { name = name.dropFirst() }
    return name.hasPrefix("_T")
}

func roundtripBatch(_ symbols: [String], index: Int) -> RoundtripBatch {
    var out = RoundtripBatch(index: index)
    let demangler = SwiftDemangler()
    let mangler = SwiftMangler()
    for mangled in symbols {
        out.totals.seen += 1
        guard let symbol = DemangledSymbol(mangled) else {
            out.totals.declined += 1
            continue
        }
        out.totals.demangled += 1
        let ast = symbol.symbol
        let canonical = mangled.hasPrefix("_") ? String(mangled.dropFirst()) : mangled
        guard let remangled = mangler.mangle(ast) else {
            out.candidates.append(RoundtripCandidate(mangled: mangled, remangled: nil, treeHasSuffix: treeContainsSuffix(ast)))
            continue
        }
        if remangled == mangled || remangled == canonical {
            out.totals.byteExact += 1
            continue
        }
        if demangler.demangle(symbol: remangled)?.treeDump() == ast.treeDump() {
            if isLegacyMangling(mangled) {
                out.totals.canonicalizedLegacy += 1
            } else {
                out.totals.canonicalizedCurrent += 1
            }
            continue
        }
        out.candidates.append(RoundtripCandidate(mangled: mangled, remangled: remangled, treeHasSuffix: treeContainsSuffix(ast)))
    }
    return out
}
