// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Demangling across every dialect — `$s`, Swift-4.1 `$S`, Embedded `$e`, legacy `_T`, and the `@__swiftmacro_` prefix. Each prefix routes correctly; legacy/`$S`/`$e` re-mangle to canonical `$s`, so they are checked for self-consistency, not byte-exact round-trip.
@Suite("Swift demangler dialect handling")
struct SwiftDemanglerDialectTests {
    private let demangler = SwiftDemangler()
    private let mangler = SwiftMangler()
    private let printer = SwiftDemanglerPrinter()

    /// Asserts the symbol demangles and prints `full`. With `selfConsistent` (`$S`/`$e`, which
    /// share the `$s` tree), the re-mangling demangles back to an identical tree; legacy `_T`
    /// re-mangles to the modernized `$s` form by design, so only a successful re-mangle is checked.
    private func assertDemangles(_ mangled: String, full: String, selfConsistent: Bool) {
        let ast = demangler.demangle(symbol: mangled)
        #expect(ast != nil, "demangle nil for \(mangled)")
        guard let ast else { return }
        #expect(printer.print(ast, style: .full) == full, "\(mangled): full=`\(printer.print(ast, style: .full))` expected=`\(full)`")
        let remangled = mangler.mangle(ast)
        #expect(remangled != nil, "mangle nil for \(mangled)")
        if selfConsistent, let remangled {
            #expect(demangler.demangle(symbol: remangled)?.treeDump() == ast.treeDump(), "\(mangled): not self-consistent (remangled=\(remangled))")
        }
    }

    @Test func legacyTNominalTypes() {
        assertDemangles("_TtC4main3Foo", full: "main.Foo", selfConsistent: false)
        assertDemangles("_TtV4main3Bar", full: "main.Bar", selfConsistent: false)
        assertDemangles("_TtO4main4Enum", full: "main.Enum", selfConsistent: false)
    }

    @Test func legacyTKnownTypesAndSugar() {
        assertDemangles("_TtSi", full: "Swift.Int", selfConsistent: false)
        assertDemangles("_TtSS", full: "Swift.String", selfConsistent: false)
        assertDemangles("_TtSb", full: "Swift.Bool", selfConsistent: false)
        assertDemangles("_TtSd", full: "Swift.Double", selfConsistent: false)
        assertDemangles("_TtGSaSi_", full: "[Swift.Int]", selfConsistent: false)
        assertDemangles("_TtGSqSi_", full: "Swift.Int?", selfConsistent: false)
        assertDemangles("_TtT_", full: "()", selfConsistent: false)
    }

    @Test func legacyTObjCClassAndFunctionAndMetadata() {
        assertDemangles("_TtCSo8NSObject", full: "__C.NSObject", selfConsistent: false)
        assertDemangles("_TFC4main3Foo3barfT_T_", full: "main.Foo.bar() -> ()", selfConsistent: false)
        assertDemangles("_TF4main3fooFT_T_", full: "main.foo() -> ()", selfConsistent: false)
    }

    @Test func dollarCapitalSDialect() {
        assertDemangles("$S4main3FooVD", full: "main.Foo", selfConsistent: true)
        assertDemangles("$S4main3FooVMa", full: "type metadata accessor for main.Foo", selfConsistent: true)
    }

    @Test func embeddedDialect() {
        assertDemangles("$e4main3FooVMa", full: "type metadata accessor for main.Foo", selfConsistent: true)
    }

    @Test func swiftmacroPrefixIsRecognizedAndDoesNotCrash() {
        // `@__swiftmacro_` is a debug-info / macro-expansion filename surface,
        // never present in nlist symbol tables; the prefix dispatch must accept
        // it and parse the body without trapping. The recognizer flags it.
        #expect(SwiftDemangler.isSwiftMangled("@__swiftmacro_4test3fooyyfMf_"))
        _ = demangler.demangle(symbol: "@__swiftmacro_4test3fooyyfMf_")
    }
}

/// The bare-type grammar entry point `demangle(type:)` (no global prefix): standard substitutions, sugared bound generics, pointers, special types, and dependent params render exactly as their `$s…D` symbol form.
@Suite("Swift demangler type-grammar entry point")
struct SwiftDemanglerTypeGrammarTests {
    private let demangler = SwiftDemangler()
    private let printer = SwiftDemanglerPrinter()

    private func assertType(_ mangled: String, full: String, simplified: String? = nil) {
        let ast = demangler.demangle(type: mangled)
        #expect(ast != nil, "demangle(type:) nil for \(mangled)")
        guard let ast else { return }
        #expect(printer.print(ast, style: .full) == full, "\(mangled): full=`\(printer.print(ast, style: .full))` expected=`\(full)`")
        if let simplified {
            #expect(printer.print(ast, style: .simplified) == simplified, "\(mangled): simplified mismatch")
        }
    }

    @Test func standardSubstitutions() {
        assertType("Si", full: "Swift.Int", simplified: "Int")
        assertType("SS", full: "Swift.String", simplified: "String")
        assertType("Sb", full: "Swift.Bool")
        assertType("Sd", full: "Swift.Double")
        assertType("Sf", full: "Swift.Float")
        assertType("ScA", full: "Swift.Actor", simplified: "Actor")
        assertType("ScP", full: "Swift.TaskPriority")
    }

    @Test func boundGenericSugar() {
        assertType("SaySiG", full: "[Swift.Int]", simplified: "[Int]")
        assertType("SDySSSiG", full: "[Swift.String : Swift.Int]", simplified: "[String : Int]")
        assertType("SqySiG", full: "Swift.Int?", simplified: "Int?")
        assertType("SiSg", full: "Swift.Int?")
    }

    @Test func pointersAndSpecialTypes() {
        assertType("SpySiG", full: "Swift.UnsafeMutablePointer<Swift.Int>")
        assertType("SPySiG", full: "Swift.UnsafePointer<Swift.Int>")
        assertType("yp", full: "Any")
        assertType("yt", full: "()")
        assertType("Bi64_", full: "Builtin.Int64")
    }

    @Test func dependentGenericParameter() {
        assertType("x", full: "A")
    }

    @Test func malformedTypeReturnsNil() {
        // Trailing garbage that leaves more than one node on the stack is not a
        // valid single type.
        #expect(demangler.demangle(type: "SiSi") == nil)
        #expect(demangler.demangle(type: "") == nil)
    }
}
