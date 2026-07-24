// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swiftfilt-parity corpus` — committed-fixture mode (the PR-speed
// default): every row of Tests/Fixtures/SwiftDemangling/*.tsv through the
// engine, diffed against the fixtures' frozen expected columns (the exact
// `swift-demangle` outputs captured when each fixture was generated), the
// trees.txt node dumps, and a per-row round-trip floor; plus every CLI
// golden fixture re-verified through the library filter and the in-process
// CLI.
//
// Fixture-echo rule: a frozen expected column equal to the input records
// that the SNAPSHOT oracle declined that row. The engine must still
// demangle it, leave no residual mangling, and stay self-consistent (a
// resolved superset, not a silent guess) — the same contract the unit
// suite pins.

import Foundation
import SwiftFilt
import SwiftFiltCLICore

public func runCorpusCommand(_ args: [String]) async -> Int32 {
    var inlineRows = 25
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--inline-rows":
            index += 1
            inlineRows = parseCount("--inline-rows", in: args, at: index, for: "corpus")
        default:
            eprint("corpus: unknown option \(args[index])")
            return 2
        }
        index += 1
    }

    let catalogue = DeviationCatalogue.load()
    var report = RunReport(instrument: "corpus", catalogue: catalogue)

    let outcome = await onLargeStack { () -> CorpusOutcome in
        var out = CorpusOutcome()
        diffCorpusFixture(into: &out)
        diffAppleFixture(into: &out)
        diffLegacyFixture(into: &out)
        diffTreeBlocks(into: &out)
        verifyCLIGoldens(into: &out)
        return out
    }
    for (leg, count) in outcome.comparisons {
        report.countComparison(leg: leg, by: count)
    }
    for divergence in outcome.divergences {
        report.record(divergence)
    }
    for error in outcome.harnessErrors {
        report.recordHarnessError(error)
    }
    for note in outcome.notes {
        report.note(note)
    }

    if let tsv = report.writeGatingRows(toDirectory: repositoryRoot().appendingPathComponent(".build/parity-reports").path) {
        report.note("gating rows TSV: \(tsv)")
    }
    print(report.render(inlineRowLimit: inlineRows))
    return report.exitCode
}

struct CorpusOutcome: Sendable {
    var comparisons: [String: Int] = [:]
    var divergences: [Divergence] = []
    var harnessErrors: [String] = []
    var notes: [String] = []

    mutating func compare(_ leg: String, mangled: String, klass: String, got: String, expected: String) {
        comparisons[leg, default: 0] += 1
        if got != expected {
            divergences.append(Divergence(leg: leg, klass: klass, mangled: mangled, swiftfilt: got, oracle: expected))
        }
    }
}

/// corpus.tsv: all three oracle-backed styles per row, the fixture-echo
/// superset contract on snapshot-declined rows, the unqualified exercise,
/// and the round-trip floor.
func diffCorpusFixture(into out: inout CorpusOutcome) {
    let path = demanglingFixturePath("corpus.tsv")
    guard let (rows, malformed) = try? loadCorpusFixture(path: path) else {
        out.harnessErrors.append("could not read \(path)")
        return
    }
    for line in malformed {
        out.divergences.append(Divergence(
            leg: "corpus", klass: "malformed-fixture-row", mangled: "corpus.tsv:L\(line)",
            swiftfilt: "<row does not have 4 tab-separated columns>", oracle: "mangled\\tcompact\\tsimplified\\tno-sugar",
        ))
    }
    out.notes.append("corpus.tsv: \(grouped(rows.count)) rows")
    let printer = SwiftDemanglerPrinter()
    let demangler = SwiftDemangler()
    let mangler = SwiftMangler()
    for row in rows {
        guard let symbol = DemangledSymbol(row.mangled) else {
            out.comparisons["corpus-full", default: 0] += 1
            out.divergences.append(Divergence(
                leg: "corpus", klass: "swiftfilt-declined", mangled: row.mangled,
                swiftfilt: "<nil>", oracle: row.compact,
            ))
            continue
        }
        let ast = symbol.symbol
        if oracleDeclined(row.compact, mangled: row.mangled) {
            // Snapshot-oracle-declined row: the engine demangled it; hold
            // the resolved-superset contract instead of the byte diff.
            out.comparisons["corpus-snapshot-declined", default: 0] += 1
            for style in [SwiftDemanglerPrinter.Style.full, .simplified, .qualified] {
                let rendered = printer.print(ast, style: style)
                if rendered.contains("$s") || rendered.contains("$e") {
                    out.divergences.append(Divergence(
                        leg: "corpus", klass: "superset-residual-mangling", mangled: row.mangled,
                        swiftfilt: rendered, oracle: "<snapshot oracle declined; no residual mangling allowed>",
                    ))
                }
            }
        } else {
            out.compare("corpus-full", mangled: row.mangled, klass: "render-mismatch",
                        got: printer.print(ast, style: .full), expected: row.compact)
            if !oracleDeclined(row.simplified, mangled: row.mangled) {
                out.compare("corpus-simplified", mangled: row.mangled, klass: "render-mismatch",
                            got: printer.print(ast, style: .simplified), expected: row.simplified)
            }
            if !oracleDeclined(row.noSugar, mangled: row.mangled) {
                out.compare("corpus-qualified", mangled: row.mangled, klass: "render-mismatch",
                            got: printer.print(ast, style: .qualified), expected: row.noSugar)
            }
        }
        // Exercised, not oracled: unqualified must render non-empty.
        out.comparisons["corpus-unqualified", default: 0] += 1
        if printer.print(ast, style: .unqualified).isEmpty {
            out.divergences.append(Divergence(
                leg: "corpus", klass: "unqualified-render-empty", mangled: row.mangled,
                swiftfilt: "<empty>", oracle: "<non-empty rendering required>",
            ))
        }
        // Round-trip floor: byte-exact, or a lossless re-encoding that
        // demangles to the identical tree.
        out.comparisons["corpus-roundtrip", default: 0] += 1
        if let remangled = mangler.mangle(ast) {
            if remangled != row.mangled,
               demangler.demangle(symbol: remangled)?.treeDump() != ast.treeDump()
            {
                out.divergences.append(Divergence(
                    leg: "corpus", klass: "roundtrip-not-self-consistent", mangled: row.mangled,
                    swiftfilt: remangled, oracle: "demangle(mangle(ast)) != ast",
                ))
            }
        } else {
            out.divergences.append(Divergence(
                leg: "corpus", klass: "remangle-nil", mangled: row.mangled,
                swiftfilt: "<remangle returned nil>", oracle: "a corpus.tsv tree must remangle",
            ))
        }
    }
}

/// apple.tsv: apple/swift's own demangler corpus — `.full` must equal the
/// expected demangling on every row (no echo rule: every expected cell in
/// this fixture is a real demangling).
func diffAppleFixture(into out: inout CorpusOutcome) {
    let path = demanglingFixturePath("apple.tsv")
    guard let (rows, malformed) = try? loadPairFixture(path: path) else {
        out.harnessErrors.append("could not read \(path)")
        return
    }
    for line in malformed {
        out.divergences.append(Divergence(
            leg: "corpus", klass: "malformed-fixture-row", mangled: "apple.tsv:L\(line)",
            swiftfilt: "<row does not have 2 tab-separated columns>", oracle: "mangled\\texpected",
        ))
    }
    out.notes.append("apple.tsv: \(grouped(rows.count)) rows")
    let printer = SwiftDemanglerPrinter()
    for row in rows {
        guard let symbol = DemangledSymbol(row.mangled) else {
            out.comparisons["corpus-apple", default: 0] += 1
            out.divergences.append(Divergence(
                leg: "corpus", klass: "swiftfilt-declined", mangled: row.mangled,
                swiftfilt: "<nil>", oracle: row.expected,
            ))
            continue
        }
        out.compare("corpus-apple", mangled: row.mangled, klass: "render-mismatch",
                    got: printer.print(symbol.symbol, style: .full), expected: row.expected)
    }
}

/// legacy.tsv: the Swift ≤4 `_T` grammar — `.full` and `.simplified` per
/// row. (Round-trip is deliberately not asserted here: legacy names
/// re-mangle to the modern `$s` form by design; the roundtrip subcommand
/// owns that contract corpus-wide.)
func diffLegacyFixture(into out: inout CorpusOutcome) {
    let path = demanglingFixturePath("legacy.tsv")
    guard let (rows, malformed) = try? loadLegacyFixture(path: path) else {
        out.harnessErrors.append("could not read \(path)")
        return
    }
    for line in malformed {
        out.divergences.append(Divergence(
            leg: "corpus", klass: "malformed-fixture-row", mangled: "legacy.tsv:L\(line)",
            swiftfilt: "<row does not have 3 tab-separated columns>", oracle: "mangled\\tcompact\\tsimplified",
        ))
    }
    out.notes.append("legacy.tsv: \(grouped(rows.count)) rows")
    let printer = SwiftDemanglerPrinter()
    for row in rows {
        guard let symbol = DemangledSymbol(row.mangled) else {
            out.comparisons["corpus-legacy", default: 0] += 1
            out.divergences.append(Divergence(
                leg: "corpus", klass: "swiftfilt-declined", mangled: row.mangled,
                swiftfilt: "<nil>", oracle: row.compact,
            ))
            continue
        }
        out.compare("corpus-legacy", mangled: row.mangled, klass: "render-mismatch",
                    got: printer.print(symbol.symbol, style: .full), expected: row.compact)
        out.compare("corpus-legacy-simplified", mangled: row.mangled, klass: "render-mismatch",
                    got: printer.print(symbol.symbol, style: .simplified), expected: row.simplified)
    }
}

/// trees.txt: the frozen `-tree-only` node dumps for the diverse subset —
/// AST shape checked node-for-node, not only through printed renderings.
func diffTreeBlocks(into out: inout CorpusOutcome) {
    let path = demanglingFixturePath("trees.txt")
    guard let blocks = try? loadTreeBlocks(path: path) else {
        out.harnessErrors.append("could not read \(path)")
        return
    }
    out.notes.append("trees.txt: \(grouped(blocks.count)) frozen tree blocks")
    for (mangled, expectedTree) in blocks.sorted(by: { $0.key < $1.key }) {
        out.comparisons["corpus-tree", default: 0] += 1
        guard let symbol = DemangledSymbol(mangled) else {
            out.divergences.append(Divergence(
                leg: "corpus", klass: "swiftfilt-declined", mangled: mangled,
                swiftfilt: "<nil>", oracle: expectedTree.split(separator: "\n").first.map(String.init) ?? "<tree>",
            ))
            continue
        }
        let engineTree = symbol.symbol.treeDump().trimmedTrailingNewlines()
        if engineTree != expectedTree {
            out.divergences.append(Divergence(
                leg: "corpus", klass: "tree-mismatch", mangled: mangled,
                swiftfilt: firstDifferingLine(engineTree, expectedTree, wantFirst: true),
                oracle: firstDifferingLine(engineTree, expectedTree, wantFirst: false),
            ))
        }
    }
}

/// The CLI golden fixtures, re-verified two ways: every input×flags pair
/// byte-diffed against its locked golden through the in-process CLI, and
/// the plain rewrites additionally held byte-equal to the library filter
/// (`MangledNameScanner.demangleAll`) — the CLI adds wiring, never its own
/// demangling opinion. The census goldens ride the same re-verification:
/// every census fixture×flags pair (the real LinkMap, both nm shapes, the
/// crash log as bare text; human report and NDJSON, full and slim) must
/// re-earn its locked bytes on every run.
func verifyCLIGoldens(into out: inout CorpusOutcome) {
    let goldenRuns: [(input: String, flags: [String], golden: String)] = [
        ("input/crash-log.txt", [], "crash-log.full.txt"),
        ("input/crash-log.txt", ["--simplified"], "crash-log.simplified.txt"),
        ("input/crash-log.txt", ["--classify"], "crash-log.classify.txt"),
        ("input/crash-log.txt", ["--tree"], "crash-log.tree.txt"),
        ("input/crash-log.txt", ["--json"], "crash-log.ndjson"),
        ("input/crash-log.txt", ["--json", "--slim"], "crash-log.slim.ndjson"),
        ("input/nm-output.txt", [], "nm-output.full.txt"),
        ("input/linker-error.txt", [], "linker-error.full.txt"),
        ("input/ansi-build-log.txt", [], "ansi-build-log.full.txt"),
        ("input/mixed-junk.bin", [], "mixed-junk.full.bin"),
        ("input/crash-log.txt", ["census", "--color", "never"], "census-bare.txt"),
        ("input/crash-log.txt", ["census", "--json"], "census-bare.ndjson"),
    ]
    let censusGoldenRuns: [(input: String, flags: [String], golden: String)] = [
        ("LinkMap.txt", ["census", "--color", "never"], "census-linkmap.txt"),
        ("LinkMap.txt", ["census", "--color", "never", "--top", "3"], "census-linkmap.top3.txt"),
        ("LinkMap.txt", ["census", "--json"], "census-linkmap.ndjson"),
        ("LinkMap.txt", ["census", "--json", "--slim"], "census-linkmap.slim.ndjson"),
        ("nm.txt", ["census", "--color", "never"], "census-nm.txt"),
        ("nm.txt", ["census", "--json", "--slim"], "census-nm.slim.ndjson"),
        ("nm-sized.txt", ["census", "--color", "never"], "census-nm-sized.txt"),
        ("nm-sized.txt", ["census", "--json"], "census-nm-sized.ndjson"),
    ]
    let allRuns: [(inputPath: String, flags: [String], golden: String)] =
        goldenRuns.map { (cliFixturePath($0.input), $0.flags, $0.golden) }
            + censusGoldenRuns.map { (censusFixturePath($0.input), $0.flags, $0.golden) }
    for run in allRuns {
        let goldenPath = cliFixturePath("golden/\(run.golden)")
        guard let input = FileManager.default.contents(atPath: run.inputPath),
              let golden = FileManager.default.contents(atPath: goldenPath)
        else {
            out.harnessErrors.append("missing CLI fixture \(run.inputPath) or golden \(run.golden)")
            continue
        }
        out.comparisons["cli-golden", default: 0] += 1
        let produced = runInProcessCLI(run.flags, stdin: [UInt8](input))
        if produced != [UInt8](golden) {
            out.divergences.append(Divergence(
                leg: "cli-golden", klass: "golden-mismatch",
                mangled: "\(run.inputPath) \(run.flags.joined(separator: " "))",
                swiftfilt: "<\(produced.count) bytes>", oracle: "<golden \(golden.count) bytes> \(run.golden)",
            ))
        }
    }
    // The library-filter equivalence: the CLI's plain rewrite is the
    // library rewrite, for every text fixture and every style.
    let styleFlags: [([String], DemangleStyle)] = [
        ([], .full), (["--simplified"], .simplified),
        (["--qualified"], .qualified), (["--unqualified"], .unqualified),
    ]
    for fixture in ["crash-log.txt", "nm-output.txt", "linker-error.txt", "ansi-build-log.txt", "mixed-junk.bin", "pure-junk.bin"] {
        guard let input = FileManager.default.contents(atPath: cliFixturePath("input/\(fixture)")) else {
            out.harnessErrors.append("missing CLI fixture \(fixture)")
            continue
        }
        let bytes = [UInt8](input)
        for (flags, style) in styleFlags {
            out.comparisons["cli-library-filter", default: 0] += 1
            let viaCLI = runInProcessCLI(flags, stdin: bytes)
            let viaLibrary = MangledNameScanner().demangleAll(inBytes: bytes, style: style)
            if viaCLI != viaLibrary {
                out.divergences.append(Divergence(
                    leg: "cli-golden", klass: "cli-library-filter-mismatch",
                    mangled: "\(fixture) \(flags.joined(separator: " "))",
                    swiftfilt: "<CLI \(viaCLI.count) bytes>", oracle: "<library \(viaLibrary.count) bytes>",
                ))
            }
        }
    }
}

/// Run the CLI in-process with injected stdio (never a subprocess: this
/// verifies the wiring the tests and the shipped binary share).
func runInProcessCLI(_ arguments: [String], stdin: [UInt8]) -> [UInt8] {
    var handedOut = false
    var out: [UInt8] = []
    _ = CLI.run(
        arguments: arguments,
        input: {
            guard !handedOut, !stdin.isEmpty else { return nil }
            handedOut = true
            return stdin
        },
        writeOutput: { out.append(contentsOf: $0) },
        writeError: { _ in },
        standardOutputIsTTY: false,
    )
    return out
}
