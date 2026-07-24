// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The demangler's error / failed-guard arms across the operator grammar (current and legacy): each string parses valid up to an operator then given a bad/missing operand, so it must return `nil` (the oracle echoes it), exercising the `return nil`/`else` branches across the witness, thunk, builtin, type, entity, archetype, impl-function, substitution, and old-mangling paths.
@Suite("Swift demangler grammar error paths")
struct SwiftDemanglerBranchErrorPathTests {
    private let demangler = SwiftDemangler()

    private static let malformed = [
        "_Tw", "_Twq", "_Twal", "_Twas", "_TW", "_TWvd", "_TWt", "_TWT", "_TWl",
        "_TWL", "_TM", "_TMp", "_TPA__T", "_TTr", "_TTW", "_TTWC13call_protocol1CS_1PS_",
        "_TtB", "_TtBf", "_TtBi8", "_TtBv4B", "_TtV", "_TtC", "_TtP", "_TtER",
        "_TtXb", "_TtXBG", "_TtXM", "_TtXP", "_TtXF", "_TtQ", "_TtuR", "_Ttu_RxS",
        "_Ttu0_Rxl", "_Ttu0_RxlE", "_Ttu0_RxlmX", "_Ttu0_RxCSi", "_Ttwx", "_TtwxP",
        "_TtWxw", "_TtWA", "_TtFTSi", "_TtFGSaSi_", "_TF", "_Tv", "_TI", "_Ti",
        "_TFSiC", "_TFSig", "_TFSil", "_TFSiaO", "_TFSiM", "_TFSiU", "_TFESi",
        "_TFC4test1Cg9subscript", "_TISiA", "_TTSg5Si_", "_TTSf1cl", "_TTSf1cpX",
        "$sTe", "$sTl", "$sTU", "$sTz", "$sTv0", "$sTTI", "$sTRz", "$sTJSf",
        "$sTJfSpS", "$sSiTHz", "$sSiSiTHz", "$sSiSiTyz", "$sB", "$sBV",
        "$sBW", "$sHC", "$sHD", "$sHD0_", "$sHI0_", "$sRi", "$sRl", "$sSiRlU",
        "$sSiRm", "$sfd", "$sfp", "$sfM", "$svb", "$svz", "$svg", "$svaO", "$sXP",
        "$sQa", "$sQy", "$sQz", "$sQe", "$sQP", "$sQR", "$sQSd", "$sQx", "$sQZ",
        "$sXzB", "$sMXY", "$sMXA", "$sIyz", "$sIyB", "$sIyG", "$sIyAI", "$sIyTr_",
        "$sIyY", "$sSg", "$s1aoz", "$s3abcA2049A", "$sSi_tMXE", "$sSi_tfp",
        "$sSi_tE", "$s1aSi_tE", "$sr", "$s0A0", "$s1aQYz", "$sSi1a_QXBi",
        "$s4Test3fooySi_tF", "$s4Test3fooySi_tFy", "$s1x4Test3fooySi_SitF",
        "$s4Test3fooQrvpz", "$s4Test3foo1xSiQrFz",
        "$s4Test1CCSi_tcig33_abcdef0123456789abcdef0123456789LLz",
        // Reabstraction thunks missing their required from/to types: must be
        // nil, never a childless thunk (which would trap the printer).
        "$sTR", "$sTr", "$sTy",
    ]

    @Test func everyGrammarErrorPathReturnsNil() {
        let notNil = Self.malformed.filter { demangler.demangle(symbol: $0) != nil }
        #expect(notNil.isEmpty, "expected nil, but these demangled: \(notNil)")
    }

    @Test func operandlessReabstractionThunksDoNotTrapThePrinter() {
        // Regression: these once demangled to a childless thunk that crashed the
        // printer. Now they are nil, so the full demangle→print pipeline is safe.
        let printer = SwiftDemanglerPrinter()
        for name in ["$sTR", "$sTr", "$sTy"] {
            let ast = demangler.demangle(symbol: name)
            #expect(ast == nil)
            #expect(ast.map { printer.print($0, style: .full) } == nil)
        }
    }
}
