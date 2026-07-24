// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// `classify(_:)` — the `swift-demangle -classify` markers: `{N}` (not Swift), `{T:target}` (thunk), `{C}` (no Swift calling convention); a plain function/type carries none.
@Suite("Swift demangler classify markers")
struct SwiftDemanglerClassifyTests {
    private let printer = SwiftDemanglerPrinter()

    @Test func swiftSymbolsClassifyMarkers() {
        // Current `$s` and legacy `_T` prefixes are both recognized as Swift, so a
        // plain function or type carries no marker; a metadata accessor (no Swift
        // calling convention) carries `{C}`.
        #expect(printer.classify("$s4main3fooyyF") == "")
        #expect(printer.classify("$s4main3FooVMa") == "{C}")
        #expect(printer.classify("_TtC4main3Foo") == "")
        #expect(printer.classify("_T0sSi") == "")
    }

    @Test func nonSwiftNamesClassifyAsN() {
        #expect(printer.classify("main") == "{N}")
        #expect(printer.classify("_OBJC_CLASS_$_NSObject") == "{N}")
        #expect(printer.classify("") == "{N}")
    }
}

/// Unmangled-suffix escaping (`quoted`): a `Suffix` node's text renders as a quoted string with C-style escapes for special/non-printable bytes, as the reference printer does.
@Suite("Swift demangler unmangled-suffix escaping")
struct SwiftDemanglerSuffixEscapingTests {
    private let printer = SwiftDemanglerPrinter()

    @Test func specialAndNonPrintableBytesAreEscaped() {
        // One Suffix node carrying a backslash, tab, newline, CR, quote, NUL,
        // a control byte (0x01), and a high byte (0x7F) among printable chars.
        let suffix = "a\\b\tc\nd\re\"f\u{0}g\u{01}h\u{7f}i"
        let rendered = printer.print(SwiftSymbol(kind: .Suffix, name: suffix), style: .full)
        #expect(rendered == " with unmangled suffix \"a\\\\b\\tc\\nd\\re\\\"f\\0g\\x01h\\x7Fi\"")
    }

    @Test func printableSuffixIsLiteral() {
        let rendered = printer.print(SwiftSymbol(kind: .Suffix, name: ".123"), style: .full)
        #expect(rendered == " with unmangled suffix \".123\"")
    }

    @Test func suffixIsHiddenWhenSuffixDisplayDisabled() {
        // .simplified sets displayUnmangledSuffix = false → nothing emitted.
        #expect(printer.print(SwiftSymbol(kind: .Suffix, name: ".x"), style: .simplified) == "")
    }
}
