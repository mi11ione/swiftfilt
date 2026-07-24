// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Printer dispatch arms for node kinds real symbols only embed (consumed inline, resolver-produced, or suppressed) and so aren't reached by the corpus walk — a hand-built node of each kind drives the arm directly against the reference's marker text.
@Suite("Swift demangler printer dispatch arms")
struct SwiftDemanglerPrinterDispatchArmTests {
    private let printer = SwiftDemanglerPrinter()
    /// `M.T` as a `Type` node, the generic operand for the cases below.
    private let mt = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Structure, children: [
        SwiftSymbol(kind: .Module, name: "M"),
        SwiftSymbol(kind: .Identifier, name: "T"),
    ]))
    private func full(_ node: SwiftSymbol) -> String {
        printer.print(node, style: .full)
    }

    @Test func genericTypeParamDeclPrintsAsEntity() {
        let node = SwiftSymbol(kind: .GenericTypeParamDecl, children: [
            SwiftSymbol(kind: .Module, name: "M"), SwiftSymbol(kind: .Identifier, name: "T"),
        ])
        #expect(full(node) == "M.T")
    }

    @Test func retroactiveConformancePrints() {
        let node = SwiftSymbol(kind: .RetroactiveConformance, children: [SwiftSymbol(kind: .Index, index: 0), mt])
        #expect(full(node).hasPrefix("retroactive @ "))
        // The arity guard: anything other than two children renders nothing.
        #expect(full(SwiftSymbol(kind: .RetroactiveConformance, children: [mt])) == "")
    }

    @Test func implFunctionTypeSubstitutionArms() {
        let typeList = SwiftSymbol(kind: .TypeList, children: [mt])
        #expect(full(SwiftSymbol(kind: .ImplInvocationSubstitutions, children: [typeList])).hasPrefix("for <"))
        #expect(full(SwiftSymbol(kind: .ImplPatternSubstitutions, children: [mt, typeList])).hasPrefix("@substituted "))
    }

    @Test func differentiableFunctionTypeKinds() {
        func diff(_ scalar: Unicode.Scalar) -> String {
            full(SwiftSymbol(kind: .DifferentiableFunctionType, index: UInt64(scalar.value)))
        }
        #expect(diff("f") == "@differentiable(_forward) ")
        #expect(diff("r") == "@differentiable(reverse) ")
        #expect(diff("l") == "@differentiable(_linear) ")
        #expect(full(SwiftSymbol(kind: .DifferentiableFunctionType)) == "@differentiable ")
    }

    @Test func dependentProtocolConformanceArms() {
        let three = [mt, mt, SwiftSymbol(kind: .Index, index: 0)]
        #expect(full(SwiftSymbol(kind: .DependentProtocolConformanceAssociated, children: three))
            .hasPrefix("dependent associated protocol conformance "))
        #expect(full(SwiftSymbol(kind: .DependentProtocolConformanceInherited, children: three))
            .hasPrefix("dependent inherited protocol conformance "))
        #expect(full(SwiftSymbol(kind: .DependentProtocolConformanceRoot, children: three))
            .hasPrefix("dependent root protocol conformance "))
        #expect(full(SwiftSymbol(kind: .DependentProtocolConformanceOpaque, children: [mt, mt]))
            .hasPrefix("opaque result conformance "))
    }

    @Test func symbolicExtendedExistentialType() {
        let unique = SwiftSymbol(kind: .SymbolicExtendedExistentialType, children: [
            SwiftSymbol(kind: .UniqueExtendedExistentialTypeShapeSymbolicReference, index: 0x10), mt,
        ])
        #expect(full(unique) == "symbolic existential type (unique) 0x10 <M.T>")
        let nonUnique = SwiftSymbol(kind: .SymbolicExtendedExistentialType, children: [
            SwiftSymbol(kind: .NonUniqueExtendedExistentialTypeShapeSymbolicReference, index: 0x10), mt, mt,
        ])
        #expect(full(nonUnique).hasPrefix("symbolic existential type (non-unique) 0x10 <"))
    }
}
