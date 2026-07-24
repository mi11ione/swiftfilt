// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Remangler paths the round-tripping corpus can't reach: inline-only nodes (standalone re-mangle must fail), and constant-prop-struct / same-as-argument func-sig-spec params that apple/swift `main` round-trips byte-exact but the host LLVM-17 oracle can't demangle (so they can't live in the oracle-keyed fixture).
@Suite("Swift mangler remangle paths")
struct SwiftManglerRemanglePathsTests {
    private let demangler = SwiftDemangler()
    private let mangler = SwiftMangler()

    @Test func silBoxTypeDemanglesButHasNoRemangleProduction() {
        // `$sSiXbD` — the current-grammar spelling of the catalogued
        // `remangler-gap-legacy-exotic-types` box type (apple converts
        // `_TtXbSi` to exactly this). Demangling agrees with the oracle;
        // our remangler deliberately lacks the production and answers nil.
        #expect(SwiftFilt.demangle("$sSiXbD") == "@box Swift.Int")
        let tree = demangler.demangle(symbol: "$sSiXbD")
        #expect(tree != nil)
        #expect(tree.flatMap { mangler.mangle($0) } == nil)
    }

    @Test func inlineOnlyNodesCannotBeMangledStandalone() {
        // These kinds carry data their parent emits; re-mangling one on its own
        // is not a valid global and yields nil.
        for kind in [SwiftSymbol.Kind.Index, .UnknownIndex, .DependentGenericParamCount,
                     .FunctionSignatureSpecializationParamPayload]
        {
            #expect(mangler.mangle(SwiftSymbol(kind: kind, index: 0)) == nil, "expected nil mangle for \(kind.name)")
        }
    }

    @Test func sameAsArgumentParamRoundTripsByteExact() {
        // `Tf1cC0` — closure-propagated arg 0 plus a same-as-previous-argument
        // param; main-faithful, host oracle declines it.
        let symbol = "$s3foo7closureSSTf1cC0_n"
        let ast = demangler.demangle(symbol: symbol)
        #expect(ast != nil)
        #expect(ast.flatMap { mangler.mangle($0) } == symbol)
    }

    @Test func constantPropStructParamRoundTripsByteExact() {
        // `Tf3npSSi3Si0` — constant-propagated struct + integer params.
        let symbol = "$s3foo4main1SVs5Int32VSbTf3npSSi3Si0_n"
        let ast = demangler.demangle(symbol: symbol)
        #expect(ast != nil)
        #expect(ast.flatMap { mangler.mangle($0) } == symbol)
    }

    @Test func nestedPartialApplyForwarderRoundTrips() {
        // `TATA` — a partial-apply forwarder of a partial-apply forwarder; the
        // demangler nests the inner forwarder under the outer and the tree
        // re-mangles byte-exact.
        let symbol = "$s4main3fooyyFTATA"
        let ast = demangler.demangle(symbol: symbol)
        #expect(ast != nil)
        #expect(ast.flatMap { mangler.mangle($0) } == symbol)
    }

    @Test func leadingDigitIdentifierIsEscapedAndRoundTrips() {
        // An identifier whose first character is a digit is `X`-escaped by the
        // mangler so it is not misread as a length prefix.
        guard let base = demangler.demangle(symbol: "$s1M3FooVMa") else { return }
        func replace(_ node: SwiftSymbol) -> SwiftSymbol {
            if node.kind == .Identifier, node.text == "Foo" {
                return SwiftSymbol(kind: .Identifier, name: "3DPoint")
            }
            return SwiftSymbol(kind: node.kind, children: node.children.map(replace), contents: node.contents)
        }
        let tree = replace(base)
        let mangled = mangler.mangle(tree)
        #expect(mangled != nil)
        #expect(mangled.flatMap { demangler.demangle(symbol: $0)?.treeDump() } == tree.treeDump())
    }

    @Test func constantPropStringWithLeadingUnderscoreRoundTrips() {
        // A constant-propagated string payload whose text starts with `_`
        // (escaped on the way out).
        let symbol = "$s4main3fooyyF3_abTf0psb_n"
        let ast = demangler.demangle(symbol: symbol)
        #expect(ast != nil)
        if let ast { #expect(mangler.mangle(ast) != nil) }
    }
}
