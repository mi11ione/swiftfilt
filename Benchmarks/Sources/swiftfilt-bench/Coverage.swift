// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The rendering-agreement vector: over the committed fixture stream,
// what fraction of symbols does each contender (a) resolve at all and
// (b) render BYTE-IDENTICALLY to the frozen ground truth — the
// fixtures' committed full-style renderings, themselves verified
// against `swift-demangle` by the repository's parity instrument.
// Measured, never asserted: every contender's output is byte-compared
// row by row, and differences split into differing-output vs declined,
// with a per-grammar-era breakdown so a stale grammar shows exactly
// where it is stale.
//
// A difference is NOT automatically a defect, and this vector must not
// be read as if it were: an engine with no output-format contract (the
// runtime's, per SE-0498) renders types unsugared and so differs on
// every sugared type while being perfectly correct. `conventionOnly`
// below separates those from genuine rendering defects.
//
// Ground truth is ALWAYS the committed fixtures (10,845 rows; an
// external SWIFTFILT_DEMANGLE_CORPUS has no verified rendering column,
// so the coverage census ignores it). Exactly one fixture row's
// expectation is the oracle's DECLINE (its column 2 echoes the mangled
// name — `swift-demangle` echo semantics); that row is excluded from
// the resolve/agreement percentages and reported on its own line,
// per contender, so the census never grades "resolving" a row whose
// verified answer is a refusal.

import Foundation
import SwiftFilt

// MARK: - Ground truth

/// One fixture row: the mangled name and its frozen full-style
/// rendering. `expectsDecline` marks the oracle-echo row.
struct GroundTruthRow {
    let mangled: String
    let expected: String

    var expectsDecline: Bool {
        expected == mangled
    }
}

/// Load the frozen ground truth: column 1 (mangled) and column 2 (the
/// verified full-style rendering) of the committed fixture corpora, in
/// file order — the same stream every speed benchmark runs.
func loadGroundTruth() -> [GroundTruthRow] {
    let fixturesDir = repositoryFixturesDirectory()
    var rows: [GroundTruthRow] = []
    for file in ["corpus.tsv", "apple.tsv", "legacy.tsv"] {
        let path = fixturesDir + "/" + file
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fatalError("swiftfilt-bench: cannot read the bundled fixture corpus at \(path)")
        }
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 2 else { continue }
            rows.append(GroundTruthRow(mangled: String(columns[0]), expected: String(columns[1])))
        }
    }
    return rows
}

/// Grammar-era bucket for the per-era breakdown, keyed on the mangling
/// prefix (a leading `_` before `$` is the Mach-O form of the same era).
func manglingEra(_ mangled: String) -> String {
    var name = Substring(mangled)
    if name.hasPrefix("_$") { name = name.dropFirst() }
    if name.hasPrefix("@__swiftmacro_") { return "macro" }
    if name.hasPrefix("$s") || name.hasPrefix("$S") { return "stable $s" }
    if name.hasPrefix("$e") { return "embedded $e" }
    if name.hasPrefix("_T0") { return "swift4 _T0" }
    if name.hasPrefix("_Tt") { return "objc _Tt" }
    if name.hasPrefix("_T") { return "legacy _T" }
    return "other"
}

/// Display order for era rows (fixture population order, stable).
let eraOrder = ["stable $s", "swift4 _T0", "legacy _T", "objc _Tt", "macro", "embedded $e", "other"]

// MARK: - Census result

/// One contender's coverage census. Percentages are over the VERIFIED
/// renderings (rows whose expectation is a demangling, not a decline).
struct CoverageResult {
    /// Stable contender identifier (JSON key, README row).
    let contender: String
    /// The best-case configuration the contender ran (fairness note).
    let configuration: String
    /// Verified-rendering rows measured.
    let rows: Int
    /// Rows the contender produced any output for.
    var resolved = 0
    /// Rows whose output matched the frozen rendering byte-for-byte.
    var byteCorrect = 0
    /// Resolved, but not byte-identical to the frozen rendering.
    var wrongOutput = 0
    /// The subset of `wrongOutput` that byte-matches the tool's own
    /// `--no-sugar` rendering of the same symbol — a display-convention
    /// divergence (same demangling, unsugared types), not a misparse.
    var conventionOnly = 0
    /// No output (the contender declined the symbol).
    var declined = 0
    /// Per-era `correct/total` breakdown.
    var eras: [String: (correct: Int, total: Int)] = [:]
    /// What the contender did on the one expected-decline fixture row.
    var declineRowVerdict = ""

    var resolvedPercent: Double {
        rows > 0 ? Double(resolved) / Double(rows) * 100 : 0
    }

    var byteCorrectPercent: Double {
        rows > 0 ? Double(byteCorrect) / Double(rows) * 100 : 0
    }
}

/// Run one in-process contender over the ground truth. `call` returns
/// the contender's full-style output or nil for a decline. `noSugar`
/// (when available) is the tool's own `--no-sugar` rendering per
/// symbol, used ONLY to classify a miss as convention-vs-divergence —
/// it never makes a wrong row correct.
func censusInProcess(
    contender: String,
    configuration: String,
    groundTruth: [GroundTruthRow],
    noSugar: [String: String],
    call: (String) -> String?,
) -> CoverageResult {
    var result = CoverageResult(
        contender: contender,
        configuration: configuration,
        rows: groundTruth.count(where: { !$0.expectsDecline }),
    )
    for row in groundTruth {
        let output = call(row.mangled)
        if row.expectsDecline {
            result.declineRowVerdict = output == nil
                ? "declined (agrees with the oracle)"
                : "resolves it (lenient superset)"
            continue
        }
        score(&result, row: row, output: output, noSugar: noSugar)
    }
    return result
}

private func score(_ result: inout CoverageResult, row: GroundTruthRow, output: String?, noSugar: [String: String]) {
    let era = manglingEra(row.mangled)
    var eraEntry = result.eras[era] ?? (0, 0)
    eraEntry.total += 1
    if let output {
        result.resolved += 1
        if output == row.expected {
            result.byteCorrect += 1
            eraEntry.correct += 1
        } else {
            result.wrongOutput += 1
            if noSugar[row.mangled] == output {
                result.conventionOnly += 1
            }
        }
    } else {
        result.declined += 1
    }
    result.eras[era] = eraEntry
}

/// The tool's `--no-sugar` rendering for every ground-truth symbol — a
/// derived secondary oracle, computed live from the pinned tool, that
/// the census uses to split byte-misses into display-convention vs real
/// divergence. Empty on tool failure (the split then reports 0 and the
/// strict numbers stand alone).
func loadNoSugarTruth(tool: SubprocessDemangler, groundTruth: [GroundTruthRow]) -> [String: String] {
    var truth: [String: String] = [:]
    truth.reserveCapacity(groundTruth.count)
    forEachArgsChunk(tool: tool, groundTruth: groundTruth, extraFlags: ["--no-sugar"]) { row, line in
        if line != row.mangled {
            truth[row.mangled] = line
        }
    }
    return truth
}

/// Drive the tool over the ground truth in args-mode chunks (under the
/// kernel argv limit), pairing each row with its output line. Stops —
/// leaving the visitor's collection partial — on a spawn or alignment
/// failure.
private func forEachArgsChunk(
    tool: SubprocessDemangler,
    groundTruth: [GroundTruthRow],
    extraFlags: [String],
    visit: (GroundTruthRow, String) -> Void,
) {
    let chunkSize = 400
    var index = 0
    while index < groundTruth.count {
        let chunk = Array(groundTruth[index ..< min(index + chunkSize, groundTruth.count)])
        index += chunkSize
        guard let lines = tool.demangleArguments(chunk.map(\.mangled), extraFlags: extraFlags),
              lines.count == chunk.count else { return }
        for (row, line) in zip(chunk, lines) {
            visit(row, line)
        }
    }
}

/// The subprocess contender's census: `swift-demangle -compact` in ARGS
/// mode — the whole-name path, its best case for coverage (the stdin
/// filter grades its candidate scanner too; the card measures the
/// demangler). Echo of the input name is the tool's decline.
func censusSubprocess(tool: SubprocessDemangler, groundTruth: [GroundTruthRow], noSugar: [String: String]) -> CoverageResult? {
    var result = CoverageResult(
        contender: "swift-demangle",
        configuration: "args mode (`swift-demangle -compact <names…>`, chunked) — the whole-name path; echo = decline",
        rows: groundTruth.count(where: { !$0.expectsDecline }),
    )
    var visited = 0
    forEachArgsChunk(tool: tool, groundTruth: groundTruth, extraFlags: []) { row, line in
        visited += 1
        let output: String? = line == row.mangled ? nil : line
        if row.expectsDecline {
            result.declineRowVerdict = output == nil
                ? "declined (echoes the name — the verified expectation)"
                : "resolves it"
            return
        }
        score(&result, row: row, output: output, noSugar: noSugar)
    }
    return visited == groundTruth.count ? result : nil
}

// MARK: - Output

@MainActor func printCoverage(_ results: [CoverageResult], groundTruth: [GroundTruthRow]) {
    let verified = groundTruth.count(where: { !$0.expectsDecline })
    let declineRow = groundTruth.first(where: { $0.expectsDecline })
    print("\ncoverage (vs frozen ground truth: \(verified) verified renderings from the committed fixtures):")
    for r in results {
        var line = "  \(r.contender.padding(toLength: 16, withPad: " ", startingAt: 0))"
            + " resolved \(r.resolved)/\(r.rows) (\(String(format: "%.2f", r.resolvedPercent))%)"
            + " · matches reference \(r.byteCorrect) (\(String(format: "%.2f", r.byteCorrectPercent))%)"
            + " · differs \(r.wrongOutput) · declined \(r.declined)"
        if r.conventionOnly > 0 {
            line += " (of those, \(r.conventionOnly) byte-match the tool's --no-sugar rendering — display convention, not misparse)"
        }
        print(line)
    }
    print("  per-era reference-matching/total:")
    let contenderWidth = 16
    var header = String(repeating: " ", count: 4 + contenderWidth)
    let eras = eraOrder.filter { era in results.contains { $0.eras[era] != nil } }
    for era in eras {
        header += era.padding(toLength: 14, withPad: " ", startingAt: 0)
    }
    print(header)
    for r in results {
        var line = "    " + r.contender.padding(toLength: contenderWidth, withPad: " ", startingAt: 0)
        for era in eras {
            let cell = r.eras[era].map { "\($0.correct)/\($0.total)" } ?? "—"
            line += cell.padding(toLength: 14, withPad: " ", startingAt: 0)
        }
        print(line)
    }
    if let declineRow {
        print("  expected-decline row (\(declineRow.mangled)) — excluded from the percentages above:")
        for r in results where !r.declineRowVerdict.isEmpty {
            print("    \(r.contender): \(r.declineRowVerdict)")
        }
    }
}

/// Coverage block for the JSON document (deterministic key order).
func renderCoverageJSON(_ results: [CoverageResult]) -> String {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    var blocks: [String] = []
    for r in results {
        var b = "    {\n"
        b += "      \"contender\": \"\(esc(r.contender))\",\n"
        b += "      \"configuration\": \"\(esc(r.configuration))\",\n"
        b += "      \"rows\": \(r.rows),\n"
        b += "      \"resolved\": \(r.resolved),\n"
        b += "      \"byteCorrect\": \(r.byteCorrect),\n"
        b += "      \"wrongOutput\": \(r.wrongOutput),\n"
        b += "      \"conventionOnly\": \(r.conventionOnly),\n"
        b += "      \"declined\": \(r.declined),\n"
        b += "      \"declineRowVerdict\": \"\(esc(r.declineRowVerdict))\",\n"
        let eraBlocks = eraOrder.compactMap { era -> String? in
            guard let entry = r.eras[era] else { return nil }
            return "        \"\(esc(era))\": { \"correct\": \(entry.correct), \"total\": \(entry.total) }"
        }
        b += "      \"eras\": {\n" + eraBlocks.joined(separator: ",\n") + "\n      }\n"
        b += "    }"
        blocks.append(b)
    }
    return "  \"coverage\": [\n" + blocks.joined(separator: ",\n") + "\n  ]"
}
