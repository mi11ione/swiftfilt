// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swiftfilt-parity probe <symbol>…` — the evidence gatherer: one
// symbol's complete engine-side story (every rendering, the node tree,
// the classify markers, the remangling and its self-consistency verdict)
// side by side with the live oracle's. Every KNOWN-DEVIATIONS entry's
// verbatim reproducer is checked with this.

import Foundation
import SwiftFilt

public func runProbeCommand(_ args: [String]) async -> Int32 {
    guard !args.isEmpty else {
        eprint("probe: pass one or more mangled symbols")
        return 2
    }
    let oracle = await Oracle.locate()
    if let oracle {
        await print("[probe] oracle: \(oracle) [\(Oracle.identity(oracle))]")
    } else {
        print("[probe] oracle: NONE (engine side only)")
    }
    let oracleOutputs: Oracle.BatchOutputs? = if let oracle { await Oracle.fetch(args, oracle: oracle, modes: .all, timeout: 120) } else { nil }
    if oracle != nil, oracleOutputs == nil {
        eprint("probe: oracle invocation failed")
        return 2
    }

    return await onLargeStack {
        let printer = SwiftDemanglerPrinter()
        let demangler = SwiftDemangler()
        let mangler = SwiftMangler()
        for (idx, mangled) in args.enumerated() {
            print("=== \(mangled)")
            guard let symbol = DemangledSymbol(mangled) else {
                print("swiftfilt: DECLINED (\(ProductFailure.reason(mangled)))")
                if let outputs = oracleOutputs {
                    let line = outputs.compact[idx]
                    print("oracle .full: \(oracleDeclined(line, mangled: mangled) ? "DECLINED (echo)" : line)")
                }
                continue
            }
            let ast = symbol.symbol
            print("swiftfilt .full:       \(printer.print(ast, style: .full))")
            print("swiftfilt .simplified: \(printer.print(ast, style: .simplified))")
            print("swiftfilt .qualified:  \(printer.print(ast, style: .qualified))")
            print("swiftfilt .unqualified:\(printer.print(ast, style: .unqualified))")
            // Markers are computed on the underscore-stripped name, exactly
            // as `swift-demangle` strips before classifying.
            let classifyName = mangled.hasPrefix("__") ? String(mangled.dropFirst()) : mangled
            print("swiftfilt classify:    \(printer.classify(classifyName, demangled: ast))")
            if let remangled = mangler.mangle(ast) {
                let canonical = mangled.hasPrefix("_") ? String(mangled.dropFirst()) : mangled
                let verdict = if remangled == mangled || remangled == canonical {
                    "byte-exact"
                } else if demangler.demangle(symbol: remangled)?.treeDump() == ast.treeDump() {
                    "canonicalized (re-demangles to the identical tree)"
                } else {
                    "NOT SELF-CONSISTENT"
                }
                print("swiftfilt remangle:    \(remangled)  [\(verdict)]")
            } else {
                print("swiftfilt remangle:    <nil>\(treeContainsSuffix(ast) ? "  [tree carries an unmangled Suffix]" : "")")
            }
            print("swiftfilt tree:\n\(ast.treeDump().trimmedTrailingNewlines())")
            if let outputs = oracleOutputs {
                let full = outputs.compact[idx]
                print("oracle .full:       \(oracleDeclined(full, mangled: mangled) ? "DECLINED (echo)" : full)")
                print("oracle .simplified: \(outputs.simplified[idx])")
                print("oracle .qualified:  \(outputs.noSugar[idx])")
                print("oracle classify:    \(leadingBraceTokens(outputs.classify[idx]))")
                let tree = outputs.tree[idx].trimmedTrailingNewlines()
                print("oracle tree:\n\(tree.isEmpty ? "<none>" : tree)")
            }
        }
        return 0
    }
}

/// The product decline taxonomy, spelled for probe output. The typed
/// throw means the catch binds a `DemangleError` directly; a success here
/// (possible only in a race with the guard above) reads as the one decline
/// cause `demangle(validating:)` cannot see.
private enum ProductFailure {
    static func reason(_ mangled: String) -> String {
        do {
            _ = try demangle(validating: mangled)
            return "renders empty"
        } catch {
            return "\(error)"
        }
    }
}
