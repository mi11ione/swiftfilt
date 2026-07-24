// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Current (`$s`) grammar arms the corpus never takes; renders and declines oracle-checked against `xcrun swift-demangle`, round-trips byte-exact.
@Suite("Current-mangling grammar arms")
struct CurrentManglingGrammarTests {
    private let demangler = SwiftDemangler()
    private let mangler = SwiftMangler()

    private func roundtrips(_ mangled: String) -> Bool {
        guard let tree = demangler.demangle(symbol: mangled) else { return false }
        return mangler.mangle(tree) == mangled
    }

    // MARK: Wide tuples — linear-time assembly, both backends

    @Test func wideTupleAssemblesInOneShotAndBothBackendsAgree() {
        // A tuple of `n` elements mangles as one element, the first-element
        // marker, `n-1` more, then `t`. The arena backend assembles the run in
        // one `make(kind:children:)` (linear, not the quadratic per-element
        // relocation), which must stay byte-identical to the value backend. The
        // crafted input repeats `Si` rather than substituting, so it is not the
        // remangler's canonical form — no round-trip asserted.
        let n = 3000
        let mangled = "$sSi_" + String(repeating: "Si", count: n - 1) + "t"
        let expected = "(" + Array(repeating: "Swift.Int", count: n).joined(separator: ", ") + ")"
        #expect(demangle(mangled) == expected)
        guard let tree = demangler.demangle(symbol: mangled) else {
            Issue.record("wide tuple must demangle on the value backend")
            return
        }
        #expect(SwiftDemanglerPrinter().print(tree) == expected)
    }

    // MARK: Generic requirements

    @Test func requirementFamiliesRenderAndRoundtrip() {
        #expect(demangle("$s4main3fooyyxAA1PCRbzlF") == "main.foo<A where A: main.P>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzClF") == "main.foo<A where A: AnyObject>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRi_zlF") == "main.foo<A where A: ~Swift.Copyable>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRi0_zlF") == "main.foo<A where A: ~Swift.Escapable>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRvzlF") == "main.foo<each A>(A) -> ()")
        for m in ["$s4main3fooyyxAA1PCRbzlF", "$s4main3fooyyxRlzClF", "$s4main3fooyyxRi_zlF",
                  "$s4main3fooyyxRi0_zlF", "$s4main3fooyyxRvzlF"]
        {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    // MARK: Function signature specializations

    @Test(arguments: [
        ("$s4main3fooyyFTf1d_n", "Dead"),
        ("$s4main3fooyyFTf1g_n", "Owned To Guaranteed"),
        ("$s4main3fooyyFTf1o_n", "Guaranteed To Owned"),
        ("$s4main3fooyyFTf1x_n", "Exploded"),
        ("$s4main3fooyyFTf1dG_n", "Dead and Owned To Guaranteed"),
        ("$s4main3fooyyFTf1dO_n", "Dead and Guaranteed To Owned"),
        ("$s4main3fooyyFTf1dX_n", "Dead and Exploded"),
        ("$s4main3fooyyFTf1dGOX_n", "Dead and Owned To Guaranteed and Guaranteed To Owned and Exploded"),
    ])
    func flagSpecializationParamsRenderAndRoundtrip(_ mangled: String, _ flags: String) {
        #expect(demangle(mangled)
            == "function signature specialization <Arg[0] = \(flags)> of main.foo() -> ()")
        #expect(roundtrips(mangled))
    }

    @Test func promotionAndConstantPropParamsRenderAndRoundtrip() {
        #expect(demangle("$s4main3fooyyFTf1i_n")
            == "function signature specialization <Arg[0] = Value Promoted from Box> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyFTf1r_n")
            == "function signature specialization <Arg[0] = InOut Converted to Out> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyFTf1e_n")
            == "function signature specialization <Arg[0] = Existential To Protocol Constrained Generic> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyFTf1s_n")
            == "function signature specialization <Arg[0] = Stack Promoted from Box> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyFTf1pi5_n")
            == "function signature specialization <Arg[0] = [Constant Propagated Integer : 5]> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyFTf5_n")
            == "function signature specialization <> of main.foo() -> ()")
        for m in ["$s4main3fooyyFTf1i_n", "$s4main3fooyyFTf1r_n", "$s4main3fooyyFTf1e_n",
                  "$s4main3fooyyFTf1s_n", "$s4main3fooyyFTf1pi5_n", "$s4main3fooyyFTf5_n"]
        {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func existentialToGenericComposesWithFlags() {
        #expect(demangle("$s4main3fooyyFTf1eDGOX_n")
            == "function signature specialization <Arg[0] = Existential To Protocol Constrained Generic "
            + "and Dead and Owned To Guaranteed and Guaranteed To Owned and Exploded> of main.foo() -> ()")
        for m in ["$s4main3fooyyFTf1eD_n", "$s4main3fooyyFTf1eG_n", "$s4main3fooyyFTf1eO_n",
                  "$s4main3fooyyFTf1eX_n", "$s4main3fooyyFTf1eDGOX_n"]
        {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func constantPropagatedOperandsRenderAndRoundtrip() {
        #expect(demangle("$s4main3fooyyF3abcTf1psb_n")
            == "function signature specialization <Arg[0] = [Constant Propagated String : u8'abc']> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyF3abcTf1psw_n")
            == "function signature specialization <Arg[0] = [Constant Propagated String : u16'abc']> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyF3abcTf1psc_n")
            == "function signature specialization <Arg[0] = [Constant Propagated String : objc'abc']> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyF3abcTf1pf_n")
            == "function signature specialization <Arg[0] = [Constant Propagated Function : abc]> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyF3abcTf1pg_n")
            == "function signature specialization <Arg[0] = [Constant Propagated Global : abc]> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyFTf1C0_n")
            == "function signature specialization <Arg[0] = [Same As Argument 0]> of main.foo() -> ()")
        for m in ["$s4main3fooyyF3abcTf1psb_n", "$s4main3fooyyF3abcTf1psw_n",
                  "$s4main3fooyyF3abcTf1psc_n", "$s4main3fooyyF3abcTf1pf_n",
                  "$s4main3fooyyF3abcTf1pg_n", "$s4main3fooyyFTf1C0_n"]
        {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func returnValueSpecializationSuffixesRender() {
        #expect(demangle("$s4main3fooyyFTf1d_g")
            == "function signature specialization <Arg[0] = Dead, Return = Owned To Guaranteed> of main.foo() -> ()")
        #expect(demangle("$s4main3fooyyFTf1d_x")
            == "function signature specialization <Arg[0] = Dead, Return = Exploded> of main.foo() -> ()")
        #expect(roundtrips("$s4main3fooyyFTf1d_g"))
        #expect(roundtrips("$s4main3fooyyFTf1d_x"))
        // An unknown or missing return marker is refused (oracle agrees).
        #expect(demangle("$s4main3fooyyFTf1d_b") == nil)
        #expect(demangle("$s4main3fooyyFTf1d_") == nil)
    }

    @Test func degenerateConstantPropPayloadsStayResolvedSupersets() {
        // Constant-prop parameters with MISSING operands: the reference
        // demangler refuses them, ours resolves a self-consistent tree —
        // the catalogued `constprop-degenerate-superset` deviation.
        #expect(demangle("$s4main3fooyyFTf1pk_n")
            == "function signature specialization <Arg[0] = [Constant Propagated KeyPath : <,>]> of main.foo() -> ()")
        // With one operand present the payload resolves partially and the
        // re-mangle canonicalizes to the operandless self-consistent form.
        let partial = demangler.demangle(symbol: "$s4main3fooyyFSiTf1pk_n")
        #expect(partial.flatMap { mangler.mangle($0) } == "$s4main3fooyyFTf1pk_n")
    }

    @Test(arguments: [
        ("$s4main3fooyyFSi_TG5", "generic not re-abstracted specialization <Swift.Int> of main.foo() -> ()"),
        ("$s4main3fooyyFSi_TB5", "generic specialization <Swift.Int> of main.foo() -> ()"),
        ("$s4main3fooyyFSi_Ts5", "generic pre-specialization <Swift.Int> of main.foo() -> ()"),
        ("$s4main3fooyyFSi_Tgq5", "generic specialization <serialized, Swift.Int> of main.foo() -> ()"),
        ("$s4main3fooyyFSi_Tga5", "generic specialization <Swift.Int> of main.foo() -> ()"),
        ("$s4main3fooyyFSi_Tgr5", "representation changed of main.foo() -> ()"),
        ("$s4main3fooyyFSi_Ti5", "inlined generic function <Swift.Int> of main.foo() -> ()"),
    ])
    func genericSpecializationKindsRenderAndRoundtrip(_ mangled: String, _ expected: String) {
        #expect(demangle(mangled) == expected)
        #expect(roundtrips(mangled))
    }

    @Test(arguments: [
        ("$s4main3fooyS2fFTJfSpSr", "forward-mode derivative"),
        ("$s4main3fooyS2fFTJrSpSr", "reverse-mode derivative"),
        ("$s4main3fooyS2fFTJdSpSr", "differential"),
        ("$s4main3fooyS2fFTJpSpSr", "pullback"),
    ])
    func autoDiffFunctionKindsRenderAndRoundtrip(_ mangled: String, _ label: String) {
        #expect(demangle(mangled)
            == "\(label) of main.foo(Swift.Float) -> Swift.Float with respect to parameters {0} and results {0}")
        #expect(roundtrips(mangled))
    }

    @Test func differentiabilityWitnessRendersAndRoundtrips() {
        let witness = "$s13test_mangling3fooyS2f_S2ftFWJrSpSr"
        #expect(demangle(witness)
            == "reverse-mode differentiability witness for test_mangling.foo(Swift.Float, Swift.Float, Swift.Float) "
            + "-> Swift.Float with respect to parameters {0} and results {0}")
        #expect(roundtrips(witness))
    }

    @Test(arguments: [
        ("$s4main3fooQryFQOMQ", "opaque type descriptor for"),
        ("$s4main3fooQryFQOMg", "opaque type descriptor accessor for"),
        ("$s4main3fooQryFQOMh", "opaque type descriptor accessor impl for"),
        ("$s4main3fooQryFQOMj", "opaque type descriptor accessor key for"),
        ("$s4main3fooQryFQOMk", "opaque type descriptor accessor var for"),
    ])
    func opaqueTypeDescriptorFamiliesRenderAndRoundtrip(_ mangled: String, _ label: String) {
        #expect(demangle(mangled) == "\(label) <<opaque return type of main.foo() -> some>>")
        #expect(roundtrips(mangled))
    }

    @Test func layoutRequirementFamiliesRenderAndRoundtrip() {
        #expect(demangle("$s4main3fooyyxRlzE8_4_lF") == "main.foo<A where A: _Trivial(9, 5)>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlze8_lF") == "main.foo<A where A: _Trivial(9)>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzM8_4_lF") == "main.foo<A where A: _TrivialAtMost(9, 5)>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzm8_lF") == "main.foo<A where A: _TrivialAtMost(9)>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzS8_lF") == "main.foo<A where A: (9)>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzUlF") == "main.foo<A where A: _UnknownLayout>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzRlF") == "main.foo<A where A: _RefCountedObject>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzNlF") == "main.foo<A where A: _NativeRefCountedObject>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzTlF") == "main.foo<A where A: _Trivial>(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzBlF") == "main.foo<A where A: >(A) -> ()")
        #expect(demangle("$s4main3fooyyxRlzDlF") == "main.foo<A where A: _NativeClass>(A) -> ()")
        for m in ["$s4main3fooyyxRlzE8_4_lF", "$s4main3fooyyxRlze8_lF", "$s4main3fooyyxRlzM8_4_lF",
                  "$s4main3fooyyxRlzm8_lF", "$s4main3fooyyxRlzS8_lF", "$s4main3fooyyxRlzUlF",
                  "$s4main3fooyyxRlzRlF", "$s4main3fooyyxRlzNlF", "$s4main3fooyyxRlzTlF",
                  "$s4main3fooyyxRlzBlF", "$s4main3fooyyxRlzDlF"]
        {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func valueGenericAndMultiParamSignaturesRenderAndRoundtrip() {
        #expect(demangle("$s4main3fooyyxRVzlF") == "main.foo<let A>() -> ()")
        #expect(demangle("$s4main3fooyyq_r0_lF") == "main.foo<A, B>(B) -> ()")
        #expect(demangle("$s4main3fooyyylF") == "main.foo<A>() -> ()")
        #expect(demangle("$s4main3fooyyxzlF") == "main.foo<A>(inout A) -> ()")
        for m in ["$s4main3fooyyxRVzlF", "$s4main3fooyyq_r0_lF", "$s4main3fooyyylF", "$s4main3fooyyxzlF"] {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func embeddedFlavorDemanglesAndCanonicalizesToStandard() {
        // `$e` parses identically to `$s`; the re-mangler emits the
        // standard prefix (the flavor is an input-side property).
        #expect(demangle("$e4main3fooyyF") == "main.foo() -> ()")
        let tree = demangler.demangle(symbol: "$e4main3fooyyF")
        #expect(tree.flatMap { mangler.mangle($0) } == "$s4main3fooyyF")
    }

    @Test(arguments: [
        "@__swiftmacro_4main3foofMf", // missing trailing underscore
        "@__swiftmacro_fMf_", // no context at all
        "@__swiftmacro_4main3foo0fMf_", // empty macro name
    ])
    func malformedMacroExpansionsDecline(_ mangled: String) {
        #expect(demangle(mangled) == nil)
    }

    // MARK: Attached-macro expansion kinds

    @Test(arguments: [
        ("a", "accessor"), ("r", "memberAttribute"), ("m", "member"),
        ("c", "conformance"), ("e", "extension"), ("b", "body"),
    ])
    func attachedMacroExpansionKindsRender(_ code: String, _ label: String) {
        let mangled = "@__swiftmacro_18macro_expand_peers1SV1f20addCompletionHandlerfM\(code)_"
        #expect(demangle(mangled)
            == "\(label) macro @addCompletionHandler expansion #1 of f in macro_expand_peers.S")
    }

    // MARK: Punycoded identifiers

    @Test func punycodedIdentifiersDecodeAndRoundtrip() {
        #expect(demangle("$s4main0012d_FfahroGaBbyyF") == "main.üñîçödé() -> ()")
        #expect(demangle("$s009mdl_snaFa3fooyyF") == "mödül.foo() -> ()")
        #expect(demangle("$s4main0010wgvHBaBBJeyyF") == "main.日本語() -> ()")
        #expect(demangle("$s4main005e_xbbyyF") == "main.é() -> ()")
        // A mapped non-symbol character (the space) survives the trip.
        #expect(demangle("$s4main007ab_qgJkyyF") == "main.a b() -> ()")
        for m in ["$s4main0012d_FfahroGaBbyyF", "$s009mdl_snaFa3fooyyF",
                  "$s4main0010wgvHBaBBJeyyF", "$s4main005e_xbbyyF", "$s4main007ab_qgJkyyF"]
        {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test(arguments: [
        "$s4main0012zzzzzzzzzzzzyyF", // delta overflow
        "$s4main008999999999yyF", // digits are not punycode letters
        "$s4main008________yyF", // separators only
        "$s4main004zzzzyyF", // overflow in a short payload
        "$s4main006zzzzzzyyF",
        "$s4main008zzzzzzzzyyF",
        "$s4main004000ayyF", // nested zero-length forms
    ])
    func malformedPunycodePayloadsDecline(_ mangled: String) {
        #expect(demangle(mangled) == nil)
    }

    // MARK: Operator identifiers

    @Test(arguments: [
        ("$s4main1coiyS2i_SitF", "@"), ("$s4main1noiyS2i_SitF", "!"),
        ("$s4main1ooiyS2i_SitF", "|"), ("$s4main1qoiyS2i_SitF", "?"),
        ("$s4main1toiyS2i_SitF", "~"), ("$s4main1xoiyS2i_SitF", "^"),
        ("$s4main1eoiyS2i_SitF", "="), ("$s4main3zzzoiyS2i_SitF", "..."),
    ])
    func operatorCharactersDecodeAndRoundtrip(_ mangled: String, _ op: String) {
        #expect(demangle(mangled) == "main.\(op) infix(Swift.Int, Swift.Int) -> Swift.Int")
        #expect(roundtrips(mangled))
    }

    @Test func operatorFixitiesRenderAndRoundtrip() {
        #expect(demangle("$s4main1noPyyF") == "main.! postfix() -> ()")
        #expect(demangle("$s4main1nopyyF") == "main.! prefix() -> ()")
        #expect(roundtrips("$s4main1noPyyF"))
        #expect(roundtrips("$s4main1nopyyF"))
    }

    @Test func invalidOperatorLettersDecline() {
        // 'A' is outside the a-z operator letter range; 'b' has no assigned
        // operator character. The oracle refuses both.
        #expect(demangle("$s4main1AoiyS2i_SitF") == nil)
        #expect(demangle("$s4main1boiyS2i_SitF") == nil)
    }

    // MARK: Repeat substitutions

    @Test func repeatSubstitutionBoundsAreEnforced() async {
        await onLargeStack {
            // In range: a large repeated standard substitution renders and
            // round-trips.
            let big = demangle("$sS10iD")
            #expect(big == String(repeating: "Swift.Int", count: 10))
            #expect(roundtrips("$sS10iD"))
            // Beyond maxRepeatCount (2047) and into natural-overflow: refused
            // (the oracle declines both).
            #expect(demangle("$sS3000iD") == nil)
            #expect(demangle("$sS99999999999999999999iD") == nil)
        }
    }

    // MARK: Entities and annotations

    @Test func isolatedDeallocatorAndConstValueRender() {
        #expect(demangle("$s4main3FooCfZ") == "main.Foo.__isolated_deallocating_deinit")
        #expect(roundtrips("$s4main3FooCfZ"))
        #expect(demangle("$sSiYgD") == "@const Swift.Int")
        #expect(roundtrips("$sSiYgD"))
        #expect(demangle("$s4main1vSiYgvp") == "main.v : @const Swift.Int")
        #expect(roundtrips("$s4main1vSiYgvp"))
    }

    @Test func nestedBoundGenericParentsBindPerLevel() {
        #expect(demangle("$s4main3FooC3BarCySi_GD") == "main.Foo<Swift.Int>.Bar")
        #expect(demangle("$s4main3FooC3BarCySi_SdGD") == "main.Foo<Swift.Int>.Bar<Swift.Double>")
        #expect(roundtrips("$s4main3FooC3BarCySi_GD"))
        #expect(roundtrips("$s4main3FooC3BarCySi_SdGD"))
    }

    @Test func associatedTypeRequirementFamiliesRender() {
        // Base-class, inverse, and layout requirements over associated
        // types (simple and compound paths) and over popped subject types.
        #expect(demangle("$s4main3fooyyxAA1CC1TRczlF")
            == "main.foo<A where A.T: main.C>(A) -> ()")
        #expect(demangle("$s4main3fooyyxAA1CC1TAA1PP_RCzlF")
            == "main.foo<A where A.main.P.T: main.C>(A) -> ()")
        #expect(demangle("$s4main3fooyyx1TRj_zlF")
            == "main.foo<A where A.T: ~Swift.Copyable>(A) -> ()")
        #expect(demangle("$s4main3fooyyx1TAA1PP_RJ_zlF")
            == "main.foo<A where A.main.P.T: ~Swift.Copyable>(A) -> ()")
        #expect(demangle("$s4main3fooyyx1TAA1PP_RMzTlF")
            == "main.foo<A where A.main.P.T: _Trivial>(A) -> ()")
        #expect(demangle("$s4main3fooyyAA1CCSiRBlF")
            == "main.foo<A where Swift.Int: main.C>() -> ()")
        #expect(demangle("$s4main3fooyySiRI0_lF")
            == "main.foo<A where Swift.Int: ~Swift.Escapable>() -> ()")
        // The simple-path forms re-mangle byte-exact; the compound paths
        // canonicalize onto their single-hop spellings.
        for m in ["$s4main3fooyyxAA1CC1TRczlF", "$s4main3fooyyx1TRj_zlF",
                  "$s4main3fooyyAA1CCSiRBlF", "$s4main3fooyySiRI0_lF"]
        {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
        let compound = demangler.demangle(symbol: "$s4main3fooyyx1TAA1PP_RJ_zlF")
        #expect(compound.flatMap { mangler.mangle($0) } == "$s4main3fooyyx1TAA1PPRj_zlF")
    }

    @Test func specialFunctionTypeOperatorsRenderAndCanonicalize() {
        #expect(demangle("$sytytXED") == "() -> ()")
        #expect(demangle("$sSiytXAD") == "@autoclosure () -> Swift.Int")
        #expect(demangle("$sSiytXKD") == "@autoclosure () -> Swift.Int")
        #expect(demangle("$sSiytXUD") == "() -> Swift.Int")
        #expect(demangle("$sSiytXLD") == "@escaping @convention(block) () -> Swift.Int")
        // Unit argument tuples canonicalize to the bare `y` spelling; the
        // uncurried marker canonicalizes to its `c` operator.
        let noescape = demangler.demangle(symbol: "$sytytXED")
        #expect(noescape.flatMap { mangler.mangle($0) } == "$syyXED")
        let uncurried = demangler.demangle(symbol: "$sSiytXUD")
        #expect(uncurried.flatMap { mangler.mangle($0) } == "$sSiycD")
    }

    @Test func silBoxLayoutsRenderAndRoundtrip() {
        // `Xx`: a SIL box with an explicit layout — empty, immutable (let)
        // and mutable (var, the inout-wrapped field) forms.
        #expect(demangle("$sSiyXxD") == "Swift.Int{ }")
        #expect(demangle("$sSi_XxD") == "{ let Swift.Int }")
        #expect(demangle("$sSiz_XxD") == "{ var Swift.Int }")
        for m in ["$sSiyXxD", "$sSi_XxD", "$sSiz_XxD"] {
            #expect(roundtrips(m), "\(m) must re-mangle byte-exact")
        }
    }

    @Test func punycodePayloadsDecodeAcrossScalarWidths() {
        // Verified against the oracle: payloads decoding to multi-byte
        // scalars, and a payload of pure basic characters that
        // canonicalizes to the plain identifier spelling.
        #expect(demangle("$s4main004jjjjyyF") == "main.Ⳛⳕ() -> ()")
        #expect(demangle("$s4main004xbbbyyF") == "main.քփ() -> ()")
        #expect(roundtrips("$s4main004jjjjyyF"))
        let basicOnly = demangler.demangle(symbol: "$s4main004e_e_yyF")
        #expect(demangle("$s4main004e_e_yyF") == "main.e_e() -> ()")
        #expect(basicOnly.flatMap { mangler.mangle($0) } == "$s4main3e_eyyF")
    }

    @Test func swiftFourZeroFunctionsCanonicalizeToCurrentMangling() {
        // `_T0` parses through the current grammar with the old-function
        // flag; the unlabelled form re-mangles to its `$s` spelling.
        let plain = demangler.demangle(symbol: "_T04main3fooyyF")
        #expect(plain != nil)
        #expect(plain.flatMap { mangler.mangle($0) } == "$s4main3fooyyF")
        // The labelled form keeps its label in the parameter tuple (the
        // catalogued `oldform-labellist-not-hoisted` shape) and stays
        // self-consistent in our grammar.
        #expect(demangle("_T04main3foo3barySi_tF") == "mainfoo.bar(Swift.Int) -> ()")
        let labelled = demangler.demangle(symbol: "_T04main3foo3barySi_tF")
        #expect(labelled.flatMap { mangler.mangle($0) } == "$s4main3foo3baryySi_tF")
    }
}
