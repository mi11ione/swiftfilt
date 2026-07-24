// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// SIL impl-function types (`I…`) arm by arm: every parameter/result/callee convention, function-convention attachment, coroutine kind, attribute, differentiability, yield, and error-result form. Oracle-checked against `xcrun swift-demangle`; re-mangles byte-exact unless pinned.
@Suite("Impl-function-type grammar")
struct ImplFunctionTypeGrammarTests {
    private let demangler = SwiftDemangler()
    private let mangler = SwiftMangler()

    private func roundtrips(_ mangled: String) -> Bool {
        guard let tree = demangler.demangle(symbol: mangled) else { return false }
        return mangler.mangle(tree) == mangled
    }

    @Test(arguments: [
        ("$sSiIegi_D", "@escaping @callee_guaranteed (@in Swift.Int) -> ()"),
        ("$sSiIegc_D", "@escaping @callee_guaranteed (@in_constant Swift.Int) -> ()"),
        ("$sSiIegl_D", "@escaping @callee_guaranteed (@inout Swift.Int) -> ()"),
        ("$sSiIegb_D", "@escaping @callee_guaranteed (@inout_aliasable Swift.Int) -> ()"),
        ("$sSiIegn_D", "@escaping @callee_guaranteed (@in_guaranteed Swift.Int) -> ()"),
        ("$sSiIegX_D", "@escaping @callee_guaranteed (@in_cxx Swift.Int) -> ()"),
        ("$sSiIegx_D", "@escaping @callee_guaranteed (@owned Swift.Int) -> ()"),
        ("$sSiIegg_D", "@escaping @callee_guaranteed (@guaranteed Swift.Int) -> ()"),
        ("$sSiIege_D", "@escaping @callee_guaranteed (@deallocating Swift.Int) -> ()"),
        ("$sSiIegy_D", "@escaping @callee_guaranteed (@unowned Swift.Int) -> ()"),
        ("$sSiIegv_D", "@escaping @callee_guaranteed (@pack_owned Swift.Int) -> ()"),
        ("$sSiIegp_D", "@escaping @callee_guaranteed (@pack_guaranteed Swift.Int) -> ()"),
        ("$sSiIegm_D", "@escaping @callee_guaranteed (@pack_inout Swift.Int) -> ()"),
    ])
    func parameterConventionsRenderAndRoundtrip(_ mangled: String, _ expected: String) {
        #expect(demangle(mangled) == expected)
        #expect(roundtrips(mangled))
    }

    @Test(arguments: [
        ("$sSiIegr_D", "@escaping @callee_guaranteed () -> (@out Swift.Int)"),
        ("$sSiIego_D", "@escaping @callee_guaranteed () -> (@owned Swift.Int)"),
        ("$sSiIegd_D", "@escaping @callee_guaranteed () -> (@unowned Swift.Int)"),
        ("$sSiIegu_D", "@escaping @callee_guaranteed () -> (@unowned_inner_pointer Swift.Int)"),
        ("$sSiIega_D", "@escaping @callee_guaranteed () -> (@autoreleased Swift.Int)"),
        ("$sSiIegk_D", "@escaping @callee_guaranteed () -> (@pack_out Swift.Int)"),
    ])
    func resultConventionsRenderAndRoundtrip(_ mangled: String, _ expected: String) {
        #expect(demangle(mangled) == expected)
        #expect(roundtrips(mangled))
    }

    @Test func parameterModifiersAttach() {
        #expect(demangle("$sSiIegiw_D") == "@escaping @callee_guaranteed (@in @noDerivative Swift.Int) -> ()")
        #expect(demangle("$sSiIegiT_D") == "@escaping @callee_guaranteed (@in sending Swift.Int) -> ()")
        #expect(demangle("$sSiIegiI_D") == "@escaping @callee_guaranteed (@in isolated Swift.Int) -> ()")
        #expect(demangle("$sSiIegiL_D")
            == "@escaping @callee_guaranteed (@in sil_implicit_leading_param Swift.Int) -> ()")
        for m in ["$sSiIegiw_D", "$sSiIegiT_D", "$sSiIegiI_D", "$sSiIegiL_D", "$sSiIegiwTIL_D"] {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test(arguments: [
        ("$sIey_D", "@escaping @callee_unowned () -> ()"),
        ("$sIeg_D", "@escaping @callee_guaranteed () -> ()"),
        ("$sIex_D", "@escaping @callee_owned () -> ()"),
        ("$sIet_D", "@escaping @convention(thin) () -> ()"),
    ])
    func calleeConventionsRenderAndRoundtrip(_ mangled: String, _ expected: String) {
        #expect(demangle(mangled) == expected)
        #expect(roundtrips(mangled))
    }

    @Test(arguments: [
        ("$sIetB_D", "block"), ("$sIetC_D", "c"), ("$sIetM_D", "method"),
        ("$sIetO_D", "objc_method"), ("$sIetK_D", "closure"), ("$sIetW_D", "witness_method"),
    ])
    func functionConventionsRenderAndRoundtrip(_ mangled: String, _ name: String) {
        #expect(demangle(mangled) == "@escaping @convention(thin) @convention(\(name)) () -> ()")
        #expect(roundtrips(mangled))
    }

    @Test func clangTypedConventionsCarryTheMangledClangType() {
        #expect(demangle("$sIetzC2id_D")
            == "@escaping @convention(thin) @convention(c, mangledCType: \"id\") () -> ()")
        #expect(demangle("$sIetzB2id_D")
            == "@escaping @convention(thin) @convention(block, mangledCType: \"id\") () -> ()")
        #expect(roundtrips("$sIetzC2id_D"))
        #expect(roundtrips("$sIetzB2id_D"))
    }

    @Test func coroutineKindsRenderAndRoundtrip() {
        #expect(demangle("$sIetA_D") == "@escaping @convention(thin) @yield_once () -> ()")
        #expect(demangle("$sIetI_D") == "@escaping @convention(thin) @yield_once_2 () -> ()")
        #expect(demangle("$sIetG_D") == "@escaping @convention(thin) @yield_many () -> ()")
        #expect(demangle("$sSiIetAYi_D")
            == "@escaping @convention(thin) @yield_once () -> (@yields @in Swift.Int)")
        for m in ["$sIetA_D", "$sIetI_D", "$sIetG_D", "$sSiIetAYi_D", "$sSiIetIYi_D", "$sSiIetGYi_D"] {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func functionAttributesAndIsolationRender() {
        #expect(demangle("$sIeth_D") == "@escaping @convention(thin) @Sendable () -> ()")
        #expect(demangle("$sIetH_D") == "@escaping @convention(thin) @async () -> ()")
        #expect(demangle("$sIetT_D") == "@escaping @convention(thin) () -> sending ()")
        #expect(demangle("$sIeAt_D") == "@escaping @isolated(any) @convention(thin) () -> ()")
        #expect(demangle("$sIeNt_D") == "@escaping @caller_isolated @convention(thin) () -> ()")
        #expect(demangle("$sINt_D") == "@caller_isolated @convention(thin) () -> ()")
        for m in ["$sIeth_D", "$sIetH_D", "$sIetT_D", "$sIeAt_D", "$sIeNt_D", "$sINt_D"] {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func differentiabilityKindsRenderAndRoundtrip() {
        #expect(demangle("$sIedt_D") == "@escaping @differentiable @convention(thin) () -> ()")
        #expect(demangle("$sIelt_D") == "@escaping @differentiable(_linear) @convention(thin) () -> ()")
        #expect(demangle("$sIeft_D") == "@escaping @differentiable(_forward) @convention(thin) () -> ()")
        #expect(demangle("$sIert_D") == "@escaping @differentiable(reverse) @convention(thin) () -> ()")
        for m in ["$sIedt_D", "$sIelt_D", "$sIeft_D", "$sIert_D"] {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func errorResultsRenderAndRoundtrip() {
        #expect(demangle("$sSiIetzr_D") == "@escaping @convention(thin) () -> (@error @out Swift.Int)")
        #expect(roundtrips("$sSiIetzr_D"))
        // Repeat-substituted operand list: the canonical spelling.
        #expect(demangle("$sS2iIetizr_D")
            == "@escaping @convention(thin) (@in Swift.Int) -> (@error @out Swift.Int)")
        #expect(roundtrips("$sS2iIetizr_D"))
    }

    @Test(arguments: [
        ("$sSiIetzl_D", "@guaranteed_address"), ("$sSiIetzg_D", "@guaranteed"),
        ("$sSiIetzm_D", "@inout"), ("$sSiIetzd_D", "@unowned"),
        ("$sSiIetzu_D", "@unowned_inner_pointer"), ("$sSiIetza_D", "@autoreleased"),
        ("$sSiIetzk_D", "@pack_out"), ("$sSiIetzo_D", "@owned"),
    ])
    func errorResultConventionsRenderAndRoundtrip(_ mangled: String, _ conv: String) {
        // The result-convention letters shared with the parameter table
        // (`l`/`g`/`m`) are reachable only through the error-result slot:
        // in the plain result loop the parameter parse consumes them first.
        #expect(demangle(mangled) == "@escaping @convention(thin) () -> (@error \(conv) Swift.Int)")
        #expect(roundtrips(mangled))
    }

    @Test func pseudogenericImplTypeDemanglesButHasNoRemangleProduction() {
        // The `$s` twin of the catalogued `remangler-gap-legacy-exotic-types`
        // tree family: apple's reference converts through this shape; our
        // remangler deliberately lacks the production and answers nil.
        #expect(demangle("$sxxlIPxyd_D") == "@callee_owned <A> (@unowned A) -> (@unowned A)")
        let tree = SwiftDemangler().demangle(symbol: "$sxxlIPxyd_D")
        #expect(tree != nil)
        #expect(tree.flatMap { SwiftMangler().mangle($0) } == nil)
    }

    @Test func substitutedImplTypesDemangleOracleExact() async {
        // Pattern (`Is…`) and invocation (`II…`) substitutions over a
        // @substituted generic impl type — the `…TC` fixture row's type
        // spelled as a bare type mangling. The reference remangler
        // round-trips these; ours lacks the production (catalogued as
        // `remangler-gap-coroutine-continuation`) and answers nil.
        await onLargeStack {
            let pattern = "$sxSo8_NSRangeVRlzCRl_Cr0_llySo12ModelRequestCyxq_GIsPetWAlYl_D"
            #expect(demangle(pattern)
                == "@escaping @convention(thin) @convention(witness_method) @yield_once "
                + "<A, B where A: AnyObject, B: AnyObject> @substituted <A> (@inout A) -> "
                + "(@yields @inout __C._NSRange) for <__C.ModelRequest<A, B>>")
            let patternTree = SwiftDemangler().demangle(symbol: pattern)
            #expect(patternTree.flatMap { SwiftMangler().mangle($0) } == nil)

            let invocation = "$sxSo8_NSRangeVRlzCRl_Cr0_lySo12ModelRequestCyxq_GIIPetWAlYl_D"
            #expect(demangle(invocation)
                == "@escaping @convention(thin) @convention(witness_method) @yield_once "
                + "<A, B where A: AnyObject, B: AnyObject> (@inout A) -> "
                + "(@yields @inout __C._NSRange) for <__C.ModelRequest<A, B>>")
            let invocationTree = SwiftDemangler().demangle(symbol: invocation)
            #expect(invocationTree.flatMap { SwiftMangler().mangle($0) } == nil)
        }
    }
}
