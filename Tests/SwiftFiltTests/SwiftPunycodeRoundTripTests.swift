// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The modified-Punycode transcoder through the public API: a non-ASCII type identifier mangles and round-trips to the same tree across every UTF-8 width (2-byte Latin-1, 3-byte CJK, 4-byte emoji); an out-of-alphabet digit is rejected. Internal transcoder, exercised by re-mangling a crafted nominal-type tree.
@Suite("Swift punycode identifier round-trip")
struct SwiftPunycodeRoundTripTests {
    private let demangler = SwiftDemangler()
    private let mangler = SwiftMangler()

    /// Re-mangle a `M.<name>` type-metadata-accessor tree and demangle it back;
    /// returns whether the round-trip reproduces the original tree.
    private func roundTrips(_ name: String) -> Bool {
        guard let base = demangler.demangle(symbol: "$s1M3FooVMa") else { return false }
        func replace(_ node: SwiftSymbol) -> SwiftSymbol {
            if node.kind == .Identifier, node.text == "Foo" {
                return SwiftSymbol(kind: .Identifier, name: name)
            }
            return SwiftSymbol(kind: node.kind, children: node.children.map(replace), contents: node.contents)
        }
        let tree = replace(base)
        guard let mangled = mangler.mangle(tree) else { return false }
        return demangler.demangle(symbol: mangled)?.treeDump() == tree.treeDump()
    }

    @Test func latin1IdentifierRoundTrips() {
        #expect(roundTrips("café"))
        #expect(roundTrips("vergüenza"))
    }

    @Test func cjkIdentifierRoundTrips() {
        #expect(roundTrips("日本語"))
    }

    @Test func emojiIdentifierRoundTrips() {
        #expect(roundTrips("Counter😀View"))
    }

    @Test func mixedWidthAndOperatorCharsRoundTrip() {
        #expect(roundTrips("Ω_α7Δértékπ"))
    }

    @Test func malformedPunycodeBodyReturnsNil() {
        // A `00`-prefixed Punycode identifier whose post-delimiter body carries
        // an out-of-alphabet digit (`Z` > the A–J range) → decode fails → nil.
        #expect(demangler.demangle(symbol: "$s4main0012vergenza_JFZV") == nil)
    }

    @Test func punycodedIdentifierFamiliesRoundTripThroughRealManglings() {
        // Canonical manglings produced by the engine's own encoder, each
        // decode verified byte-identical against `xcrun swift-demangle`:
        // 2-byte, 3-byte, and combining scalars, a punycoded module, and a
        // mapped non-symbol character (the space).
        #expect(SwiftFilt.demangle("$s4main0012d_FfahroGaBbyyF") == "main.üñîçödé() -> ()")
        #expect(SwiftFilt.demangle("$s009mdl_snaFa3fooyyF") == "mödül.foo() -> ()")
        #expect(SwiftFilt.demangle("$s4main0010wgvHBaBBJeyyF") == "main.日本語() -> ()")
        #expect(SwiftFilt.demangle("$s4main005e_xbbyyF") == "main.é() -> ()")
        #expect(SwiftFilt.demangle("$s4main007ab_qgJkyyF") == "main.a b() -> ()")
    }

    @Test(arguments: [
        "$s4main0012zzzzzzzzzzzzyyF", // delta overflow across a long payload
        "$s4main008999999999yyF", // digits are not punycode letters
        "$s4main008________yyF", // delimiters only
        "$s4main004zzzzyyF", // overflow in a short payload
        "$s4main006zzzzzzyyF",
        "$s4main008zzzzzzzzyyF",
        "$s4main004000ayyF", // nested zero-length forms
    ])
    func overflowingPunycodePayloadsDecline(_ mangled: String) {
        // `swift-demangle` refuses every one of these.
        #expect(demangler.demangle(symbol: mangled) == nil)
    }

    @Test func punycodePayloadBytesAboveASCIIDecline() {
        // The byte-level entry can carry non-ASCII bytes inside a punycode
        // payload — something no String mangling can produce. The decoder
        // refuses them rather than decoding garbage.
        var bytes = Array("$s4main005e_xbbyyF".utf8)
        let payloadStart = Array("$s4main005".utf8).count
        bytes[payloadStart] = 0xC3
        #expect(demangler.demangle(symbolBytes: bytes) == nil)
    }
}
