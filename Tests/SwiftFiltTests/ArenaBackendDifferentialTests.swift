// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// The C2 backend split, pinned at fixture scale. C2 routes the string→string
/// path (`demangle(_:style:)`, symbol output, `MangledNameScanner.demangleAll`)
/// onto the bump-arena ``ArenaBuilder`` backend while the structured path keeps
/// the value backend; both run the same generic demangler/printer bodies over two
/// node representations, so they must render byte-for-byte identically in every
/// style, compared through the public surface. The full 13M-row differential is
/// swept by `swiftfilt-parity differential`; this pin keeps a backend regression
/// visible in the fast `swift test` gate.
@Suite("Arena backend differential (arena == SwiftSymbol)")
struct ArenaBackendDifferentialTests {
    /// Every mangled name in the three committed demangling corpora
    /// (`corpus.tsv` + `apple.tsv` + `legacy.tsv`, first column) — the same
    /// real-world symbol population the corpus-parity suite runs on.
    static func fixtureSymbols() -> [String] {
        var symbols: [String] = []
        for file in ["corpus.tsv", "apple.tsv", "legacy.tsv"] {
            guard let contents = try? String(contentsOfFile: SwiftDemanglerCorpusParity.fixturePath(file), encoding: .utf8) else { continue }
            for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                if raw.isEmpty || raw.hasPrefix("#") { continue }
                guard let tab = raw.firstIndex(of: "\t") else { continue }
                symbols.append(String(raw[raw.startIndex ..< tab]))
            }
        }
        return symbols
    }

    /// `SwiftSymbol` value-backend render of `name` in `style` — the same `__T…`
    /// Mach-O adapter and nil-on-empty contract as the product path, over the value tree.
    static func reference(_ name: String, _ style: SwiftDemanglerPrinter.Style) -> String? {
        let adapted = name.hasPrefix("__T") ? String(name.dropFirst()) : name
        guard let tree = SwiftDemangler().demangle(symbol: adapted) else { return nil }
        let rendered = SwiftDemanglerPrinter().print(tree, style: style)
        return rendered.isEmpty ? nil : rendered
    }

    /// The product-tier arena render (`demangle(_:style:)`) paired with the
    /// node-tier reference style it must equal.
    static let stylePairs: [(DemangleStyle, SwiftDemanglerPrinter.Style)] = [
        (.full, .full), (.simplified, .simplified), (.qualified, .qualified), (.unqualified, .unqualified),
    ]

    private static func summarize(_ failures: [String], limit: Int = 15) -> String {
        guard !failures.isEmpty else { return "" }
        let shown = failures.prefix(limit).joined(separator: "\n  ")
        let more = failures.count > limit ? "\n  …and \(failures.count - limit) more" : ""
        return "\(failures.count) arena/SwiftSymbol divergence(s):\n  \(shown)\(more)"
    }

    /// The core differential: over the whole fixture corpus, in all four styles,
    /// the arena `demangle(_:style:)` equals the `SwiftSymbol` reference render
    /// exactly (both non-`nil` and equal, or both `nil`).
    @Test func everyFixtureSymbolRendersIdenticallyOnBothBackends() async {
        let symbols = Self.fixtureSymbols()
        #expect(symbols.count > 4000, "fixture corpus shrank unexpectedly: \(symbols.count)")
        let failures = await onLargeStack { () -> [String] in
            var fails: [String] = []
            for name in symbols {
                for (arenaStyle, referenceStyle) in Self.stylePairs {
                    let arena = demangle(name, style: arenaStyle)
                    let reference = Self.reference(name, referenceStyle)
                    if arena != reference {
                        fails.append("\(name) [\(arenaStyle)]: arena=`\(arena ?? "<nil>")` swiftSymbol=`\(reference ?? "<nil>")`")
                    }
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(Self.summarize(failures))")
    }

    /// Deep-nesting, punycode, and exotic witnesses in every style, so the arena's
    /// recursive `materialize`/`adopt` seams and punycode path are covered explicitly,
    /// not just incidentally by the corpus sweep.
    @Test func craftedDeepPunycodeAndEveryStyleCohortMatches() async {
        let cohort = [
            // Deep nested generics (the printer/demangler recurse per level).
            "$s4main1SVyAA1TVyAA1UVyAA1VVyAA1WVGGGGSgSayAEGSDySSAEGtsSHRzlF",
            // Punycode identifiers (Unicode class / method names).
            "$s10Foundation3URLV䏿yyF",
            "$s3aaa3fooyyF",
            "$ss5UInt8V4main1é",
            // Old `_T` mangling (routes through OldDemangler + arena adopt).
            "_TtC4main5Thing",
            "_TFC4main5Thing3fooFT_T_",
            // Opaque return type (routes through materialize/adopt rewrite).
            "$s4main3fooQryF",
            "$s4main3fooQryFQOyQo_",
            // Function signature specialization (constant-prop payload printer).
            "$s4main3fooyyFTf0pk_n",
            // Standard-substitution-heavy signatures.
            "$sSiSSSdSbtSayxGs5ErrorRzlF",
        ]
        let failures = await onLargeStack { () -> [String] in
            var fails: [String] = []
            for name in cohort {
                for (arenaStyle, referenceStyle) in Self.stylePairs {
                    let arena = demangle(name, style: arenaStyle)
                    let reference = Self.reference(name, referenceStyle)
                    if arena != reference {
                        fails.append("\(name) [\(arenaStyle)]: arena=`\(arena ?? "<nil>")` swiftSymbol=`\(reference ?? "<nil>")`")
                    }
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(Self.summarize(failures))")
    }

    /// `demangleAll(inBytes:style:)` (arena rewrite) produces the same bytes as
    /// splicing each `matches(inBytes:)` match's `SwiftSymbol` render, over an
    /// embedded-symbol log in every style — the backend swap perturbs neither which
    /// spans match nor how they render.
    @Test func scannerRewritePathMatchesStructuredMatchesSplice() {
        let symbols = Self.fixtureSymbols()
        // A synthetic log: alternating prose, crash-frame, and nm-style lines
        // carrying fixture symbols; plus junk that must never match.
        var log = "".utf8.map(\.self)
        for (i, symbol) in symbols.prefix(3000).enumerated() {
            log.append(contentsOf: "\(i)  MyApp  0x1000\(i)  \(symbol) + \(i)\n".utf8)
            if i % 3 == 0 { log.append(contentsOf: "no symbols on this prose line at all\n".utf8) }
            if i % 5 == 0 { log.append(contentsOf: "0x00 T \(symbol)\n".utf8) }
            log.append(contentsOf: "raw 0xDEADBEEF _Z3fooi not_a_symbol \(i)\n".utf8)
        }
        let scanner = MangledNameScanner()
        for style in DemangleStyle.allCases {
            let arena = scanner.demangleAll(inBytes: log, style: style)
            var reference: [UInt8] = []
            var cursor = 0
            for match in scanner.matches(inBytes: log) {
                let replacement = match.demangled(style)
                guard !replacement.isEmpty else { continue }
                reference.append(contentsOf: log[cursor ..< match.byteRange.lowerBound])
                reference.append(contentsOf: replacement.utf8)
                cursor = match.byteRange.upperBound
            }
            let expected: [UInt8]
            if cursor > 0 {
                reference.append(contentsOf: log[cursor...])
                expected = reference
            } else {
                expected = log
            }
            #expect(arena == expected, "demangleAll[\(style)] arena rewrite diverged from SwiftSymbol matches splice (\(arena.count) vs \(expected.count) bytes)")
        }
    }

    /// The structured contract survives the split: `matches()` still exposes a
    /// real `SwiftSymbol` tree (the public `Match.symbol`), so callers that read
    /// structure keep it. The arena never leaks into this surface.
    @Test func structuredMatchesStillExposeSwiftSymbolTrees() throws {
        let text = "frame: $s4main3fooyyF called"
        let matches = MangledNameScanner().matches(in: text)
        #expect(matches.count == 1)
        let symbol: SwiftSymbol = try #require(matches.first).symbol
        #expect(symbol.kind == .Global)
        #expect(symbol.treeDump() == SwiftDemangler().demangle(symbol: "$s4main3fooyyF")?.treeDump())
    }

    /// The structured path keeps its own `__T…` Mach-O adapter, distinct from the
    /// arena string path's — a `__T…` name resolves through `DemangledSymbol` exactly
    /// when it resolves through the arena path, and to the same rendering.
    @Test func structuredMachODoubleUnderscoreAdapterStillApplies() {
        for name in ["__TtC4main5Thing", "__TFC4main5Thing3fooFT_T_", "__TMSi"] {
            let structured = DemangledSymbol(name)
            let arenaString = demangle(name, style: .full)
            #expect((structured != nil) == (arenaString != nil), "structured/arena __T adapter disagreement on \(name)")
            if let structured, let arenaString {
                #expect(SwiftDemanglerPrinter().print(structured.symbol, style: .full) == arenaString)
            }
        }
    }

    /// Both scans (arena `demangleAll` and structured `matches`) trim a trailing
    /// dot: a real unmangled suffix never ends in a dot, so a symbol ending a
    /// sentence must not swallow the period.
    @Test func bothScansTrimTrailingSentenceDotIdentically() {
        let text = "see frame $s4main3fooyyF. done"
        let out = String(decoding: MangledNameScanner().demangleAll(inBytes: Array(text.utf8), style: .full), as: UTF8.self)
        #expect(out == "see frame main.foo() -> (). done", "arena trailing-dot trim diverged: `\(out)`")
        // Structured scan: the match is the symbol without the trailing dot.
        let matches = MangledNameScanner().matches(in: text)
        #expect(matches.count == 1)
        #expect(matches.first?.mangled == "$s4main3fooyyF", "structured trailing-dot trim diverged")
    }
}
