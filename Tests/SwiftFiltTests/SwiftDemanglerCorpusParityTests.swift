// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// Golden-corpus parity support: loads `corpus.tsv` (real Swift symbols + `swift-demangle`
/// `-compact`/`-simplified`/`-no-sugar` columns) and `trees.txt` (oracle node trees for a
/// diverse subset, so AST shape is checked exactly). The fixtures snapshot one toolchain,
/// regenerated when it moves; where the oracle declines a symbol it echoes the input, and
/// those rows are skipped here (`hostOracleDeclinedRowsStayResolvedSupersets` carries them).
enum SwiftDemanglerCorpusParity {
    /// Repo-root-relative fixture path, resolved from this source file so
    /// `swift test` finds it regardless of the working directory.
    static func fixturePath(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SwiftFiltTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tests/Fixtures/SwiftDemangling/\(name)")
            .path
    }

    struct Row: Sendable {
        let mangled: String
        let compact: String
        let simplified: String
        let noSugar: String
        let lineNumber: Int
    }

    /// `swift-demangle` echoes its input verbatim when it can't demangle — the oracle
    /// failed, not SwiftFilt, so parity tests skip the print comparison there and
    /// `hostOracleDeclinedRowsStayResolvedSupersets` carries the assertion. The echo
    /// also matches with the leading `_` stripped.
    static func oracleDeclined(_ oracleValue: String, for row: Row) -> Bool {
        let canonical = row.mangled.hasPrefix("_") ? String(row.mangled.dropFirst()) : row.mangled
        return oracleValue == row.mangled || oracleValue == canonical
    }

    static func loadRows() throws -> [Row] {
        let contents = try String(contentsOfFile: fixturePath("corpus.tsv"), encoding: .utf8)
        var rows: [Row] = []
        rows.reserveCapacity(5000)
        for (idx, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { continue }
            rows.append(Row(mangled: parts[0], compact: parts[1], simplified: parts[2], noSugar: parts[3], lineNumber: idx + 1))
        }
        return rows
    }

    /// The oracle `-tree-only` blocks keyed by their input symbol: header
    /// `Demangling for <input>` then the node lines, blank-separated.
    static func loadTreeBlocks() throws -> [String: String] {
        let contents = try String(contentsOfFile: fixturePath("trees.txt"), encoding: .utf8)
        var blocks: [String: String] = [:]
        var currentKey: String?
        var current: [Substring] = []
        func flush() {
            guard let key = currentKey else { return }
            while let last = current.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                current.removeLast()
            }
            blocks[key] = current.joined(separator: "\n")
            current.removeAll(keepingCapacity: true)
        }
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Demangling for ") {
                flush()
                currentKey = String(line.dropFirst("Demangling for ".count))
                continue
            }
            if currentKey != nil { current.append(line) }
        }
        flush()
        return blocks
    }
}

/// Joins up to `limit` failure descriptions for a readable `#expect` message.
private func summarize(_ failures: [String], limit: Int = 12) -> String {
    guard !failures.isEmpty else { return "" }
    let shown = failures.prefix(limit).joined(separator: "\n  ")
    let more = failures.count > limit ? "\n  …and \(failures.count - limit) more" : ""
    return "\(failures.count) failure(s):\n  \(shown)\(more)"
}

/// Parses and renders every corpus symbol against the `swift-demangle` oracle (compact/simplified/no-sugar) and re-mangles byte-exact.
@Suite("Swift demangler corpus parity (every row)")
struct SwiftDemanglerCorpusParityTests {
    @Test func corpusIsLarge() throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        #expect(rows.count > 4000, "corpus fixture shrank unexpectedly: \(rows.count) rows")
    }

    @Test func everyRowDemanglesToFullCompact() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let failures = await onLargeStack {
            let demangler = SwiftDemangler(); let printer = SwiftDemanglerPrinter()
            var fails: [String] = []
            for row in rows {
                guard let ast = demangler.demangle(symbol: row.mangled) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): demangle nil"); continue
                }
                if SwiftDemanglerCorpusParity.oracleDeclined(row.compact, for: row) { continue }
                let full = printer.print(ast, style: .full)
                if full != row.compact { fails.append("L\(row.lineNumber) \(row.mangled): full=`\(full)` expected=`\(row.compact)`") }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(summarize(failures))")
    }

    @Test func everyRowDemanglesToSimplified() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let failures = await onLargeStack {
            let demangler = SwiftDemangler(); let printer = SwiftDemanglerPrinter()
            var fails: [String] = []
            for row in rows {
                guard let ast = demangler.demangle(symbol: row.mangled) else { continue }
                if SwiftDemanglerCorpusParity.oracleDeclined(row.simplified, for: row) { continue }
                let simplified = printer.print(ast, style: .simplified)
                if simplified != row.simplified { fails.append("L\(row.lineNumber) \(row.mangled): simplified=`\(simplified)` expected=`\(row.simplified)`") }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(summarize(failures))")
    }

    @Test func everyRowDemanglesToQualifiedNoSugar() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let failures = await onLargeStack {
            let demangler = SwiftDemangler(); let printer = SwiftDemanglerPrinter()
            var fails: [String] = []
            for row in rows {
                guard let ast = demangler.demangle(symbol: row.mangled) else { continue }
                if SwiftDemanglerCorpusParity.oracleDeclined(row.noSugar, for: row) { continue }
                let qualified = printer.print(ast, style: .qualified)
                if qualified != row.noSugar { fails.append("L\(row.lineNumber) \(row.mangled): qualified=`\(qualified)` expected=`\(row.noSugar)`") }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(summarize(failures))")
    }

    /// Rows the host `swift-demangle` declines (echoes back). The printer tests skip
    /// those, so the assertion lives here: SwiftFilt must still demangle each, leave
    /// no residual mangling in any style, and re-mangle byte-exact — a resolved superset,
    /// not a silent guess. Pinning the set keeps an oracle regression or new decline visible.
    @Test func hostOracleDeclinedRowsStayResolvedSupersets() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let declined = rows.filter { SwiftDemanglerCorpusParity.oracleDeclined($0.compact, for: $0) }
        #expect(declined.map(\.mangled) == ["$s4main3fooyyF3fooSiTf0pk_n"],
                "host-oracle-declined set moved: \(declined.map(\.mangled))")

        let failures = await onLargeStack {
            let demangler = SwiftDemangler(); let printer = SwiftDemanglerPrinter(); let mangler = SwiftMangler()
            var fails: [String] = []
            for row in declined {
                guard let ast = demangler.demangle(symbol: row.mangled) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): SwiftFilt declined it too"); continue
                }
                for style in [SwiftDemanglerPrinter.Style.full, .simplified, .qualified] {
                    let rendered = printer.print(ast, style: style)
                    if rendered.contains("$s") || rendered.contains("$e") {
                        fails.append("L\(row.lineNumber) \(row.mangled): \(style) left a residual mangling `\(rendered)`")
                    }
                }
                // The self-consistency floor: byte-exact, or a lossless
                // re-encoding (here the remangler back-references the already-seen
                // `foo` as a substitution) that demangles to the identical tree.
                // Anything else is `superset_suspect_fabrication` — a silent guess.
                guard let remangled = mangler.mangle(ast) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): remangle returned nil"); continue
                }
                if remangled != row.mangled, demangler.demangle(symbol: remangled)?.treeDump() != ast.treeDump() {
                    fails.append("L\(row.lineNumber) \(row.mangled): remangled=`\(remangled)` not self-consistent (fabrication suspect)")
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(summarize(failures))")
    }

    @Test func everyRowRoundTripsByteExact() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let failures = await onLargeStack {
            let demangler = SwiftDemangler(); let mangler = SwiftMangler()
            var fails: [String] = []
            for row in rows {
                guard let ast = demangler.demangle(symbol: row.mangled) else { continue }
                guard let remangled = mangler.mangle(ast) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): mangle nil"); continue
                }
                if remangled == row.mangled { continue }
                // Lossless canonicalization (e.g. legacy `MD` normalized to `Md`):
                // the bytes differ but the remangling demangles to an identical tree.
                if demangler.demangle(symbol: remangled)?.treeDump() != ast.treeDump() {
                    fails.append("L\(row.lineNumber) \(row.mangled): remangled=`\(remangled)` not self-consistent")
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(summarize(failures))")
    }

    @Test func everyRowAlsoRendersUnqualifiedAndTreeDump() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let failures = await onLargeStack {
            let demangler = SwiftDemangler(); let printer = SwiftDemanglerPrinter()
            var fails: [String] = []
            for row in rows {
                guard let ast = demangler.demangle(symbol: row.mangled) else { continue }
                // .unqualified has no 1:1 oracle flag; exercising it on every row
                // covers the qualify-entities-off printer paths. A symbol that
                // demangles renders to a non-empty name in every style.
                if printer.print(ast, style: .unqualified).isEmpty { fails.append("L\(row.lineNumber) \(row.mangled): empty unqualified") }
                if ast.treeDump().isEmpty { fails.append("L\(row.lineNumber) \(row.mangled): empty treeDump") }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(summarize(failures))")
    }

    @Test func diverseSubsetMatchesOracleTreeNodeForNode() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let blocks = try SwiftDemanglerCorpusParity.loadTreeBlocks()
        let result = await onLargeStack { () -> (failures: [String], checked: Int) in
            let demangler = SwiftDemangler()
            var fails: [String] = []
            var checked = 0
            for row in rows {
                guard let expectedTree = blocks[row.mangled] else { continue }
                guard let ast = demangler.demangle(symbol: row.mangled) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): demangle nil"); continue
                }
                var trimmed = ast.treeDump()
                while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") {
                    trimmed.removeLast()
                }
                if trimmed != expectedTree { fails.append("L\(row.lineNumber) \(row.mangled): tree mismatch") }
                checked += 1
            }
            return (fails, checked)
        }
        #expect(result.failures.isEmpty, "\(summarize(result.failures))")
        #expect(result.checked > 300, "tree-subset coverage shrank: \(result.checked) symbols checked")
    }

    @Test func corpusSpansManyDistinctNodeKinds() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let kinds = await onLargeStack { () -> Set<String> in
            let demangler = SwiftDemangler()
            var seen: Set<String> = []
            for row in rows {
                guard let ast = demangler.demangle(symbol: row.mangled) else { continue }
                for line in ast.treeDump().split(separator: "\n") {
                    guard let range = line.range(of: "kind=") else { continue }
                    let kind = line[range.upperBound...].prefix { $0 != "," && $0 != "\n" }
                    seen.insert(String(kind))
                }
            }
            return seen
        }
        // The real-symbol corpus must exercise a broad swath of the 379-kind
        // universe — far more than any hand-written fixture set.
        #expect(kinds.count > 120, "corpus exercised only \(kinds.count) node kinds")
    }
}
