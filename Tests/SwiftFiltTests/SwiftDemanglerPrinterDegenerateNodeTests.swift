// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The printer on minimal (payload-less) nodes — the defensive `?? default` fallbacks for
/// absent text/index payloads. These degenerate trees never arise from a valid mangled name,
/// but the printer must render them deterministically (never trap).
@Suite("Swift demangler degenerate-node printing")
struct SwiftDemanglerPrinterDegenerateNodeTests {
    private let printer = SwiftDemanglerPrinter()

    private func full(_ kind: SwiftSymbol.Kind) -> String {
        printer.print(SwiftSymbol(kind: kind), style: .full)
    }

    @Test func payloadLessTextNodesRenderEmptyText() {
        #expect(full(.Module) == "")
        #expect(full(.ArgumentTuple) == "")
        #expect(full(.Identifier) == "")
        #expect(full(.BuiltinTypeName) == "")
        #expect(full(.ClangType) == "")
        #expect(full(.MetatypeRepresentation) == "")
        #expect(full(.ImplConvention) == "")
        #expect(full(.ImplFunctionAttribute) == "")
    }

    @Test func payloadLessIndexNodesRenderZero() {
        #expect(full(.Index) == "0")
        #expect(full(.Number) == "0")
        #expect(full(.SpecializationPassID) == "0")
    }

    @Test func operatorNamesRenderWithMissingText() {
        #expect(full(.InfixOperator) == " infix")
        #expect(full(.PrefixOperator) == " prefix")
        #expect(full(.PostfixOperator) == " postfix")
        #expect(full(.TupleElementName) == ": ")
    }

    @Test func outlinedNodesDefaultMissingPayload() {
        #expect(full(.OutlinedBridgedMethod) == "outlined bridged method () of ")
        #expect(full(.OutlinedVariable) == "outlined variable #0 of ")
        #expect(full(.OutlinedReadOnlyObject) == "outlined read-only object #0 of ")
        #expect(full(.DroppedArgument) == "param0-removed")
    }

    @Test func symbolicReferenceNodesDefaultMissingIndex() {
        #expect(full(.TypeSymbolicReference) == "type symbolic reference 0x0")
        #expect(full(.OpaqueTypeDescriptorSymbolicReference) == "opaque type symbolic reference 0x0")
        #expect(full(.ProtocolSymbolicReference) == "protocol symbolic reference 0x0")
    }

    @Test func symbolicReferenceShapeAndMiscMarkers() {
        func hex(_ kind: SwiftSymbol.Kind) -> String {
            printer.print(SwiftSymbol(kind: kind, index: 0x10), style: .full)
        }
        #expect(hex(.UniqueExtendedExistentialTypeShapeSymbolicReference) == "unique existential shape symbolic reference 0x10")
        #expect(hex(.NonUniqueExtendedExistentialTypeShapeSymbolicReference) == "non-unique existential shape symbolic reference 0x10")
        #expect(hex(.ObjectiveCProtocolSymbolicReference) == "objective-c protocol symbolic reference 0x10")
        #expect(full(.HasSymbolQuery) == "#_hasSymbol query for ")
        #expect(full(.CoroFunctionPointer) == "coro function pointer to ")
        #expect(full(.DefaultOverride) == "default override of ")
        #expect(printer.print(SwiftSymbol(kind: .Integer, index: 7), style: .full) == "7")
        #expect(printer.print(SwiftSymbol(kind: .NegativeInteger, index: 7), style: .full) == "7")
    }

    @Test func outOfRangeValueWitnessCodeRendersEmptyName() {
        // A ValueWitness whose index is past the known witness-kind table:
        // `ValueWitnessKinds.name(forIndex:)` returns nil → empty witness name.
        let node = SwiftSymbol(kind: .ValueWitness, children: [
            SwiftSymbol(kind: .Index, index: 99),
            SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Structure, children: [
                SwiftSymbol(kind: .Module, name: "M"),
                SwiftSymbol(kind: .Identifier, name: "T"),
            ])),
        ])
        #expect(printer.print(node, style: .full) == " value witness for M.T")
    }

    // MARK: Under-populated entity and attribute shells

    private func global(_ child: SwiftSymbol) -> SwiftSymbol {
        SwiftSymbol(kind: .Global, child: child)
    }

    private let intType = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Structure, children: [
        SwiftSymbol(kind: .Module, name: "Swift"),
        SwiftSymbol(kind: .Identifier, name: "Int"),
    ]))

    private let unitFunctionType = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .FunctionType, children: [
        SwiftSymbol(kind: .ArgumentTuple, child: SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Tuple))),
        SwiftSymbol(kind: .ReturnType, child: SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Tuple))),
    ]))

    @Test func childlessEntryPointEntitiesFallBackToPlainSpellings() {
        // A childless allocator has no type to test for class-ness: the
        // `__allocating_init` spelling needs a class, so nothing prints;
        // the deallocating flavors keep the plain `deinit`.
        #expect(printer.print(global(SwiftSymbol(kind: .Allocator)), style: .full) == "")
        #expect(printer.print(global(SwiftSymbol(kind: .Deallocator)), style: .full) == "deinit")
        #expect(printer.print(global(SwiftSymbol(kind: .IsolatedDeallocator)), style: .full) == "deinit")
        #expect(printer.print(global(SwiftSymbol(kind: .Getter)), style: .full) == "")
    }

    @Test func textlessTupleLabelPrintsBareColon() {
        let tuple = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Tuple, children: [
            SwiftSymbol(kind: .TupleElement, children: [SwiftSymbol(kind: .TupleElementName), intType]),
        ]))
        #expect(printer.print(global(tuple), style: .full) == "(: Swift.Int)")
    }

    @Test func emptyModuleNameHidesTheQualification() {
        // `printContext` hides a module whose name is empty (the
        // hiding-current-module comparison) — the entity prints bare.
        let fn = SwiftSymbol(kind: .Function, children: [
            SwiftSymbol(kind: .Module, name: ""),
            SwiftSymbol(kind: .Identifier, name: "foo"),
            unitFunctionType,
        ])
        #expect(printer.print(global(fn), style: .full) == "foo() -> ()")
    }

    @Test func textlessModuleContextAlsoHidesTheQualification() {
        // A payload-free `.Module` context takes the same hidden-module arm as an
        // empty-named one: `printContext`'s probes read `text ?? ""`, so no-text and
        // empty-text modules behave identically — the entity prints bare.
        let fn = SwiftSymbol(kind: .Function, children: [
            SwiftSymbol(kind: .Module),
            SwiftSymbol(kind: .Identifier, name: "foo"),
            unitFunctionType,
        ])
        #expect(printer.print(global(fn), style: .full) == "foo() -> ()")
    }

    @Test func payloadBearingOpaqueReturnShapesPrintSome() {
        #expect(printer.print(global(SwiftSymbol(kind: .OpaqueReturnType, index: 3)), style: .full) == "some")
        let withIndexChild = SwiftSymbol(kind: .OpaqueReturnType,
                                         child: SwiftSymbol(kind: .OpaqueReturnTypeIndex))
        #expect(printer.print(global(withIndexChild), style: .full) == "some")
    }

    @Test func trailingIsSerializedSpecializationPrintsMarkerOnly() {
        // Constructed with `IsSerialized` in trailing position (the parser
        // puts it first): the printer still renders the marker list.
        let spec = SwiftSymbol(kind: .GenericSpecialization, children: [
            SwiftSymbol(kind: .SpecializationPassID, index: 5),
            SwiftSymbol(kind: .IsSerialized),
        ])
        let fn = SwiftSymbol(kind: .Function, children: [
            SwiftSymbol(kind: .Module, name: "m"),
            SwiftSymbol(kind: .Identifier, name: "f"),
            unitFunctionType,
        ])
        let sym = SwiftSymbol(kind: .Global, children: [spec, fn])
        #expect(printer.print(sym, style: .full) == "generic specialization <serialized> of m.f() -> ()")
    }

    @Test func childlessDescriptorAndConformanceRefsKeepTheirHeadings() {
        #expect(printer.print(global(SwiftSymbol(kind: .ProtocolDescriptor)), style: .full)
            == "protocol descriptor for ")
        #expect(printer.print(global(SwiftSymbol(kind: .ProtocolConformanceRefInTypeModule)), style: .full)
            == "protocol conformance ref (type's module) ")
        #expect(printer.print(global(SwiftSymbol(kind: .ProtocolConformanceRefInProtocolModule)), style: .full)
            == "protocol conformance ref (protocol's module) ")
        #expect(printer.print(global(SwiftSymbol(kind: .`Type`,
                                                 child: SwiftSymbol(kind: .ConstrainedExistential))), style: .full)
            == "any <>")
    }

    @Test func degenerateImplFunctionShellsPrintTheirPieces() {
        func implType(_ children: [SwiftSymbol]) -> SwiftSymbol {
            global(SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .ImplFunctionType, children: children)))
        }
        let callee = SwiftSymbol(kind: .ImplConvention, name: "@callee_guaranteed")
        // One-child function convention (no Clang type attached).
        let conv = SwiftSymbol(kind: .ImplFunctionConvention,
                               child: SwiftSymbol(kind: .ImplFunctionConventionName, name: "c"))
        #expect(printer.print(implType([callee, conv]), style: .full)
            == "@callee_guaranteed @convention(c) () -> ()")
        // Unknown / textless pieces still render deterministically.
        #expect(printer.print(implType([SwiftSymbol(kind: .ImplConvention, name: "@bogus")]), style: .full)
            == "@bogus () -> ()")
        let textlessName = SwiftSymbol(kind: .ImplFunctionConvention,
                                       child: SwiftSymbol(kind: .ImplFunctionConventionName))
        #expect(printer.print(implType([callee, textlessName]), style: .full)
            == "@callee_guaranteed @convention() () -> ()")
        #expect(printer.print(implType([callee, SwiftSymbol(kind: .ImplCoroutineKind, name: "bogus")]), style: .full)
            == "@callee_guaranteed @bogus () -> ()")
        let bogusDiffParam = SwiftSymbol(kind: .ImplParameter, children: [
            SwiftSymbol(kind: .ImplConvention, name: "@in"),
            SwiftSymbol(kind: .ImplParameterResultDifferentiability, name: "bogus"),
            intType,
        ])
        #expect(printer.print(implType([callee, bogusDiffParam]), style: .full)
            == "@callee_guaranteed (@in bogus Swift.Int) -> ()")
    }

    @Test func indexlessGenericParamCountPrintsEmptyAngles() {
        let sig = SwiftSymbol(kind: .DependentGenericSignature,
                              child: SwiftSymbol(kind: .DependentGenericParamCount))
        let dep = SwiftSymbol(kind: .`Type`,
                              child: SwiftSymbol(kind: .DependentGenericType, children: [sig, intType]))
        let entity = SwiftSymbol(kind: .Function, children: [
            SwiftSymbol(kind: .Module, name: "m"),
            SwiftSymbol(kind: .Identifier, name: "f"),
            dep,
        ])
        #expect(printer.print(global(entity), style: .full) == "m.f : <> Swift.Int")
    }
}
