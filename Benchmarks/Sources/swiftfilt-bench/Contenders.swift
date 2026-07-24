// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The benchmark card's module-import contenders: CwlDemangle (the
// pure-Swift port the ecosystem vendors into crash SDKs — a bench-only
// SPM dependency, never shipped) and `Runtime.demangle` (SE-0498, the
// official Swift 6.4 stdlib API). This file deliberately does NOT
// import SwiftFilt: CwlDemangle declares its own `SwiftSymbol`, and
// keeping the modules in separate files keeps every reference
// unambiguous. Each contender runs its documented best case; the exact
// configuration strings feed the card's fairness notes.

import CwlDemangle
#if canImport(Runtime)
    import Runtime
#endif

/// CwlDemangle, pinned by revision (the repository publishes no version
/// tags). Best case: the package's primary public entry point,
/// `parseMangledSwiftSymbol(_:)`, printed with `.default` PLUS
/// `.synthesizeSugarOnTypes` — the tool's own default renders sugar
/// (`T?`, `[T]`) and CwlDemangle's `.default` omits that one flag, so
/// adding it is the configuration that maximizes its byte-agreement
/// (measured: wrong rows drop 1,993 → 196). A thrown parse error is a
/// decline.
enum CwlContender {
    static let pin = "mattgallagher/CwlDemangle @ 6bfc351 (repo HEAD, 2025-03-31; no version tags)"
    static let configuration = "parseMangledSwiftSymbol(_:).print(using: .default + .synthesizeSugarOnTypes) — its best-scoring rendering vs the tool default"

    static func demangle(_ mangled: String) -> String? {
        guard let symbol = try? parseMangledSwiftSymbol(mangled) else { return nil }
        // Computed per call: SymbolPrintOptions predates Sendable, so a
        // cached static would trip strict concurrency; the union is two
        // integer ORs.
        return symbol.print(using: SymbolPrintOptions.default.union(.synthesizeSugarOnTypes))
    }
}

/// `Runtime.demangle` (SE-0498). Compile-gated on the toolchain carrying
/// the `Runtime` module, run-gated on its `@available(macOS 27)` floor;
/// `unavailableReason` is non-nil — with the exact reason — wherever it
/// cannot run, so its absence from a report is never silent.
enum RuntimeAPIContender {
    static let configuration = "Runtime.demangle(_:) — one call per symbol; a thrown error is a decline"

    #if canImport(Runtime)
        static var unavailableReason: String? {
            if #available(macOS 27.0, *) { return nil }
            return "not benchmarkable on this host: Runtime.demangle is @available(macOS 27.0) and this OS is older"
        }

        static func demangle(_ mangled: String) -> String? {
            if #available(macOS 27.0, *) {
                return try? Runtime.demangle(mangled)
            }
            return nil
        }
    #else
        static var unavailableReason: String? {
            "not benchmarkable on this host: the toolchain has no Runtime module (SE-0498 needs Swift 6.4+)"
        }

        static func demangle(_: String) -> String? {
            nil
        }
    #endif
}
