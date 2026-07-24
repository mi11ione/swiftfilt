// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The demangler's incomplete-input rejection at scale: every byte prefix of a shape-diverse corpus slice is demangled. Truncations land mid-operator/index/identifier, exercising the `peekChar() == 0` / `pos < count` / null-propagating guards; each must demangle deterministically and never trap.
@Suite("Swift demangler truncated-input resilience")
struct SwiftDemanglerTruncationSweepTests {
    @Test func everyPrefixOfCorpusSymbolsDemanglesDeterministically() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        // A spread across the corpus (every 23rd row), capped in length so the
        // prefix count per symbol stays bounded.
        let sampled = rows.enumerated()
            .filter { $0.offset % 23 == 0 && $0.element.mangled.utf8.count <= 90 }
            .map(\.element.mangled)
        let failures = await onLargeStack { () -> [String] in
            let demangler = SwiftDemangler()
            var fails: [String] = []
            for symbol in sampled {
                let bytes = Array(symbol.utf8)
                // The full symbol must demangle (fixture sanity).
                if demangler.demangle(symbol: symbol) == nil { fails.append("full nil: \(symbol)") }
                for end in 1 ..< bytes.count {
                    let prefix = Array(bytes[0 ..< end])
                    // Deterministic: the same truncation parses identically twice.
                    if demangler.demangle(symbolBytes: prefix)?.treeDump()
                        != demangler.demangle(symbolBytes: prefix)?.treeDump()
                    {
                        fails.append("\(symbol)[0..<\(end)]")
                    }
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(failures.prefix(10).joined(separator: "; "))")
    }
}
