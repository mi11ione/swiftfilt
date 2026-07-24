// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The remangler's failure-propagation branches at scale: for a shape-diverse corpus slice, every node position is replaced with an unmanglable node and the tree re-mangled, exercising the `guard mangle(child) else { return false }` paths through every `mangleXXX` — the corrupted re-mangle must be deterministic and never trap.
@Suite("Swift mangler corrupted-subtree resilience")
struct SwiftManglerCorruptedTreeTests {
    private func paths(_ node: SwiftSymbol, _ prefix: [Int] = [], into out: inout [[Int]]) {
        out.append(prefix)
        for (i, child) in node.children.enumerated() {
            paths(child, prefix + [i], into: &out)
        }
    }

    private func replacing(_ node: SwiftSymbol, at path: ArraySlice<Int>, with replacement: SwiftSymbol) -> SwiftSymbol {
        guard let i = path.first, i < node.children.count else { return path.isEmpty ? replacement : node }
        var copy = node
        copy.children[i] = replacing(node.children[i], at: path.dropFirst(), with: replacement)
        return copy
    }

    @Test func corruptingEveryCorpusSubtreeReMangleIsDeterministicAndSafe() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        // A spread across the corpus (every 27th row) gives shape diversity
        // across the exotic remangler functions without combinatorial blow-up.
        let sampled = rows.enumerated().filter { $0.offset % 27 == 0 }.map(\.element.mangled)
        let failures = await onLargeStack { () -> [String] in
            let demangler = SwiftDemangler(); let mangler = SwiftMangler()
            let unmanglable = SwiftSymbol(kind: .Index, index: 0)
            var fails: [String] = []
            for symbol in sampled {
                guard let ast = demangler.demangle(symbol: symbol) else { continue }
                var nodePaths: [[Int]] = []
                paths(ast, into: &nodePaths)
                // Bound per-symbol work: huge nested-generic tails have thousands
                // of positions and add no new branches past the first hundreds.
                guard nodePaths.count <= 400 else { continue }
                for path in nodePaths {
                    let corrupted = replacing(ast, at: path[...], with: unmanglable)
                    if mangler.mangle(corrupted) != mangler.mangle(corrupted) {
                        fails.append("\(symbol) @ \(path)")
                    }
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(failures.prefix(10).joined(separator: "; "))")
    }

    // MARK: Pinned outcomes for under-populated shells

    private func global(_ child: SwiftSymbol) -> SwiftSymbol {
        SwiftSymbol(kind: .Global, child: child)
    }

    @Test func underPopulatedShellsManglePinnedForms() {
        // Deterministic outputs for shells missing their operands: entry
        // points emit their bare operators; descriptor and conformance
        // refs emit their heads; the opaque index defaults to zero.
        let mangler = SwiftMangler()
        #expect(mangler.mangle(global(SwiftSymbol(kind: .Allocator))) == "$sfC")
        #expect(mangler.mangle(global(SwiftSymbol(kind: .Deallocator))) == "$sfD")
        #expect(mangler.mangle(global(SwiftSymbol(kind: .IsolatedDeallocator))) == "$sfZ")
        #expect(mangler.mangle(global(SwiftSymbol(kind: .ProtocolDescriptor))) == "$sMp")
        #expect(mangler.mangle(global(SwiftSymbol(kind: .ProtocolConformanceRefInTypeModule))) == "$sHP")
        #expect(mangler.mangle(global(SwiftSymbol(kind: .ProtocolConformanceRefInProtocolModule))) == "$sHp")
        #expect(mangler.mangle(global(SwiftSymbol(kind: .OpaqueReturnType, index: 3))) == "$sQr")
        #expect(mangler.mangle(global(SwiftSymbol(kind: .OpaqueReturnType,
                                                  child: SwiftSymbol(kind: .OpaqueReturnTypeIndex)))) == "$sQR_")
        #expect(mangler.mangle(global(SwiftSymbol(kind: .`Type`,
                                                  child: SwiftSymbol(kind: .ConstrainedExistential)))) == "$sXP")
        // A bare `Type` root and a childless accessor cannot mangle.
        #expect(mangler.mangle(SwiftSymbol(kind: .`Type`)) == nil)
        #expect(mangler.mangle(global(SwiftSymbol(kind: .Getter))) == nil)
        #expect(mangler.mangle(global(SwiftSymbol(kind: .`Type`,
                                                  child: SwiftSymbol(kind: .SugaredOptional)))) == nil)
    }

    @Test func bogusImplConventionTextsRefuseToMangle() {
        // The impl-function convention tables are total over the grammar's
        // vocabulary; constructed nodes carrying unknown (or missing) texts
        // make the mangle nil, never a guess.
        let mangler = SwiftMangler()
        func implType(_ children: [SwiftSymbol]) -> SwiftSymbol {
            global(SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .ImplFunctionType, children: children)))
        }
        let callee = SwiftSymbol(kind: .ImplConvention, name: "@callee_guaranteed")
        #expect(mangler.mangle(implType([SwiftSymbol(kind: .ImplConvention, name: "@bogus")])) == nil)
        #expect(mangler.mangle(implType([callee,
                                         SwiftSymbol(kind: .ImplFunctionConvention,
                                                     child: SwiftSymbol(kind: .ImplFunctionConventionName, name: "bogus"))])) == nil)
        #expect(mangler.mangle(implType([callee,
                                         SwiftSymbol(kind: .ImplFunctionConvention,
                                                     child: SwiftSymbol(kind: .ImplFunctionConventionName))])) == nil)
        #expect(mangler.mangle(implType([callee, SwiftSymbol(kind: .ImplCoroutineKind, name: "bogus")])) == nil)
        #expect(mangler.mangle(implType([callee, SwiftSymbol(kind: .ImplFunctionAttribute, name: "@bogus")])) == nil)
        let intType = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Structure, children: [
            SwiftSymbol(kind: .Module, name: "Swift"),
            SwiftSymbol(kind: .Identifier, name: "Int"),
        ]))
        let bogusDiff = SwiftSymbol(kind: .ImplParameter, children: [
            SwiftSymbol(kind: .ImplConvention, name: "@in"),
            SwiftSymbol(kind: .ImplParameterResultDifferentiability, name: "bogus"),
            intType,
        ])
        #expect(mangler.mangle(implType([callee, bogusDiff])) == nil)
        // A convention shell with exactly one child mangles its head form.
        let bare = SwiftSymbol(kind: .ImplFunctionConvention,
                               child: SwiftSymbol(kind: .ImplFunctionConventionName, name: "c"))
        #expect(mangler.mangle(implType([callee, bare])) == "$sIgC_")
    }

    @Test func specializationAttributeShapesManglePinnedForms() {
        // Trailing `IsSerialized` (the parser emits it leading) drops the
        // pass id it cannot reorder: the mangle is nil rather than a
        // misordered attribute.
        let mangler = SwiftMangler()
        let spec = SwiftSymbol(kind: .GenericSpecialization, children: [
            SwiftSymbol(kind: .SpecializationPassID, index: 5),
            SwiftSymbol(kind: .IsSerialized),
        ])
        let fn = SwiftSymbol(kind: .Function, children: [
            SwiftSymbol(kind: .Module, name: "m"),
            SwiftSymbol(kind: .Identifier, name: "f"),
            SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .FunctionType, children: [
                SwiftSymbol(kind: .ArgumentTuple, child: SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Tuple))),
                SwiftSymbol(kind: .ReturnType, child: SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Tuple))),
            ])),
        ])
        #expect(mangler.mangle(SwiftSymbol(kind: .Global, children: [spec, fn])) == nil)
        // An indexless generic-param count mangles as the zero form.
        let sig = SwiftSymbol(kind: .DependentGenericSignature,
                              child: SwiftSymbol(kind: .DependentGenericParamCount))
        let intType = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Structure, children: [
            SwiftSymbol(kind: .Module, name: "Swift"),
            SwiftSymbol(kind: .Identifier, name: "Int"),
        ]))
        let dep = SwiftSymbol(kind: .`Type`,
                              child: SwiftSymbol(kind: .DependentGenericType, children: [sig, intType]))
        let entity = SwiftSymbol(kind: .Function, children: [
            SwiftSymbol(kind: .Module, name: "m"),
            SwiftSymbol(kind: .Identifier, name: "f"),
            dep,
        ])
        #expect(mangler.mangle(global(entity)) == "$s1m1f3IntsrzlF")
    }

    @Test func runawayNestingRefusesAtTheDepthGuard() async {
        // 1,200 nested metatype shells: the mangle bails at the depth
        // guard rather than recursing without bound. Construction and
        // teardown of the chain recurse per level too, so the whole case
        // lives on the big stack.
        await onLargeStack {
            let mangler = SwiftMangler()
            var deep = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Structure, children: [
                SwiftSymbol(kind: .Module, name: "Swift"),
                SwiftSymbol(kind: .Identifier, name: "Int"),
            ]))
            for _ in 0 ..< 1200 {
                deep = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Metatype, child: deep))
            }
            #expect(mangler.mangle(SwiftSymbol(kind: .Global,
                                               child: SwiftSymbol(kind: .TypeMangling, child: deep))) == nil)
        }
    }
}
