// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The known-deviations contract: KNOWN-DEVIATIONS.md at the repository
// root is both human documentation and the machine-readable table every
// parity subcommand consults. A divergence matching an entry is reported
// under the entry's id and does not gate; anything a run reports that is
// NOT matched by the table exits non-zero. The contract is zero
// unexplained rows.

import Foundation

/// One divergence a parity run found: which instrument leg produced it,
/// its machine classification, the symbol, and both sides' text.
public struct Divergence: Sendable {
    /// The instrument leg: `full` / `simplified` / `qualified` / `tree` /
    /// `classify` / `decline` / `unqualified` / `roundtrip` / `corpus` /
    /// `cli-golden`.
    public let leg: String
    /// The machine classification within the leg (e.g. `render-mismatch`,
    /// `swiftfilt-superset`, `remangle-nil`).
    public let klass: String
    /// The mangled symbol (or fixture identifier for file-level rows).
    public let mangled: String
    /// swiftfilt's side of the disagreement.
    public let swiftfilt: String
    /// The oracle's (or frozen fixture's) side.
    public let oracle: String

    public init(leg: String, klass: String, mangled: String, swiftfilt: String, oracle: String) {
        self.leg = leg
        self.klass = klass
        self.mangled = mangled
        self.swiftfilt = swiftfilt
        self.oracle = oracle
    }
}

/// A deviation's lifecycle status.
public enum DeviationStatus: String, Sendable {
    /// By design, permanent until the scope changes.
    case expected
    /// A recorded bug that must be removed by the fixing change — reported
    /// loudly on every run so it cannot fade into the background.
    case openDefect = "open-defect"
}

/// One entry of the KNOWN-DEVIATIONS table: an id, a status, and the
/// matcher — a `;`-separated `key=value` clause list, ALL of which must
/// hold for a divergence to classify under the entry.
public struct DeviationEntry: Sendable {
    public let id: String
    public let status: DeviationStatus
    public let constraints: [(key: String, value: String)]

    public init(id: String, status: DeviationStatus, constraints: [(key: String, value: String)]) {
        self.id = id
        self.status = status
        self.constraints = constraints
    }

    /// Match one divergence. Clause keys:
    /// `leg=<name>` — the instrument leg (an entry never crosses legs
    /// implicitly; omit to match the same class on any leg) ·
    /// `class=<name>` — the divergence's machine classification ·
    /// `mangled.prefix=<p>` · `mangled.suffix=<s>` ·
    /// `mangled.regex=<r>` (must match the ENTIRE mangled name) ·
    /// `oracle.contains=<t>` · `swiftfilt.contains=<t>`.
    /// All clauses AND together; an entry with no clauses matches nothing.
    public func matches(_ divergence: Divergence) -> Bool {
        for constraint in constraints {
            switch constraint.key {
            case "leg":
                if divergence.leg != constraint.value { return false }
            case "class":
                if divergence.klass != constraint.value { return false }
            case "mangled.prefix":
                if !divergence.mangled.hasPrefix(constraint.value) { return false }
            case "mangled.suffix":
                if !divergence.mangled.hasSuffix(constraint.value) { return false }
            case "mangled.regex":
                guard let regex = try? NSRegularExpression(pattern: constraint.value) else { return false }
                let range = NSRange(divergence.mangled.startIndex..., in: divergence.mangled)
                guard let match = regex.firstMatch(in: divergence.mangled, range: range),
                      match.range == range
                else { return false }
            case "oracle.contains":
                if !divergence.oracle.contains(constraint.value) { return false }
            case "swiftfilt.contains":
                if !divergence.swiftfilt.contains(constraint.value) { return false }
            default:
                // An unknown clause never matches: a typo in the table must
                // surface as gating rows, not silently classify them.
                return false
            }
        }
        return !constraints.isEmpty
    }
}

/// The parsed KNOWN-DEVIATIONS.md table.
public struct DeviationCatalogue: Sendable {
    public let entries: [DeviationEntry]
    public let path: String

    public init(entries: [DeviationEntry], path: String) {
        self.entries = entries
        self.path = path
    }

    /// Load and parse `KNOWN-DEVIATIONS.md`. Table rows are
    /// `| `id` | status | `matcher` | evidence |`; the matcher cell is a
    /// backtick-quoted `;`-separated `key=value` list. A missing file
    /// yields an empty catalogue — every divergence gates.
    public static func load(from path: String = repositoryRoot().appendingPathComponent("KNOWN-DEVIATIONS.md").path) -> DeviationCatalogue {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return DeviationCatalogue(entries: [], path: path)
        }
        return DeviationCatalogue(entries: parse(markdown: contents), path: path)
    }

    /// Parse the entry table out of the document text (exposed separately
    /// so the table grammar is unit-testable without touching disk).
    public static func parse(markdown contents: String) -> [DeviationEntry] {
        var entries: [DeviationEntry] = []
        for raw in contents.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3 else { continue }
            let id = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard let status = DeviationStatus(rawValue: cells[1]) else { continue }
            let matcherCell = cells[2].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            var constraints: [(String, String)] = []
            for clause in matcherCell.split(separator: ";") {
                let pair = clause.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { continue }
                constraints.append((pair[0], pair[1]))
            }
            if !constraints.isEmpty {
                entries.append(DeviationEntry(id: id, status: status, constraints: constraints))
            }
        }
        return entries
    }

    /// The first matching entry for a divergence, or `nil` (gating).
    public func classify(_ divergence: Divergence) -> DeviationEntry? {
        entries.first { $0.matches(divergence) }
    }
}

// MARK: - Run report

/// Accumulates one run's outcome — comparison tallies, catalogued
/// deviations, and gating divergences — and renders the summary block.
/// Deterministic: rows are emitted in the order they were recorded (the
/// caller feeds them in corpus order), classes and ids sort lexically.
public struct RunReport {
    public let instrument: String
    private let catalogue: DeviationCatalogue
    private let started = Date()

    /// Comparison volume per leg (rows actually compared, not just seen).
    public private(set) var comparisons: [String: Int] = [:]
    /// Catalogued (non-gating) divergence counts by entry id.
    public private(set) var catalogued: [String: Int] = [:]
    /// One exemplar per catalogue id (first hit), for the summary.
    public private(set) var cataloguedExemplars: [String: Divergence] = [:]
    /// Gating (uncatalogued) divergences, in record order.
    public private(set) var gating: [Divergence] = []
    /// Gating counts by `leg/class` (exact even past the stored-row cap).
    public private(set) var gatingCounts: [String: Int] = [:]
    /// Setup/harness failures (oracle timeouts, unlaunchable tools). These
    /// abort scoring — a run with harness errors cannot report clean.
    public private(set) var harnessErrors: [String] = []
    /// Free-form informational lines carried into the summary.
    public private(set) var notes: [String] = []
    /// When set, gating divergences are reported in full but do NOT fail the
    /// run, and the string says why. Set only when the live oracle is older
    /// than `Oracle.referenceVersion`, where rendering-string and node-kind
    /// differences are toolchain skew rather than engine defects. Harness
    /// errors are unaffected — a broken oracle still fails. Purely a
    /// softening of the exit code: nothing is hidden or reclassified.
    public var advisoryReason: String?

    /// Stored-row cap for gating rows (counts stay exact past it): keeps a
    /// pathological everything-diverges run from holding millions of rows.
    public let storedRowCap: Int

    public init(instrument: String, catalogue: DeviationCatalogue, storedRowCap: Int = 100_000) {
        self.instrument = instrument
        self.catalogue = catalogue
        self.storedRowCap = storedRowCap
    }

    public mutating func countComparison(leg: String, by amount: Int = 1) {
        comparisons[leg, default: 0] += amount
    }

    /// Record one divergence: classified under a catalogue entry when one
    /// matches (non-gating), gating otherwise.
    public mutating func record(_ divergence: Divergence) {
        if let entry = catalogue.classify(divergence) {
            catalogued[entry.id, default: 0] += 1
            if cataloguedExemplars[entry.id] == nil {
                cataloguedExemplars[entry.id] = divergence
            }
            return
        }
        gatingCounts["\(divergence.leg)/\(divergence.klass)", default: 0] += 1
        if gating.count < storedRowCap {
            gating.append(divergence)
        }
    }

    public mutating func recordHarnessError(_ message: String) {
        harnessErrors.append(message)
    }

    public mutating func note(_ message: String) {
        notes.append(message)
    }

    /// Total gating divergences (exact, independent of the stored cap).
    public var gatingTotal: Int {
        gatingCounts.values.reduce(0, +)
    }

    /// The run's exit code: 0 only when there are no gating divergences
    /// AND no harness errors. An advisory run (oracle below the reference
    /// version) still reports every divergence but exits 0 for them;
    /// harness errors gate regardless, since a broken oracle is a setup
    /// failure no toolchain skew explains.
    public var exitCode: Int32 {
        if !harnessErrors.isEmpty { return 2 }
        if advisoryReason != nil { return 0 }
        return gatingTotal == 0 ? 0 : 1
    }

    /// Write every gating row (up to the stored cap) as TSV:
    /// `leg  class  mangled  swiftfilt  oracle` with newlines/tabs escaped.
    /// Returns the path, or nil when there was nothing to write.
    public func writeGatingRows(toDirectory directory: String) -> String? {
        guard !gating.isEmpty else { return nil }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/\(instrument)-gating.tsv"
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        var out = "# leg\tclass\tmangled\tswiftfilt\toracle\n"
        for row in gating {
            out += "\(escape(row.leg))\t\(escape(row.klass))\t\(escape(row.mangled))\t\(escape(row.swiftfilt))\t\(escape(row.oracle))\n"
        }
        guard (try? out.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        return path
    }

    /// Render the summary block and per-row detail. `inlineRowLimit` caps
    /// the gating rows echoed to the console per class; the full set goes
    /// to the TSV via `writeGatingRows` (counts are always exact).
    public func render(inlineRowLimit: Int = 25, oracleIdentity: String? = nil) -> String {
        var lines: [String] = []
        lines.append("== swiftfilt-parity \(instrument) summary ==")
        if let oracleIdentity {
            lines.append("oracle: \(oracleIdentity)")
        }
        lines.append("deviations table: \(catalogue.path) (\(catalogue.entries.count) entr\(catalogue.entries.count == 1 ? "y" : "ies"))")
        for note in notes {
            lines.append(note)
        }
        let legOrder = comparisons.keys.sorted()
        if !legOrder.isEmpty {
            lines.append("rows compared: " + legOrder.map { "\($0)=\(grouped(comparisons[$0] ?? 0))" }.joined(separator: " "))
        }
        if catalogued.isEmpty {
            lines.append("deviations matched: none")
        } else {
            lines.append("deviations matched:")
            for id in catalogued.keys.sorted() {
                let entry = catalogue.entries.first { $0.id == id }
                let status = entry?.status.rawValue ?? "?"
                let loud = entry?.status == .openDefect ? "  ** OPEN DEFECT — must be fixed, not accepted **" : ""
                lines.append("  \(id) [\(status)]: \(grouped(catalogued[id] ?? 0)) row(s)\(loud)")
                if let exemplar = cataloguedExemplars[id] {
                    lines.append("    e.g. \(exemplar.mangled): swiftfilt=`\(clip(exemplar.swiftfilt))` oracle=`\(clip(exemplar.oracle))`")
                }
            }
        }
        // A catalogue entry that matched nothing on a leg THIS run compared
        // is stale — surfaced so the table cannot quietly outlive the
        // behavior it documents. Entries pinned to another instrument's leg
        // are not this run's to judge.
        let unmatched = catalogue.entries.filter { entry in
            guard catalogued[entry.id] == nil else { return false }
            let legClauses = entry.constraints.filter { $0.key == "leg" }
            guard !legClauses.isEmpty else { return !comparisons.isEmpty }
            return legClauses.allSatisfy { comparisons[$0.value] != nil }
        }.map(\.id)
        if !unmatched.isEmpty {
            lines.append("deviations with zero matches on this run's legs (stale?): \(unmatched.sorted().joined(separator: ", "))")
        }
        if gatingTotal == 0 {
            lines.append("UNEXPLAINED DIVERGENCES: 0")
        } else {
            if let advisoryReason {
                lines.append("UNEXPLAINED DIVERGENCES: \(grouped(gatingTotal)) — ADVISORY (not gating)")
                lines.append("  reason: \(advisoryReason)")
            } else {
                lines.append("UNEXPLAINED DIVERGENCES: \(grouped(gatingTotal)) — GATING")
            }
            for key in gatingCounts.keys.sorted() {
                lines.append("  \(key): \(grouped(gatingCounts[key] ?? 0))")
            }
            var shownPerClass: [String: Int] = [:]
            for row in gating {
                let key = "\(row.leg)/\(row.klass)"
                let shown = shownPerClass[key, default: 0]
                guard shown < inlineRowLimit else { continue }
                shownPerClass[key] = shown + 1
                lines.append("  DIV [\(key)] \(row.mangled): swiftfilt=`\(clip(row.swiftfilt))` oracle=`\(clip(row.oracle))`")
            }
            let hidden = gatingTotal - shownPerClass.values.reduce(0, +)
            if hidden > 0 {
                lines.append("  … and \(grouped(hidden)) more (full rows in the gating TSV)")
            }
        }
        for error in harnessErrors {
            lines.append("HARNESS ERROR: \(error)")
        }
        lines.append("runtime: \(secondsText(Date().timeIntervalSince(started)))")
        lines.append("exit: \(exitCode)")
        return lines.joined(separator: "\n")
    }

    private func clip(_ s: String, to limit: Int = 220) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "\\n")
        guard flat.count > limit else { return flat }
        return flat.prefix(limit) + "…[\(flat.count) chars]"
    }
}
