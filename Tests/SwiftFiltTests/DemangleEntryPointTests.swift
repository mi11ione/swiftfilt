// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// The tier-0 entry points (`demangle(_:style:)`, `demangle(validating:style:)`, `isSwiftMangled(_:)`): every era in, the right string or typed error out, at golden-fixture parity.
@Suite("Top-level demangle entry points")
struct DemangleEntryPointTests {
    // MARK: Happy path across every shipped prefix era

    @Test func demanglesEveryPrefixEra() {
        // Stable ABI, with and without the Mach-O underscore.
        #expect(demangle("$s4main3fooyyF") == "main.foo() -> ()")
        #expect(demangle("_$s4main3fooyyF") == "main.foo() -> ()")
        // Swift 4.2 `$S`.
        #expect(demangle("$S4main3fooyyF") == "main.foo() -> ()")
        #expect(demangle("_$S4main3fooyyF") == "main.foo() -> ()")
        // Embedded Swift.
        #expect(demangle("$e4main3fooyyF") == "main.foo() -> ()")
        #expect(demangle("_$e4main3fooyyF") == "main.foo() -> ()")
        // Swift 4.0.
        #expect(demangle("_T04main3fooyyF") == "main.foo() -> ()")
        // Legacy ObjC-metadata class names, single and doubled underscore.
        #expect(demangle("_TtC4test3Foo") == "test.Foo")
        #expect(demangle("__TtC4test3Foo") == "test.Foo")
    }

    @Test func styleParameterSelectsTheValidatedPresets() {
        let mangled = "$s4main6ServerC5start4portySi_tF"
        #expect(demangle(mangled) == "main.Server.start(port: Swift.Int) -> ()")
        #expect(demangle(mangled, style: .full) == "main.Server.start(port: Swift.Int) -> ()")
        #expect(demangle(mangled, style: .simplified) == "Server.start(port:)")
        #expect(demangle(mangled, style: .qualified) == "main.Server.start(port: Swift.Int) -> ()")
        #expect(demangle(mangled, style: .unqualified) == "start(port: Int) -> ()")
    }

    @Test func llvmSuffixedSymbolsDemangle() {
        #expect(demangle("$s4main3fooyyF.llvm.123")
            == "main.foo() -> () with unmangled suffix \".llvm.123\"")
    }

    @Test func punycodedDebuggerModulesRenderAndProbeCorrectly() {
        // Punycoded (owned) module names beginning with the `__lldb_expr_`
        // debugger prefix: the printer's module probes must answer from the
        // assembled text as `String.hasPrefix` would — one with an ASCII byte
        // after the prefix, one with a non-ASCII scalar (grapheme boundary).
        // `swift-demangle` renders all three identically.
        #expect(demangle("$s0017___lldb_expr_1_nhb3fooyyF") == "__lldb_expr_1é.foo() -> ()")
        #expect(demangle("$s0016___lldb_expr__meb3fooyyF") == "__lldb_expr_é.foo() -> ()")
        // A punycoded module NOT carrying the debugger prefix walks the
        // same probes to their negative answers.
        #expect(demangle("$s005w_bga3fooyyF") == "wé.foo() -> ()")
    }

    @Test func emptyRenderingsReturnNilNeverAnEmptyString() {
        // `$ss` (the bare Swift module) parses but renders empty in
        // .simplified — `swift-demangle -simplified` echoes it likewise;
        // the entry point answers nil, never "".
        #expect(demangle("$ss") == "Swift")
        #expect(demangle("$ss", style: .simplified) == nil)
        #expect(throws: DemangleError.malformed) {
            try demangle(validating: "$ss", style: .simplified)
        }
        // `$sRv_` parses but renders empty in every style (the reference
        // printer refuses the bare pack marker): nil across the presets.
        for style in DemangleStyle.allCases {
            #expect(demangle("$sRv_", style: style) == nil)
        }
    }

    // MARK: Failures and the typed taxonomy

    @Test(arguments: [
        "hello", "_ZN4llvm3fooEv", "__ZTVN3fooE", "_TK_LOGGING", "", " ",
        "printf", "0x0000000100003f50", "_main",
        // `_T` + a char that starts no top-level symbol: a dead operator
        // (`o a f`: no old-grammar production) or a bare nominal-type code
        // (`S`: begins a type, not a symbol). The honest verdict is "not
        // Swift" — hand these C names to the next demangler, not corrupt.
        "_ToggleFlag", "_TableSize", "_TfooHelper", "_TS",
    ])
    func nonSwiftNamesReturnNilAndThrowNotSwiftMangled(_ name: String) {
        #expect(demangle(name) == nil)
        #expect(!isSwiftMangled(name))
        #expect(throws: DemangleError.notSwiftMangled) {
            try demangle(validating: name)
        }
    }

    @Test(arguments: [
        "$s", "$sZZZ", "_$s", "$S", "$e", "_T0", "@__swiftmacro_",
        // `_T` + a recognized operator that then fails the parse — the
        // DemangleError.malformed doc's "`_T…` C symbol that slipped past
        // prefix heuristics" case (`i` is the legacy subscript operator).
        "_TimerCallback", "_Ti",
    ])
    func swiftPrefixedGarbageReturnsNilAndThrowsMalformed(_ name: String) {
        #expect(demangle(name) == nil)
        #expect(isSwiftMangled(name), "the prefix pre-filter accepts these; only the parse rejects them")
        #expect(throws: DemangleError.malformed) {
            try demangle(validating: name)
        }
    }

    @Test func validatingVariantMatchesTheOptionalVariantOnSuccess() throws {
        let mangled = "$s4main6ServerC5start4portySi_tF"
        for style in DemangleStyle.allCases {
            #expect(try demangle(validating: mangled, style: style) == demangle(mangled, style: style))
        }
    }

    @Test func errorsAreHashableAndDescribable() {
        #expect(DemangleError.notSwiftMangled != DemangleError.malformed)
        #expect(Set([DemangleError.notSwiftMangled, .malformed, .notSwiftMangled]).count == 2)
        #expect(!DemangleError.notSwiftMangled.description.isEmpty)
        #expect(!DemangleError.malformed.description.isEmpty)
    }

    // MARK: The prefix pre-filter

    @Test func isSwiftMangledAcceptsEveryFixtureSymbol() throws {
        let corpus = try SwiftDemanglerCorpusParity.loadRows()
        #expect(corpus.allSatisfy { isSwiftMangled($0.mangled) })
        // Pre-filter soundness over the legacy fixtures: every fixture symbol
        // is a real entity/global start, so all pass the grammar-exact `_T`
        // gate. The gate is intentionally stricter than the demangler on bare
        // nominal-type codes (`_TS…`/`_TC…` — a type, not a symbol), but no
        // such collision appears in the curated fixtures.
        let legacy = try FixtureRows.legacy()
        let rejected = legacy.filter { !isSwiftMangled($0.mangled) }
        #expect(rejected.isEmpty, "pre-filter rejected demangleable fixtures: \(rejected.map(\.mangled))")
    }

    /// The pre-filter is intentionally STRICTER than the mechanical demangler
    /// on the ambiguous `_T` lead. A real entity (a legacy subscript) passes
    /// both. A bare nominal-type code passes the demangler — which renders the
    /// bare type — but the pre-filter rejects it: a type is not a top-level
    /// symbol, so the scanner must not lift such `_TK_LOG`-class C collisions.
    @Test func preFilterRejectsBareTypeCollisionsTheDemanglerStillRenders() {
        let sym = "_TiC4Meow5MyCls9subscriptFT1iSi_Sf"
        #expect(isSwiftMangled(sym))
        #expect(demangle(sym) == "Meow.MyCls.subscript(i: Swift.Int) -> Swift.Float")
        #expect(!isSwiftMangled("_TSa"))
        #expect(demangle("_TSa") == "Swift.Array")
    }

    // MARK: Full-corpus parity through the product entry point

    @Test func everyCorpusRowDemanglesToItsFixtureRendering() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let failures = await onLargeStack { () -> [String] in
            var fails: [String] = []
            for row in rows {
                guard let out = demangle(row.mangled) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): nil")
                    continue
                }
                // Where the oracle declined (echoed its input), SwiftFilt
                // resolving the symbol is the documented superset behavior.
                if SwiftDemanglerCorpusParity.oracleDeclined(row.compact, for: row) { continue }
                if out != row.compact {
                    fails.append("L\(row.lineNumber) \(row.mangled): \(out) != \(row.compact)")
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(failures.count) mismatches; first: \(failures.first ?? "")")
    }

    @Test func everyLegacyRowDemanglesThroughTheProductEntryPoint() async throws {
        let rows = try FixtureRows.legacy()
        let failures = await onLargeStack { () -> [String] in
            var fails: [String] = []
            for row in rows {
                guard let out = demangle(row.mangled) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): nil")
                    continue
                }
                if out != row.compact {
                    fails.append("L\(row.lineNumber) \(row.mangled): \(out) != \(row.compact)")
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(failures.count) mismatches; first: \(failures.first ?? "")")
    }

    /// The Mach-O double-underscore adapter, grounded in the legacy corpus:
    /// every `_T…` fixture symbol behind one more underscore demangles to
    /// exactly the same rendering, as `swift-demangle` adapts it.
    @Test func doubledUnderscoreLegacyNamesDemangleIdentically() async throws {
        let rows = try FixtureRows.legacy().filter { $0.mangled.hasPrefix("_T") }
        try #require(!rows.isEmpty)
        let failures = await onLargeStack { () -> [String] in
            var fails: [String] = []
            for row in rows {
                let doubled = "_" + row.mangled
                if demangle(doubled) != demangle(row.mangled) {
                    fails.append("L\(row.lineNumber) \(doubled): differs from single-underscore form")
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(failures.count) mismatches; first: \(failures.first ?? "")")
    }
}

/// Shared fixture loading for the product-surface suites.
enum FixtureRows {
    struct LegacyRow: Sendable {
        let mangled: String
        let compact: String
        let simplified: String
        let lineNumber: Int
    }

    static func legacy() throws -> [LegacyRow] {
        let path = SwiftDemanglerCorpusParity.fixturePath("legacy.tsv")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [LegacyRow] = []
        for (idx, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            rows.append(LegacyRow(mangled: parts[0], compact: parts[1], simplified: parts[2], lineNumber: idx + 1))
        }
        return rows
    }
}
