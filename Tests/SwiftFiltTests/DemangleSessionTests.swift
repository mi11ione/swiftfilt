// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// `DemangleSession`'s contract: byte-identical to one-shot `demangle(_:style:)` for every
/// input and style, with the engine reused (not rebuilt) across calls. The risk under test is
/// cross-call state leakage (node arena, word-substitution/substitution tables, printer
/// buffer/flags) contaminating the next result. Full-corpus version: `swiftfilt-parity differential`'s session leg.
@Suite("DemangleSession (reused engine == one-shot)")
struct DemangleSessionTests {
    static let styles: [DemangleStyle] = [.full, .simplified, .qualified, .unqualified]

    /// Every fixture symbol, through one session, in every style — equal to
    /// the one-shot call (both non-`nil` and byte-equal, or both `nil`).
    @Test func everyFixtureSymbolMatchesOneShotThroughOneSession() async {
        let symbols = ArenaBackendDifferentialTests.fixtureSymbols()
        #expect(symbols.count > 4000, "fixture corpus shrank unexpectedly: \(symbols.count)")
        let failures = await onLargeStack { () -> [String] in
            let session = DemangleSession()
            var fails: [String] = []
            for name in symbols {
                for style in Self.styles {
                    let reused = session.demangle(name, style: style)
                    let oneShot = demangle(name, style: style)
                    if reused != oneShot {
                        fails.append("\(name) [\(style)]: session=`\(reused ?? "<nil>")` one-shot=`\(oneShot ?? "<nil>")`")
                    }
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(failures.prefix(10).joined(separator: "\n"))\(failures.count > 10 ? "\n…and \(failures.count - 10) more" : "")")
    }

    /// Word-substitution state is per-call: an identifier that back-references
    /// harvested words (`0aB0…`-style refs into THIS symbol's word table)
    /// demangles identically whether or not the previous call harvested a
    /// different word table (the classic cross-call contamination).
    @Test func wordSubstitutionTableDoesNotLeakAcrossCalls() {
        // Real corpus symbol whose `0aB0`/`0aC0` identifiers back-reference
        // the words harvested from `_SwiftData_SwiftUI` earlier in the name.
        let wordy = "$s011_SwiftData_A2UI5QueryV_11transactionACyxSayxGG0aB015FetchDescriptorVyxG_0aC011TransactionVSgtcAERs_rlufC"
        let plain = "$s4main3fooyyF"
        let session = DemangleSession()
        let freshWordy = demangle(wordy)
        let freshPlain = demangle(plain)
        // Interleave so each call runs against the other's leftover state.
        #expect(session.demangle(plain) == freshPlain)
        #expect(session.demangle(wordy) == freshWordy)
        #expect(session.demangle(plain) == freshPlain)
        #expect(session.demangle(wordy) == freshWordy)
    }

    /// Every mangling era through one session, mixed: stable-ABI, Swift-4
    /// `_T0`, legacy `_T`, Mach-O underscored, doubled `__T`, and a macro
    /// name — each equal to its one-shot result in that same interleaving.
    @Test func manglingErasInterleaveWithoutCrossTalk() {
        let names = [
            "$s4main6ServerC5start4portySi_tF",
            "_T0SaySiG",
            "_TFC4test3FooD",
            "_$s10Foundation4DataV",
            "__TFC4test3Foo3barfT_T_",
            "$sSS7cStringSSSPys4Int8VG_tcfC",
            "not a symbol at all",
            "$sinvalid!!!",
        ]
        let session = DemangleSession()
        for style in Self.styles {
            for name in names {
                #expect(session.demangle(name, style: style) == demangle(name, style: style),
                        "session diverged from one-shot for \(name) [\(style)]")
            }
        }
    }

    /// `nil` agreement: a session declines exactly what the one-shot declines
    /// — non-symbols, malformed Swift-prefixed names, and the empty string —
    /// and a decline leaves the session fully usable.
    @Test func declinesMatchOneShotAndDoNotPoisonTheSession() {
        let session = DemangleSession()
        #expect(session.demangle("") == nil)
        #expect(session.demangle("printf") == nil)
        #expect(session.demangle("$s!!!") == nil)
        // `$sRv_` parses but renders empty in every style — the session
        // returns `nil` exactly as the one-shot does (never an empty string).
        #expect(session.demangle("$sRv_") == nil)
        // A good symbol right after a decline renders normally.
        #expect(session.demangle("$s4main3fooyyF") == "main.foo() -> ()")
        #expect(session.demangle("$s4main3fooyyF", style: .simplified) == demangle("$s4main3fooyyF", style: .simplified))
    }

    /// A deep/specialized symbol followed immediately by a tiny one: the
    /// arena, stacks, and printer buffer shrink back logically (storage may
    /// stay warm — that is the point) with no residue in the output.
    @Test func largeThenTinySymbolRendersClean() throws {
        let symbols = ArenaBackendDifferentialTests.fixtureSymbols()
        let deepest = try #require(symbols.max(by: { $0.utf8.count < $1.utf8.count }))
        let session = DemangleSession()
        let big = session.demangle(deepest)
        #expect(big == demangle(deepest))
        #expect(session.demangle("$s4main3fooyyF") == "main.foo() -> ()")
    }
}
