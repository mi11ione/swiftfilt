// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Validates `isSwiftMangled(_:)`, the prefix-only pre-filter: every era recognized with/without the Mach-O underscore, and the ambiguous legacy `_T` requires a known old-mangling operator to stay low-false-positive on C-heavy symbol tables.
@Suite("Swift mangled-name recognition")
struct SwiftDemanglerRecognitionTests {
    @Test func recognizesEveryCurrentPrefix() {
        for name in ["$s4main3FooV", "$S4main3FooV", "$e4main3FooV",
                     "_$s4main3FooV", "_$S4main3FooV", "_$e4main3FooV",
                     "@__swiftmacro_4main3fooyyfMf_"]
        {
            #expect(SwiftDemangler.isSwiftMangled(name), "expected recognized: \(name)")
        }
    }

    @Test func recognizesLegacyTPrefixWithKnownOperator() {
        // One demangling witness per character in the grammar-derived
        // operator set `0CFIMOPSTVWZitvw` (every char that can start an
        // old-mangling production after `_T`) — each of these also
        // demangles, so rejecting any would break pre-filter soundness.
        for name in ["_T04main3fooyyF", // 0: Swift-4.0 new mangling
                     "_TC4main3Baz", // C: class
                     "_TF4main3fooFT_T_", // F: function
                     "_TIF4main3fooFT1xSi_T_A_", // I: default argument
                     "_TMaSi", // M: metadata access
                     "_TO4main3Bar", // O: enum
                     "_TPA__TTRXFo_dSi_dSi_XFo_iSi_iSi_", // P: partial apply
                     "_TP4main5Proto", // P: protocol declaration
                     "_TSa", // S: stdlib substitution
                     "_TTRXFo_dSi_dSi_XFo_iSi_iSi_", // T: thunk
                     "_TV4main3Foo", // V: struct
                     "_TWVV4main3Foo", // W: value witness table
                     "_TZF4main3fooFT_T_", // Z: static entity
                     "_TiC4Meow5MyCls9subscriptFT1iSi_Sf", // i: subscript
                     "_TtC4main3Foo", // t: type mangling
                     "_Tv4main1xSi", // v: variable
                     "_TwalC4main3Foo", // w: value witness
                     "_TFC4main3Foo3barfT_T_"] // F again: method
        {
            #expect(SwiftDemangler.isSwiftMangled(name), "expected recognized: \(name)")
        }
    }

    @Test func recognizesDoubleUnderscoreTForm() {
        #expect(SwiftDemangler.isSwiftMangled("__TtC4main3Foo"))
        #expect(SwiftDemangler.isSwiftMangled("__TiC4Meow5MyCls9subscriptFT1iSi_Sf"))
    }

    @Test func rejectsLegacyTPrefixWithoutKnownOperator() {
        // The classic C-symbol collision: `_T` followed by a non-operator char.
        for name in ["_TK_LOG_PREFIX", "_TQfoo", "_Thello", "_TXYZ"] {
            #expect(!SwiftDemangler.isSwiftMangled(name), "expected rejected: \(name)")
        }
    }

    @Test func rejectsLegacyTPrefixWithDeadOperatorChars() {
        // Chars the pre-filter once accepted but that begin NO old-grammar
        // production (`o s G a b R f` dead-end in OldDemangler's top-level
        // dispatch; `swift-demangle` echoes all of these back). Rejecting
        // them costs nothing demangleable and keeps C names like
        // `_ToggleFlag` out.
        for name in ["_ToC4main3Foo", "_Ts4main3foo", "_TGSaSi_", "_TaSi",
                     "_TbT_T_", "_TRSi", "_TfT_T_"]
        {
            #expect(!SwiftDemangler.isSwiftMangled(name), "expected rejected: \(name)")
        }
    }

    @Test func rejectsBareTPrefixWithEmptyBody() {
        #expect(!SwiftDemangler.isSwiftMangled("_T"))
        #expect(!SwiftDemangler.isSwiftMangled("__T"))
    }

    @Test func rejectsNonSwiftSymbols() {
        for name in ["", "main", "_main", "_OBJC_CLASS_$_NSObject",
                     "foo_bar", "$x", "_$x", "swift_demangle"]
        {
            #expect(!SwiftDemangler.isSwiftMangled(name), "expected rejected: \(name)")
        }
    }

    // MARK: Classification markers

    @Test func thunkMarkersCarryTheirTargets() {
        // The `-classify` thunk marker computes the thunk's target symbol
        // by stripping the thunk suffix; every string below is byte-equal
        // to `swift-demangle -classify` output (verified 2026-07-16).
        let printer = SwiftDemanglerPrinter()
        #expect(printer.classify("$s4main3fooyyFTo") == "{T:$s4main3fooyyF,C}")
        // Legacy partial-apply forwarders compute their target by
        // stripping the `_TPA_`/`_TPAo_` head back to the wrapped thunk
        // (verified against `swift-demangle -classify` 2026-07-24).
        #expect(printer.classify("_TPA__TTRXFo_oSSoSS_dSb_XFo_iSSiSS_dSb_")
            == "{T:_TTRXFo_oSSoSS_dSb_XFo_iSSiSS_dSb_}")
        #expect(printer.classify("_TPAo__TTRXFo_oSSoSS_dSb_XFo_iSSiSS_dSb_")
            == "{T:_TTRXFo_oSSoSS_dSb_XFo_iSSiSS_dSb_}")
        #expect(printer.classify("$s4main3fooyyFTO") == "{T:$s4main3fooyyF}")
        // Old-style partial-apply forwarders embed the target after the
        // `_TPA_` / `_TPAo_` prefix.
        #expect(printer.classify("_TPA__TF4main3fooFT_T_") == "{T:_TF4main3fooFT_T_}")
        #expect(printer.classify("_TPAo__TF4main3fooFT_T_") == "{T:_TF4main3fooFT_T_}")
        // Async partials and suffixed pieces are not `{T:}` thunks.
        #expect(printer.classify("$s4main3fooyyFTQ0_") == "")
        #expect(printer.classify("$s4main3fooyyFTY0_") == "")
        #expect(printer.classify("$s4main3fooyyF.resume.0") == "")
        // Plain symbols carry no markers; junk is `{N}`.
        #expect(printer.classify("$s4main3fooyyF") == "")
        #expect(printer.classify("junkname") == "{N}")
    }
}
