// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// Golden-corpus parity for legacy `_T` mangling (`OldDemangler` path): reads `legacy.tsv`
/// (Swift ≤4.0 names + `swift-demangle` `-compact`/`-simplified` oracle). Legacy names re-mangle
/// to the modern `$s` form, so only demangle+print parity is checked (round-trip lives in the `$s` corpus).
@Suite("Swift demangler legacy _T corpus parity")
struct SwiftDemanglerLegacyCorpusTests {
    private struct Row: Sendable {
        let mangled: String
        let compact: String
        let simplified: String
        let lineNumber: Int
    }

    private static func loadRows() throws -> [Row] {
        let path = SwiftDemanglerCorpusParity.fixturePath("legacy.tsv")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [Row] = []
        for (idx, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            rows.append(Row(mangled: parts[0], compact: parts[1], simplified: parts[2], lineNumber: idx + 1))
        }
        return rows
    }

    @Test func corpusIsNonEmpty() throws {
        #expect(try Self.loadRows().count > 200)
    }

    @Test func everyLegacyRowDemanglesAndPrints() async throws {
        let rows = try Self.loadRows()
        let failures = await onLargeStack { () -> [String] in
            let demangler = SwiftDemangler(); let printer = SwiftDemanglerPrinter()
            var fails: [String] = []
            for row in rows {
                guard let ast = demangler.demangle(symbol: row.mangled) else {
                    fails.append("L\(row.lineNumber) \(row.mangled): demangle nil"); continue
                }
                let full = printer.print(ast, style: .full)
                if full != row.compact { fails.append("L\(row.lineNumber) \(row.mangled): full=`\(full)` expected=`\(row.compact)`") }
                let simplified = printer.print(ast, style: .simplified)
                if simplified != row.simplified { fails.append("L\(row.lineNumber) \(row.mangled): simplified=`\(simplified)` expected=`\(row.simplified)`") }
            }
            return fails
        }
        let summary = failures.prefix(15).joined(separator: "\n  ")
        #expect(failures.isEmpty, "\(failures.count) legacy failure(s):\n  \(summary)")
    }

    @Test func legacyClosurePropagatedSpecializationDemangles() {
        // A legacy function-signature specialization with a closure-propagated
        // operand (`_TTSf1cl…`). It demangles to a tree (the old closure-prop
        // grammar); its printed form is a banded deviation, so only the parse
        // is asserted here.
        let symbol = "_TTSf1cl35_TFF7specgen6callerFSiT_U_FTSiSi_T_Si___TF7specgen12take_closureFFTSiSi_T_T_"
        #expect(SwiftDemangler().demangle(symbol: symbol) != nil)
    }

    @Test func malformedLegacyBodiesReturnNil() {
        // Truncated / ill-formed legacy bodies across the old grammar's parse
        // points (builtin, function type, bound generic, witness, metatype,
        // existential-metatype, special type) all fail cleanly.
        let demangler = SwiftDemangler()
        for name in ["_TtB", "_TFX", "_TtGSi", "_TWx", "_TMX", "_TtPM", "_TtXz", "_TF3fooFX",
                     "_TTSg0_", "_TtQUz", "_TTz", "_TWvz", "_TTSz", "_TTSf0cpz", "_TTRGx",
                     "_TTRG_RxSi", "_TTRG_RxlZ", "_TtQz", "_TtZ", "_TtBv2Bz", "_TtXMz", "_TtXFz"]
        {
            #expect(demangler.demangle(symbol: name) == nil, "expected nil for \(name)")
        }
    }

    @Test func rareLegacyAndDialectConstructsDemangleAndExerciseReMangle() {
        // Constructs absent from the round-tripping corpus, exercised through
        // demangle + (best-effort) re-mangle + print: a legacy extension whose
        // defining module is a substitution back-reference, a legacy
        // constant-propagated-string func-sig-spec, a `$S` bound-generic-function
        // (generic init), and a pseudogeneric SIL impl-function type.
        let demangler = SwiftDemangler(); let mangler = SwiftMangler(); let printer = SwiftDemanglerPrinter()
        for symbol in ["_TFESoV11def_structA1A4testfT_T_", "_T03foo4_123ABTf3psbpsb_n",
                       "$S3nix8MystructV1x1uACyxGx_qd__tclufc7MyaliasL_ayx_qd___GD", "$slIPg_D"]
        {
            let ast = demangler.demangle(symbol: symbol)
            #expect(ast != nil, "expected demangle for \(symbol)")
            if let ast {
                _ = mangler.mangle(ast)
                #expect(!printer.print(ast, style: .full).isEmpty)
            }
        }
    }
}
