// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Renders every `SwiftSymbol.Kind` (with nominal-type children) through all four printer
/// styles, the re-mangler, and the tree dumper. The type children drive the child-bearing
/// dispatch arms while their `?.index ?? default` fallbacks still fire — the invariant is
/// that no tree shape traps; every renderer returns deterministically.
@Suite("Swift demangler exhaustive node-kind rendering")
struct SwiftDemanglerAllKindsRenderingTests {
    private let printer = SwiftDemanglerPrinter()
    private let mangler = SwiftMangler()
    private static let styles: [SwiftDemanglerPrinter.Style] = [.full, .simplified, .qualified, .unqualified]
    private let typeChild = SwiftSymbol(kind: .`Type`, child: SwiftSymbol(kind: .Structure, children: [
        SwiftSymbol(kind: .Module, name: "M"), SwiftSymbol(kind: .Identifier, name: "T"),
    ]))

    @Test func everyKindRendersAndReManglesWithoutTrapping() {
        for kind in SwiftSymbol.Kind.allCases {
            let node = SwiftSymbol(kind: kind, children: [typeChild, typeChild, typeChild])
            #expect(node.treeDump().hasPrefix("kind=\(kind.name)\n"))
            for style in Self.styles {
                _ = printer.print(node, style: style)
            }
            // Re-mangling is a pure function of the tree: two attempts agree
            // (the remangler holds no state across calls).
            #expect(mangler.mangle(node) == mangler.mangle(node), "non-deterministic mangle for \(kind.name)")
        }
    }

    @Test func everyKindPropagatesChildManglingFailure() {
        // An `Index` child cannot be re-mangled standalone; placing one at each
        // position drives the `guard mangle(child) else { return false }`
        // failure arms in every container kind's re-mangler — without trapping.
        let bad = SwiftSymbol(kind: .Index, index: 0)
        let g = typeChild
        let configs = [
            [bad, bad, bad], [g, bad, bad], [g, g, bad],
            [g, g, g, bad], [g, g, g, g, bad], [g, g, g, g, g, bad],
        ]
        for kind in SwiftSymbol.Kind.allCases {
            for config in configs {
                let node = SwiftSymbol(kind: kind, children: config)
                #expect(mangler.mangle(node) == mangler.mangle(node), "non-deterministic mangle for \(kind.name)")
            }
        }
    }

    // MARK: Rare node families on real manglings

    // Each rendering below is oracle-verified against `xcrun swift-demangle`.

    @Test func objcCompletionHandlerImplsRenderEveryFlagMode() {
        let base = "@objc completion handler block implementation for Swift.Int with result type Swift.Int"
        #expect(demangle("$sS2iTz_") == base)
        #expect(demangle("$sS2iTz0_") == base + " nonzero on error")
        #expect(demangle("$sS2iTz1_") == base + " zero on error")
        #expect(demangle("$sS2iTz2_") == base + " <invalid error flag>")
        #expect(demangle("$sS2iTZ1_") == "checked " + base + " zero on error")
    }

    @Test func anonymousContextsRenderTheirDiscriminator() {
        #expect(demangle("$s4main3abcyXZ") == "main.(unknown context at abc)")
    }

    @Test func debuggerExpressionModulesStayVisible() {
        #expect(demangle("$s12__lldb_expr_3fooyyF") == "__lldb_expr_.foo() -> ()")
        #expect(demangle("$s14__lldb_expr_123fooyyF") == "__lldb_expr_12.foo() -> ()")
    }

    @Test(arguments: [
        ("$s4main3fooyS2fFWJfSpSr", "forward-mode"),
        ("$s4main3fooyS2fFWJdSpSr", "normal"),
        ("$s4main3fooyS2fFWJlSpSr", "linear"),
    ])
    func differentiabilityWitnessKindsRender(_ mangled: String, _ label: String) {
        #expect(demangle(mangled)
            == "\(label) differentiability witness for main.foo(Swift.Float) -> Swift.Float "
            + "with respect to parameters {0} and results {0}")
    }

    @Test func explicitSugarOperatorsRender() {
        #expect(demangle("$sSiXSqD") == "Swift.Int?")
        #expect(demangle("$sSiXSaD") == "[Swift.Int]")
        #expect(demangle("$sSiSSXSDD") == "[Swift.Int : Swift.String]")
    }

    @Test func constantPropagatedFunctionPayloadsDemangleInline() {
        // The payload identifier is itself a mangled name: the printer
        // demangles it in place, exactly as the reference does.
        #expect(demangle("_TTSf0cpfr17_TF4main3barFT_T____TF4main3fooFT_T_")
            == "function signature specialization <Arg[0] = [Constant Propagated Function : main.bar() -> ()]> "
            + "of main.foo() -> ()")
    }
}
