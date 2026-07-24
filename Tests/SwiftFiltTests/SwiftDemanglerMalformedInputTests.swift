// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The "silent skip, never silent guess or trap" invariant on malformed input: no-prefix, empty body, operand-less operator, over-long identifier, and overflowing natural all return `nil`; the deeply-nested fixture proves recursion is bounded by input length, not the stack.
@Suite("Swift demangler malformed-input handling")
struct SwiftDemanglerMalformedInputTests {
    private let demangler = SwiftDemangler()

    @Test func noRecognizedPrefixReturnsNil() {
        for name in ["", "main", "_main", "abc123", "swift_demangle", "_OBJC_CLASS_$_X"] {
            #expect(demangler.demangle(symbol: name) == nil, "expected nil for \(name)")
        }
    }

    @Test func emptyBodyAfterPrefixReturnsNil() {
        for name in ["$s", "$S", "$e", "_$s"] {
            #expect(demangler.demangle(symbol: name) == nil, "expected nil for \(name)")
        }
    }

    @Test func operatorWithNoOperandReturnsNil() {
        // `Z` (Static) and `c` (FunctionType) each pop an operand off an empty
        // stack; the null-propagating builder yields nil.
        #expect(demangler.demangle(symbol: "$sZ") == nil)
        #expect(demangler.demangle(symbol: "$sc") == nil)
    }

    @Test func overlongIdentifierLengthReturnsNil() {
        // Length prefix 99 with far fewer bytes available.
        #expect(demangler.demangle(symbol: "$s99main") == nil)
    }

    @Test func overflowingNaturalReturnsNil() {
        // A 25-digit length overflows the natural-number accumulator → fail.
        #expect(demangler.demangle(symbol: "$s9999999999999999999999999main") == nil)
    }

    @Test func byteOverloadRejectsEmptyAndUnprefixed() {
        #expect(demangler.demangle(symbolBytes: []) == nil)
        #expect(demangler.demangle(symbolBytes: Array("foo".utf8)) == nil)
        #expect(demangler.demangle(symbolBytes: Array("$s".utf8)) == nil)
    }

    @Test func legacyPrefixGarbageReturnsNil() {
        // `_T` routes to the old demangler; a body it cannot parse is nil.
        #expect(demangler.demangle(symbol: "_TZZZZZ") == nil)
    }

    @Test func negativeIndexOperandsReturnNilNotTrap() {
        // Operators that read an index and build a node from it must reject a
        // failed (negative) index rather than trap converting it to an unsigned
        // node payload. Each input drives one such operator with a non-index
        // operand: opaque-type ordinal (`Qo`), macro-expansion source location
        // (`fMX`), the value/negative integer type (`$`), and the legacy
        // specialization pass id (`_TTSg`/`_TTSf`).
        for name in ["$sQoX", "$sQo", "$s3foozzfMfX_", "$s3foo3barfMXX",
                     "$s$X", "$s$nX", "$s$", "_TTSg", "_TTSf", "_TTSg!"]
        {
            #expect(demangler.demangle(symbol: name) == nil, "expected nil (no trap) for \(name)")
        }
    }

    @Test func malformedOperandsAcrossGrammarReturnNil() {
        // One malformed input per grammar area whose builder must reject bad
        // input: builtin-type width bounds (`Bf0_`/`Bi4097_`), bad type
        // annotations (`Y?`), `H`-operator conformances, metatype/special-type
        // (`M?`/`X?`/`XS?`), archetype (`Q?`), impl-function-type conventions
        // (`I?`/`Is_`), thunk/specialization (`T?`/`Tw?`/`TfX_n`/`Tg99_`),
        // accessors (`f?`/`Siv?`/`Siva?`), generic requirements (`R?`/`Rl?`),
        // back-ref substitutions (`A`/`A99z`), and operator/value-witness paths.
        let malformed = [
            "$sB?", "$sBf0_", "$sBi0_", "$sBv0_x", "$sBf4097_", "$sBi4097_",
            "$sBv4097_Bi8_", "$sBvBi8_", "$sSiBv4_", "$sYZ", "$sY?", "$sH?",
            "$sMX?", "$sM?", "$sX?", "$sXS?", "$sSiXM?", "$sQ?", "$sI?", "$sIs_",
            "$sII_", "$sIz_", "$sIg", "$sSiIgx", "$s4main3fooyyFT?",
            "$s4main3fooyyFTw?", "$s4main3fooyyFTJ?", "$s4main3FooC3barSivWO?",
            "$s4main3FooC3barSivWv?", "$sf?", "$sfm?", "$sSiv?", "$sSiva?",
            "$sSivl?", "$sR?", "$sRl?", "$sRE?", "$s1aoz", "$soi", "$sA", "$sA_",
            "$sA99z", "$sZ", "$s4main3fooyyFSi_Tg99_", "$s4main3fooyyFTfX_n",
            "$sSiwzz", "$s4main00V", "$sSiTK", "$s001__",
            "$sAab", "$sScz", "$sHz", "$sQS", "$s4main3fooyyFTH", "$sSiSiTK",
            "$sSi4main1PpGSi_", "$sSig_", "$sSi4main1PHI2_", "$sSi4main1PHA1_",
            "$sytMC", "$s4main3FooVSiSQTn",
        ]
        for name in malformed {
            #expect(demangler.demangle(symbol: name) == nil, "expected nil for \(name)")
        }
    }

    @Test func deeplyNestedOptionalParsesAndRoundTrips() async {
        // 100 nested Optionals: parse is bounded by input length, and the
        // recursive print/mangle/treeDump run on a large stack the same way
        // deep real-corpus symbols require. Deterministic outcome: the tree
        // re-mangles self-consistently (the remangler may emit the canonical
        // `Sg`/`Sq` form, so byte-equality is not required).
        let mangled = "$sSi" + String(repeating: "Sg", count: 100) + "D"
        let result = await onLargeStack { () -> String in
            let demangler = SwiftDemangler(); let mangler = SwiftMangler()
            guard let ast = demangler.demangle(symbol: mangled) else { return "demangle nil" }
            guard let remangled = mangler.mangle(ast) else { return "mangle nil" }
            if remangled == mangled { return "ok-byte-exact" }
            if demangler.demangle(symbol: remangled)?.treeDump() == ast.treeDump() { return "ok-self-consistent" }
            return "mismatch: \(remangled.prefix(48))"
        }
        #expect(result.hasPrefix("ok"), "\(result)")
    }

    @Test func pathologicallyDeepTreeIsRejectedByRemanglerDepthGuard() async {
        // 700 nested Optionals: the parse (bounded by input length) still
        // succeeds, but the recursive re-mangle exceeds the remangler's depth
        // ceiling — a defense-in-depth guard against stack exhaustion on an
        // adversarial tree. Deterministic outcome: demangle non-nil, mangle nil.
        let mangled = "$sSi" + String(repeating: "Sg", count: 700) + "D"
        let result = await onLargeStack { () -> String in
            let demangler = SwiftDemangler(); let mangler = SwiftMangler()
            guard let ast = demangler.demangle(symbol: mangled) else { return "demangle nil" }
            return mangler.mangle(ast) == nil ? "ok-guarded" : "mangled"
        }
        #expect(result == "ok-guarded", "\(result)")
    }
}
