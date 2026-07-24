// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swiftfilt-parity live` — symbols through BOTH the engine and the live
// `xcrun swift-demangle`, diffed per style.
//
// Oracle legs (verified against the installed tool's flags):
//   full        product `.full` rendering  vs  `-compact`
//   simplified  `.simplified`              vs  `-simplified`
//   qualified   `.qualified`               vs  `-no-sugar`
//   tree        `DemangledSymbol.symbol.treeDump()` vs `-tree-only -compact`
//   classify    leading `{…}` marker tokens vs `-classify`
//   decline     decline agreement: the oracle echoes a symbol it cannot
//               demangle; swiftfilt must decline it too (and vice versa)
//   unqualified EXERCISED, NOT ORACLED — `swift-demangle` has no
//               unqualified mode; the leg renders every demangled symbol
//               and gates on emptiness/crash only. Its rendering substance
//               is owned by the fixture suites (DemangleStyleRenderingTests
//               and the corpus subcommand), stated here so an unvalidated
//               leg is never implied validated.
//
// Comparison convention: the oracle declines by echoing its input (also
// with one leading Mach-O `_` stripped); print-leg comparisons run only
// where BOTH sides demangled — the decline leg owns the disagreement when
// exactly one side declined, so one root cause is one row, not five.

import Foundation
import SwiftFilt

public func runLiveCommand(_ args: [String]) async -> Int32 {
    var limit = Int.max
    var skip = 0
    var tag: String?
    var legsSpec = "full,simplified,qualified,tree,classify,decline,unqualified"
    var batchSize = 8192
    var jobs = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    var oracleOverride: String?
    var timeout = 120.0
    var inlineRows = 25
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--limit":
            index += 1
            limit = parseCount("--limit", in: args, at: index, for: "live", minimum: 1)
        case "--skip":
            index += 1
            skip = parseCount("--skip", in: args, at: index, for: "live")
        case "--tag":
            index += 1
            guard args.indices.contains(index), !args[index].isEmpty else {
                eprint("live: --tag needs a non-empty value")
                return 2
            }
            tag = args[index]
        case "--legs":
            index += 1
            guard args.indices.contains(index) else {
                eprint("live: --legs needs a comma-separated list")
                return 2
            }
            legsSpec = args[index]
        case "--batch":
            index += 1
            batchSize = parseCount("--batch", in: args, at: index, for: "live", minimum: 1)
        case "--jobs":
            index += 1
            jobs = parseCount("--jobs", in: args, at: index, for: "live", minimum: 1)
        case "--oracle":
            index += 1
            oracleOverride = args.indices.contains(index) ? args[index] : nil
        case "--timeout":
            index += 1
            timeout = Double(parseCount("--timeout", in: args, at: index, for: "live", minimum: 1))
        case "--inline-rows":
            index += 1
            inlineRows = parseCount("--inline-rows", in: args, at: index, for: "live")
        default:
            eprint("live: unknown option \(args[index])")
            return 2
        }
        index += 1
    }

    guard let legs = LiveLegs(spec: legsSpec) else {
        eprint("live: --legs takes a comma-separated subset of full,simplified,qualified,tree,classify,decline,unqualified")
        return 2
    }
    guard let source = SymbolSource.resolve(for: "live") else { return 2 }
    guard let oracle = oracleOverride ?? Oracle.locate() else {
        eprint("live: swift-demangle not found (install an Xcode toolchain or pass --oracle PATH)")
        return 2
    }
    let oracleIdentity = "\(oracle) [\(Oracle.identity(oracle))]"
    let catalogue = DeviationCatalogue.load()
    var report = RunReport(instrument: tag.map { "live-\($0)" } ?? "live", catalogue: catalogue)
    report.note("symbols: \(source.descriptionLine)\(skip == 0 ? "" : " skip=\(grouped(skip))")\(limit == .max ? "" : " limit=\(grouped(limit))")")
    report.note("legs: \(legs.names.joined(separator: ",")) (unqualified is exercised, not oracled — no swift-demangle mode exists for it)")
    report.note("batch=\(grouped(batchSize)) jobs=\(jobs) timeout=\(Int(timeout))s")
    print("[live] oracle: \(oracleIdentity)")
    print("[live] source: \(source.descriptionLine)")

    let started = Date()
    let processed: Int
    switch source {
    case let .fixtures(symbols):
        let capped = Array(symbols.dropFirst(skip).prefix(limit))
        processed = await sweep(
            batches: BatchSequence(symbols: capped, batchSize: batchSize),
            totalHint: capped.count,
            oracle: oracle, legs: legs, jobs: jobs, timeout: timeout, report: &report,
        )
    case let .manifest(path):
        guard let reader = ManifestBatchReader(path: path, batchSize: batchSize, limit: limit, skip: skip) else {
            eprint("live: could not open \(path)")
            return 2
        }
        processed = await sweep(
            batches: BatchSequence(reader: reader),
            totalHint: nil,
            oracle: oracle, legs: legs, jobs: jobs, timeout: timeout, report: &report,
        )
    }
    report.note("symbols processed: \(grouped(processed)) in \(secondsText(Date().timeIntervalSince(started)))")

    if let tsv = report.writeGatingRows(toDirectory: repositoryRoot().appendingPathComponent(".build/parity-reports").path) {
        report.note("gating rows TSV: \(tsv)")
    }
    print(report.render(inlineRowLimit: inlineRows, oracleIdentity: oracleIdentity))
    return report.exitCode
}

/// The selected oracle legs.
public struct LiveLegs: Sendable {
    public var full = false
    public var simplified = false
    public var qualified = false
    public var tree = false
    public var classify = false
    public var decline = false
    public var unqualified = false

    public init?(spec: String) {
        for name in spec.split(separator: ",") {
            switch name.trimmingCharacters(in: .whitespaces) {
            case "full": full = true
            case "simplified": simplified = true
            case "qualified": qualified = true
            case "tree": tree = true
            case "classify": classify = true
            case "decline": decline = true
            case "unqualified": unqualified = true
            default: return nil
            }
        }
        guard full || simplified || qualified || tree || classify || decline || unqualified else { return nil }
    }

    public var names: [String] {
        var out: [String] = []
        if full { out.append("full") }
        if simplified { out.append("simplified") }
        if qualified { out.append("qualified") }
        if tree { out.append("tree") }
        if classify { out.append("classify") }
        if decline { out.append("decline") }
        if unqualified { out.append("unqualified") }
        return out
    }

    /// The oracle modes these legs require. `-compact` is always fetched:
    /// it is the decline reference every other leg's skip rule keys on.
    var oracleModes: Oracle.Modes {
        var modes: Oracle.Modes = [.compact]
        if tree { modes.insert(.tree) }
        if simplified { modes.insert(.simplified) }
        if qualified { modes.insert(.noSugar) }
        if classify { modes.insert(.classify) }
        return modes
    }
}

/// A batch source unifying the in-memory fixture list and the streaming
/// manifest reader (single-consumer; driven only from the reducer task).
final class BatchSequence {
    private var symbols: [String] = []
    private var offset = 0
    private let batchSize: Int
    private let reader: ManifestBatchReader?

    init(symbols: [String], batchSize: Int) {
        self.symbols = symbols
        self.batchSize = batchSize
        reader = nil
    }

    init(reader: ManifestBatchReader) {
        self.reader = reader
        batchSize = 0
    }

    func next() -> [String]? {
        if let reader {
            return reader.next()
        }
        guard offset < symbols.count else { return nil }
        let end = min(offset + batchSize, symbols.count)
        defer { offset = end }
        return Array(symbols[offset ..< end])
    }
}

private struct BatchOutcome: Sendable {
    let index: Int
    let count: Int
    var comparisons: [String: Int] = [:]
    var divergences: [Divergence] = []
    var harnessError: String?

    init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

/// Drive all batches through a bounded TaskGroup, absorbing outcomes into
/// the report in batch order (deterministic output regardless of
/// completion order). Returns the number of symbols processed.
private func sweep(
    batches: BatchSequence, totalHint: Int?, oracle: String, legs: LiveLegs,
    jobs: Int, timeout: Double, report: inout RunReport,
) async -> Int {
    var processed = 0
    var nextToAbsorb = 0
    var pending: [Int: BatchOutcome] = [:]
    var lastProgress = Date()
    let progressEvery = 15.0

    // Local copy for absorption inside the group (inout cannot cross the
    // task boundary); merged back after the group completes.
    var localReport = report
    await withTaskGroup(of: BatchOutcome.self) { group in
        var inFlight = 0
        var dispatched = 0
        func fill() {
            while inFlight < jobs, let batch = batches.next() {
                let batchIndex = dispatched
                dispatched += 1
                group.addTask {
                    await diffBatch(batch, index: batchIndex, oracle: oracle, legs: legs, timeout: timeout)
                }
                inFlight += 1
            }
        }
        func absorbReady() {
            while let outcome = pending.removeValue(forKey: nextToAbsorb) {
                nextToAbsorb += 1
                processed += outcome.count
                for (leg, count) in outcome.comparisons {
                    localReport.countComparison(leg: leg, by: count)
                }
                for divergence in outcome.divergences {
                    localReport.record(divergence)
                }
                if let error = outcome.harnessError {
                    localReport.recordHarnessError(error)
                }
            }
            if Date().timeIntervalSince(lastProgress) > progressEvery {
                lastProgress = Date()
                let total = totalHint.map { "/\(grouped($0))" } ?? ""
                print("[live] processed \(grouped(processed))\(total) symbols, gating so far: \(grouped(localReport.gatingTotal))")
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
    report = localReport
    return processed
}

/// Diff one batch: the oracle's five output modes (as the legs require)
/// against the engine, on a large-stack worker (deep corpus symbols nest
/// past the cooperative pool's stack).
private func diffBatch(_ symbols: [String], index: Int, oracle: String, legs: LiveLegs, timeout: Double) async -> BatchOutcome {
    guard let outputs = Oracle.fetch(symbols, oracle: oracle, modes: legs.oracleModes, timeout: timeout) else {
        // A whole-batch oracle failure (timeout/misalignment/launch) is a
        // harness problem: abort scoring loudly, never mis-attribute it.
        var outcome = BatchOutcome(index: index, count: symbols.count)
        outcome.harnessError = "batch \(index) (\(symbols.count) symbols starting \(symbols.first ?? "")): swift-demangle invocation failed or timed out"
        return outcome
    }
    return await onLargeStack {
        var result = BatchOutcome(index: index, count: symbols.count)
        compareBatch(symbols, outputs: outputs, legs: legs, into: &result)
        return result
    }
}

private func compareBatch(_ symbols: [String], outputs: Oracle.BatchOutputs, legs: LiveLegs, into outcome: inout BatchOutcome) {
    let printer = SwiftDemanglerPrinter()
    for (idx, mangled) in symbols.enumerated() {
        let symbol = DemangledSymbol(mangled)
        let oracleFull = outputs.compact[idx]
        let oracleFullDeclined = oracleDeclined(oracleFull, mangled: mangled)
        // The oracle's stdin filter rewrites the mangled SPAN it finds in
        // the line: for a Mach-O `__…` name it matches from the second
        // underscore and echoes the first (`__TM…` → `_type metadata …`),
        // while the whole-name path both tools share strips that
        // underscore before demangling (swift-demangle.cpp `demangle()`;
        // the product's documented `__T` adapter). Render-leg equality
        // for `__…` names therefore means: oracle line == "_" + render.
        let underscoreShifted = mangled.hasPrefix("__")
        func rendersEqual(_ engine: String, _ oracle: String) -> Bool {
            engine == oracle || (underscoreShifted && oracle == "_" + engine)
        }
        // Tier-0 decline semantics: `demangle()` is nil for no-tree AND for
        // an empty `.full` render; the product's echo behavior keys on it.
        let engineFull = symbol.map { printer.print($0.symbol, style: .full) }
        let engineDeclined = engineFull == nil || engineFull!.isEmpty

        if legs.decline {
            outcome.comparisons["decline", default: 0] += 1
            if oracleFullDeclined, !engineDeclined {
                outcome.divergences.append(Divergence(
                    leg: "decline", klass: "swiftfilt-superset", mangled: mangled,
                    swiftfilt: engineFull ?? "", oracle: "<oracle echoed (declined)>",
                ))
            } else if !oracleFullDeclined, engineDeclined {
                outcome.divergences.append(Divergence(
                    leg: "decline", klass: "swiftfilt-declined", mangled: mangled,
                    swiftfilt: engineFull == nil ? "<nil>" : "<empty .full render>", oracle: oracleFull,
                ))
            }
        }

        // Print legs: only where both sides demangled (the decline leg owns
        // one-sided rows — one root cause, one row).
        if let symbol, let engineFull, !engineDeclined {
            if legs.full, !oracleFullDeclined {
                outcome.comparisons["full", default: 0] += 1
                if !rendersEqual(engineFull, oracleFull) {
                    outcome.divergences.append(Divergence(
                        leg: "full", klass: "render-mismatch", mangled: mangled,
                        swiftfilt: engineFull, oracle: oracleFull,
                    ))
                }
            }
            if legs.simplified {
                let oracleLine = outputs.simplified[idx]
                if !oracleDeclined(oracleLine, mangled: mangled) {
                    outcome.comparisons["simplified", default: 0] += 1
                    let engine = printer.print(symbol.symbol, style: .simplified)
                    if !rendersEqual(engine, oracleLine) {
                        outcome.divergences.append(Divergence(
                            leg: "simplified", klass: "render-mismatch", mangled: mangled,
                            swiftfilt: engine, oracle: oracleLine,
                        ))
                    }
                }
            }
            if legs.qualified {
                let oracleLine = outputs.noSugar[idx]
                if !oracleDeclined(oracleLine, mangled: mangled) {
                    outcome.comparisons["qualified", default: 0] += 1
                    let engine = printer.print(symbol.symbol, style: .qualified)
                    if !rendersEqual(engine, oracleLine) {
                        outcome.divergences.append(Divergence(
                            leg: "qualified", klass: "render-mismatch", mangled: mangled,
                            swiftfilt: engine, oracle: oracleLine,
                        ))
                    }
                }
            }
            if legs.tree {
                let oracleTree = outputs.tree[idx].trimmedTrailingNewlines()
                if !oracleTree.isEmpty, !oracleTree.contains("<<NULL>>") {
                    outcome.comparisons["tree", default: 0] += 1
                    let engineTree = symbol.symbol.treeDump().trimmedTrailingNewlines()
                    if engineTree != oracleTree {
                        outcome.divergences.append(Divergence(
                            leg: "tree", klass: "tree-mismatch", mangled: mangled,
                            swiftfilt: firstDifferingLine(engineTree, oracleTree, wantFirst: true),
                            oracle: firstDifferingLine(engineTree, oracleTree, wantFirst: false),
                        ))
                    }
                }
            }
            if legs.classify {
                let oracleLine = outputs.classify[idx]
                if !oracleDeclined(oracleLine, mangled: mangled) {
                    outcome.comparisons["classify", default: 0] += 1
                    let oracleMarker = leadingBraceTokens(oracleLine)
                    // Markers are computed on the underscore-stripped name,
                    // exactly as the tool does before classifying.
                    let classifyName = underscoreShifted ? String(mangled.dropFirst()) : mangled
                    let engineMarker = printer.classify(classifyName, demangled: symbol.symbol)
                    if engineMarker != oracleMarker {
                        outcome.divergences.append(Divergence(
                            leg: "classify", klass: "classify-mismatch", mangled: mangled,
                            swiftfilt: engineMarker.isEmpty ? "<none>" : engineMarker,
                            oracle: oracleMarker.isEmpty ? "<none>" : oracleMarker,
                        ))
                    }
                }
            }
            if legs.unqualified {
                outcome.comparisons["unqualified", default: 0] += 1
                if printer.print(symbol.symbol, style: .unqualified).isEmpty {
                    outcome.divergences.append(Divergence(
                        leg: "unqualified", klass: "render-empty", mangled: mangled,
                        swiftfilt: "<empty .unqualified render>", oracle: "<no oracle mode; emptiness gates>",
                    ))
                }
            }
        }
    }
}

/// The leading `{…}` classification group of a `swift-demangle -classify`
/// line, or "" when the line has none. Validated against the tool's
/// marker grammar — `{X(,X)*}` where X is `N`, `C`, or `T:<target>` — so a
/// demangling that itself begins with a brace (SIL box types render as
/// `{ let Swift.Int }`) is never mistaken for a marker.
public func leadingBraceTokens(_ line: String) -> String {
    guard line.first == "{", let close = line.firstIndex(of: "}") else { return "" }
    let content = line[line.index(after: line.startIndex) ..< close]
    guard !content.isEmpty else { return "" }
    for token in content.split(separator: ",", omittingEmptySubsequences: false) {
        guard token == "N" || token == "C" || token.hasPrefix("T:") else { return "" }
    }
    return String(line[line.startIndex ... close])
}

/// The first line where two multi-line dumps differ (tree divergences are
/// reported by their first differing node, not two full trees).
public func firstDifferingLine(_ mine: String, _ theirs: String, wantFirst: Bool) -> String {
    let a = mine.split(separator: "\n", omittingEmptySubsequences: false)
    let b = theirs.split(separator: "\n", omittingEmptySubsequences: false)
    for idx in 0 ..< max(a.count, b.count) {
        let mineLine = idx < a.count ? String(a[idx]) : "<none>"
        let theirsLine = idx < b.count ? String(b[idx]) : "<none>"
        if mineLine != theirsLine { return wantFirst ? mineLine : theirsLine }
    }
    return "<equal>"
}
