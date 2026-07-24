// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Legacy `_T` grammar arm by arm; every accept and decline oracle-checked against `xcrun swift-demangle`.
@Suite("Old-mangling grammar arms")
struct OldManglingGrammarTests {
    // MARK: Accepting arms

    @Test func metadataOperatorsRenderTheirRecordKind() {
        #expect(demangle("_TMaC4main3Foo") == "type metadata accessor for main.Foo")
        #expect(demangle("_TMLC4main3Foo") == "lazy cache variable for type metadata for main.Foo")
    }

    @Test func serializedGenericSpecializationAttributeRenders() {
        #expect(demangle("_TTSgq0Si___TF4main3fooFT_T_")
            == "generic specialization <serialized, Swift.Int> of main.foo() -> ()")
    }

    @Test func constantPropagatedUTF16StringSpecializationRenders() {
        #expect(demangle("_TTSf0cpse1v3abc___TF4main3fooFT_T_")
            == "function signature specialization <Arg[0] = [Constant Propagated String : u16'abc']> of main.foo() -> ()")
    }

    @Test func bufferPointerSubstitutionsResolve() {
        #expect(demangle("_TtSR") == "Swift.UnsafeBufferPointer")
        #expect(demangle("_TtSr") == "Swift.UnsafeMutableBufferPointer")
    }

    @Test func extensionContextNamesTheStdlibDefiningModule() {
        // `E` + `s`: an extension whose defining module is the stdlib
        // shorthand, not an identifier.
        #expect(demangle("_TtaEsSi5Alias") == "(extension in Swift):Swift.Int.Alias")
    }

    @Test func boundGenericNominalsBindTheirArguments() {
        #expect(demangle("_TtGC4main3BarSi_") == "main.Bar<Swift.Int>")
        #expect(demangle("_TtGO4main3BarSi_") == "main.Bar<Swift.Int>")
        // An empty argument list leaves the nominal unbound.
        #expect(demangle("_TtGC4main3Bar_") == "main.Bar")
        // A bound-generic context inside an entity.
        #expect(demangle("_TFGC4main3BarSi_3fooFT_T_") == "main.Bar<Swift.Int>.foo() -> ()")
    }

    @Test func builtinBridgeObjectAndValueBufferRender() {
        #expect(demangle("_TtBb") == "Builtin.BridgeObject")
        #expect(demangle("_TtBB") == "Builtin.UnsafeValueBuffer")
    }

    @Test func thinFunctionAndUnmanagedSpecialTypesRender() {
        #expect(demangle("_TtXfT_T_") == "@convention(thin) () -> ()")
        #expect(demangle("_TtXuSi") == "unowned(unsafe) Swift.Int")
    }

    @Test func prefixOperatorEntityDecodesTheOperatorTable() {
        // `op` + `1a`: operator letter 'a' decodes to '&'.
        #expect(demangle("_TF4mainop1aFT_T_") == "main.& prefix() -> ()")
    }

    @Test func unknownDifferentiabilityKindIsConsumedNotFatal() {
        // `FDq`: 'q' is no differentiability kind; both demanglers consume
        // it and carry on (`swift-demangle` prints the same plain type).
        #expect(demangle("_TtFDqT_T_") == "() -> ()")
    }

    @Test func accessorOfALocalDeclarationKeepsTheDiscriminator() {
        #expect(demangle("_TF4maingL0_3abcSi") == "getter of abc #2 : Swift.Int in main")
    }

    // MARK: Declining arms — specialization payloads

    // Every input below is refused by `swift-demangle` too (echoed back).

    @Test(arguments: [
        "_TTSf0n__Q", // specialization attribute not followed by `_T`
        "_TTSg0SiXX__TF4main3fooFT_T_", // conformance in a spec param fails
        "_TTSf0cpfr0", // constant-prop function: empty identifier
        "_TTSf0cpg0", // constant-prop global: empty identifier
        "_TTSf0cpi12", // constant-prop integer: no terminating underscore
        "_TTSf0cpfl12", // constant-prop float: no terminating underscore
        "_TTSf0cpsx", // constant-prop string: missing `e`
        "_TTSf0cpse2", // constant-prop string: encoding not 0/1
        "_TTSf0cpse0x", // constant-prop string: missing `v`
        "_TTSf0x", // parameter with no known marker and empty flags
    ])
    func malformedSpecializationPayloadsDecline(_ mangled: String) {
        #expect(demangle(mangled) == nil)
    }

    // MARK: Declining arms — names, identifiers, operators

    @Test(arguments: [
        "_TF4mainLx", // local decl name: bad discriminator index
        "_TF4mainP", // private decl name: nothing follows
        "_TFoi5apply", // module position cannot hold an operator name
        "_TF4mainox1a", // unknown operator fixity marker
        "_TtCX2AA3Foo", // punycode identifier that does not decode
        "_TtC4main0", // zero-length identifier
        "_TF4mainoi2A1", // operator letter outside a-z
        "_TF4mainoi1b", // operator letter with no assigned character
    ])
    func malformedNamesDecline(_ mangled: String) {
        #expect(demangle(mangled) == nil)
    }

    // MARK: Declining arms — protocols, substitutions, bound generics

    @Test(arguments: [
        "_TtPs0_", // protocol name: empty identifier after stdlib context
        "_TtPSz_", // protocol substitution: unknown index
        "_TtPSa_", // protocol substitution resolving to a non-protocol
        "_TtGSoSi_", // bound generic over a childless module substitution
        "_TtGVSq3Fooz", // bound generic parent whose own arguments fail
        "_TtGC4main3FooSi", // argument list hits end of input
        "_TtGP4main3FooSi_", // bound generic over a protocol
        "_TtGz", // no nominal after G
        "_Ttae1ar", // constrained extension context missing its type
    ])
    func malformedProtocolAndGenericContextsDecline(_ mangled: String) {
        #expect(demangle(mangled) == nil)
    }

    // MARK: Declining arms — entities and accessors

    @Test(arguments: [
        "_TF4mainax", // unknown mutable-addressor flavor
        "_TF4mainlO0", // owning addressor: empty name
        "_TF4mainG0", // global getter: empty name
        "_TF4mains0", // setter: empty name
        "_TF4mainm0", // materializeForSet: empty name
        "_TF4mainw0", // willSet: empty name
        "_TF4mainW0", // didSet: empty name
        "_TF4mainr0", // read accessor: empty name
        "_TF4mainux", // implicit closure: bad index
        "_TI4mainz", // initializer entity that is neither A nor i
    ])
    func malformedEntitiesDecline(_ mangled: String) {
        #expect(demangle(mangled) == nil)
    }

    // MARK: Declining arms — dependent types, signatures, archetypes

    @Test(arguments: [
        "_Ttqdz", // dependent param: bad depth index
        "_TtqxSa", // member type ref substitution of the wrong kind
        "_Ttwz", // associated type: bad base param
        "_Ttq", // dependent type at end of input
        "_TtqX", // dependent base type fails
        "_TtuRxzz", // same-type requirement: second type fails
        "_TtuRx", // requirement hits end of input
        "_TtuRxSo0", // conformance via module substitution: bad protocol name
        "_TtuRx1", // conformance constraint: bad protocol
        "_TtuRxle", // layout `e`: missing size
        "_TtuRxlM1", // layout `M`: missing alignment separator
        "_TtuRxlS", // layout `S`: missing size
        "_TtQs0", // archetype: empty associated-type name
        "_TtQQz", // nested archetype root fails
        "_TtQSz", // archetype substitution fails
    ])
    func malformedDependentTypesAndSignaturesDecline(_ mangled: String) {
        #expect(demangle(mangled) == nil)
    }

    // MARK: Declining arms — tuples, functions, builtins, special types

    @Test(arguments: [
        "_TtT0Si_", // tuple label: zero-length identifier
        "_TtT3abcz", // tuple element type fails
        "_TtFYz", // global-actor type fails
        "_TtRz", // inout wraps a failing type
        "_Ttkz", // no-derivative wraps a failing type
        "_TtBv3x", // builtin vector: missing element marker
        "_TtBv3Bix", // builtin vector of ints: bad size
        "_TtBv3Bfx", // builtin vector of floats: bad size
        "_TtBz", // unknown builtin
        "_TtXPMz", // existential metatype: bad representation
        "_TtXBx", // SIL box layout: unknown field marker
        "_TtXBiz", // SIL box field type fails
        "_TtXBGr_z", // SIL box generic argument type fails
        "_TTRT_z", // reabstraction destination type fails
        "_TtXFoCz", // impl function: unknown convention attachment
        "_TtXFoGz", // impl function: generic signature fails
        "_TtXFoz", // impl function: missing parameter separator
        "_TtXFo_z", // `z` error marker on a parameter
        "_TtXFo__q", // result with no convention
        "_TtXFo_dz", // parameter type fails
    ])
    func malformedTypesDecline(_ mangled: String) {
        #expect(demangle(mangled) == nil)
    }

    // MARK: Recursion depth guards

    @Test func depthGuardsRefuseRunawayNesting() async {
        // 1023 metatype wrappers land the protocol-name parse just past
        // the 1024-frame guard; 520 chained function entities do the same
        // for the entity parser. `swift-demangle` refuses both inputs.
        await onLargeStack {
            let metatypeChain = "_Tt" + String(repeating: "M", count: 1023) + "Ps3Foo_"
            #expect(demangle(metatypeChain) == nil)
            let entityChain = "_T" + String(repeating: "F", count: 520) + "4main3fooFT_T_"
            #expect(demangle(entityChain) == nil)
        }
    }
}
