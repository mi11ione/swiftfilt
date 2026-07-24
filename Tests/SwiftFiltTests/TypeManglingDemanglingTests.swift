// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// `demangle(type:style:)` — the bare-type entry (no `$s` prefix), the `swift-demangle -type` form. Expected values are frozen from `swift-demangle -type`; the decline set pins the never-fabricate contract: a string that isn't exactly one complete type returns `nil` (where the reference prints `<<invalid type>>`).
@Suite("Type-mangling demangling")
struct TypeManglingDemanglingTests {
    @Test(arguments: [
        ("Si", "Swift.Int"),
        ("SS", "Swift.String"),
        ("Sf", "Swift.Float"),
        ("Sb", "Swift.Bool"),
        ("SaySiG", "[Swift.Int]"),
        ("SiSg", "Swift.Int?"),
        ("SSSg", "Swift.String?"),
        ("SDySSSiG", "[Swift.String : Swift.Int]"),
        ("Sim", "Swift.Int.Type"),
        ("So8NSObjectC", "__C.NSObject"),
        ("SpySiG", "Swift.UnsafeMutablePointer<Swift.Int>"),
        ("Si_Sdt", "(Swift.Int, Swift.Double)"),
    ])
    func fullStyleMatchesTheReferenceTypeDemangling(_ mangled: String, _ expected: String) {
        #expect(demangle(type: mangled) == expected)
        // The default argument is `.full`.
        #expect(demangle(type: mangled, style: .full) == expected)
    }

    @Test func eachStyleRendersTheSameType() {
        #expect(demangle(type: "SiSg", style: .full) == "Swift.Int?")
        #expect(demangle(type: "SiSg", style: .simplified) == "Int?")
        #expect(demangle(type: "SiSg", style: .qualified) == "Swift.Optional<Swift.Int>")
        #expect(demangle(type: "SiSg", style: .unqualified) == "Int?")
        #expect(demangle(type: "SaySiG", style: .full) == "[Swift.Int]")
        #expect(demangle(type: "SaySiG", style: .simplified) == "[Int]")
        #expect(demangle(type: "SaySiG", style: .qualified) == "Swift.Array<Swift.Int>")
    }

    /// Not one complete valid type (`$s`/`_$s`-prefixed entity, Mach-O-underscored form,
    /// unfinished production, nonsense, empty) — all return `nil`, never `<<invalid type>>`.
    @Test(arguments: ["xyz", "$sSi", "_$sSi", "$s4main3fooyyF", "ySitcD", "SSSJ", ""])
    func nonTypesReturnNil(_ input: String) {
        #expect(demangle(type: input) == nil)
    }

    /// Trailing type operators compose onto the type, exactly as the
    /// reference stacks them (`z` is the `inout` operator).
    @Test func trailingTypeOperatorsCompose() {
        #expect(demangle(type: "SaySiGzzz") == "inout inout inout [Swift.Int]")
    }

    /// The type grammar and the symbol grammar are distinct entries: a body
    /// that names an entity demangles as a *type* only when it is one, and
    /// the same bytes behind the `$s` global prefix are a symbol, not a type.
    @Test func typeAndSymbolEntriesAreDistinct() {
        #expect(demangle("$s4main3fooyyF") == "main.foo() -> ()") // symbol entry
        #expect(demangle(type: "4main3fooyyF") == "main.foo() -> ()") // type-parseable body
        #expect(demangle(type: "$s4main3fooyyF") == nil) // the $s prefix is not type grammar
    }
}
