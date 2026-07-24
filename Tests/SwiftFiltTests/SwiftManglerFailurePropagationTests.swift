// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The remangler's `guard mangle(child) else { return false }` arms across many node shapes: each diverse real symbol is demangled, then every single-node-corrupted variant (one descendant replaced by an unmanglable `Index`) is re-mangled — the remangler is pure, so the anchor is that every corrupted re-mangle is deterministic.
@Suite("Swift mangler failure propagation")
struct SwiftManglerFailurePropagationTests {
    private let demangler = SwiftDemangler()
    private let mangler = SwiftMangler()

    /// Diverse round-tripping symbols: functions, generics, witnesses, SIL impl types, thunks, specializations, metatypes, existentials, accessors, conformances, outlined value witnesses.
    private static let symbols = [
        "$s4main3fooyySi_SStF", "$sSaySiGD", "$sSDyS2iGD", "$s4main3FooVMa",
        "$s4main8MyStructVAA1PA2aDP3fooyyFTW", "$sSiIgi_D",
        "$s4main3fooyyFTc", "$s4main3fooyyFTf0i_n", "$s4main3fooyyFSi_Tg5",
        "$sSiXMt", "$sypRi_s_XPD", "$s4main3FooC3barSivg", "$sSiWOy",
        "$s4main3fooyyxRlzUlF", "$sxq_Ifgnr_D", "$s4main3FooV3barSivx",
        "$sSiSiIgxzo_D", "$s4main3fooyyx_q_tRhzr0_lF",
    ]

    private func allPaths(_ node: SwiftSymbol, _ prefix: [Int] = []) -> [[Int]] {
        var paths = [prefix]
        for (i, child) in node.children.enumerated() {
            paths += allPaths(child, prefix + [i])
        }
        return paths
    }

    private func replacing(_ node: SwiftSymbol, at path: ArraySlice<Int>, with replacement: SwiftSymbol) -> SwiftSymbol {
        guard let i = path.first else { return replacement }
        guard i < node.children.count else { return node }
        var copy = node
        copy.children[i] = replacing(node.children[i], at: path.dropFirst(), with: replacement)
        return copy
    }

    @Test func reMangleOfCorruptedSubtreesIsDeterministic() {
        let unmanglable = SwiftSymbol(kind: .Index, index: 0)
        for symbol in Self.symbols {
            let parsed = demangler.demangle(symbol: symbol)
            #expect(parsed != nil, "fixture symbol no longer demangles: \(symbol)")
            guard let ast = parsed else { continue }
            for path in allPaths(ast) {
                let corrupted = replacing(ast, at: path[...], with: unmanglable)
                #expect(mangler.mangle(corrupted) == mangler.mangle(corrupted),
                        "non-deterministic mangle for \(symbol) corrupted at \(path)")
            }
        }
    }
}
