// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Storage-accessor spellings the printer emits. Fidelity point: `vx`/`vy` follow apple/swift `main` (`yielding_mutate`/`yielding_borrow`), not the shipped 6.2 toolchain's `modify2`/`read2`.
@Suite("Swift demangler accessor spellings")
struct SwiftDemanglerAccessorSpellingTests {
    private let demangler = SwiftDemangler()
    private let mangler = SwiftMangler()
    private let printer = SwiftDemanglerPrinter()

    private func full(_ mangled: String) -> String? {
        demangler.demangle(symbol: mangled).map { printer.print($0, style: .full) }
    }

    @Test func accessorFamilyRenders() {
        // `$s2hi1SV1iSiv<accessor>` — property `i: Int` on struct `hi.S`.
        #expect(full("$s2hi1SV1iSivg") == "hi.S.i.getter : Swift.Int")
        #expect(full("$s2hi1SV1iSivs") == "hi.S.i.setter : Swift.Int")
        #expect(full("$s2hi1SV1iSivr") == "hi.S.i.read : Swift.Int")
        #expect(full("$s2hi1SV1iSivM") == "hi.S.i.modify : Swift.Int")
        #expect(full("$s2hi1SV1iSivw") == "hi.S.i.willset : Swift.Int")
        #expect(full("$s2hi1SV1iSivW") == "hi.S.i.didset : Swift.Int")
        #expect(full("$s2hi1SV1iSivau") == "hi.S.i.unsafeMutableAddressor : Swift.Int")
        #expect(full("$s2hi1SV1iSivlu") == "hi.S.i.unsafeAddressor : Swift.Int")
        #expect(full("$s2hi1SV1iSivi") == "hi.S.i.init : Swift.Int")
    }

    @Test func yieldingCoroutineAccessorsUseMainSpelling() {
        // main-faithful: `yielding_mutate` / `yielding_borrow`, not 6.2's
        // `modify2` / `read2`.
        #expect(full("$s2hi1SV1iSivx") == "hi.S.i.yielding_mutate : Swift.Int")
        #expect(full("$s2hi1SV1iSivy") == "hi.S.i.yielding_borrow : Swift.Int")
    }

    @Test func yieldingAccessorsRoundTrip() {
        for symbol in ["$s2hi1SV1iSivx", "$s2hi1SV1iSivy"] {
            let ast = demangler.demangle(symbol: symbol)
            #expect(ast.flatMap { mangler.mangle($0) } == symbol, "round-trip failed for \(symbol)")
        }
    }
}
