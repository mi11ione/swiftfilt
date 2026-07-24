// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// The byte-level scanner entry points: binary-safe scan/rewrite over raw bytes, byte-identity for non-manglings (invalid UTF-8 included), and exact agreement with the `String` entry points on valid UTF-8.
@Suite("Byte-level mangled-name scanning")
struct MangledNameScannerByteAPITests {
    private let scanner = MangledNameScanner()

    // MARK: Matching over raw bytes

    @Test func byteMatchCarriesRangeMangledAndTree() throws {
        let bytes = Array("frame $s4main3fooyyF + 12".utf8)
        let matches = scanner.matches(inBytes: bytes)
        let match = try #require(matches.first)
        #expect(matches.count == 1)
        #expect(match.mangled == "$s4main3fooyyF")
        #expect(Array(bytes[match.byteRange]) == Array(match.mangled.utf8))
        #expect(match.demangled() == "main.foo() -> ()")
        #expect(match.demangled(.simplified) == "foo()")
        #expect(match.symbol.kind == .Global)
    }

    @Test func byteMatchesAgreeWithStringMatches() {
        let text = #"0x1 _$s4main6ServerC5start4portySi_tF then "$s4main3fooyyF", done."#
        let byteMatches = scanner.matches(inBytes: Array(text.utf8))
        let stringMatches = scanner.matches(in: text)
        #expect(byteMatches.map(\.mangled) == stringMatches.map(\.mangled))
        #expect(byteMatches.map(\.symbol) == stringMatches.map(\.symbol))
        // The byte ranges are the UTF-8 offsets of the string ranges.
        let utf8 = text.utf8
        for (byteMatch, stringMatch) in zip(byteMatches, stringMatches) {
            let lower = utf8.distance(from: text.startIndex, to: stringMatch.range.lowerBound)
            let upper = utf8.distance(from: text.startIndex, to: stringMatch.range.upperBound)
            #expect(byteMatch.byteRange == lower ..< upper)
        }
    }

    @Test func matchesInJunkBytesFindSymbolsBetweenInvalidUTF8() throws {
        var bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x80]
        bytes.append(contentsOf: "$s4main3fooyyF".utf8)
        bytes.append(contentsOf: [0xC3, 0x28]) // invalid 2-byte sequence
        bytes.append(contentsOf: "_$s4main6ServerC5start4portySi_tF".utf8)
        bytes.append(0xF5) // never valid in UTF-8
        let matches = scanner.matches(inBytes: bytes)
        #expect(matches.map(\.mangled) == ["$s4main3fooyyF", "_$s4main6ServerC5start4portySi_tF"])
        let first = try #require(matches.first)
        #expect(first.byteRange.lowerBound == 4)
    }

    // MARK: Rewriting over raw bytes

    @Test func demangleAllInBytesRewritesBetweenJunk() {
        var bytes: [UInt8] = [0xDE, 0xAD]
        bytes.append(contentsOf: "x $s4main3fooyyF y".utf8)
        bytes.append(0xBE)
        var expected: [UInt8] = [0xDE, 0xAD]
        expected.append(contentsOf: "x main.foo() -> () y".utf8)
        expected.append(0xBE)
        #expect(scanner.demangleAll(inBytes: bytes) == expected)
    }

    @Test func invalidUTF8WithoutSymbolsPassesThroughByteIdentical() {
        // Prefix lookalikes against invalid continuations: every candidate
        // dies in validation and every byte survives verbatim.
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "$s".utf8)
        bytes.append(contentsOf: [0xC3, 0x28])
        bytes.append(contentsOf: "_T0".utf8)
        bytes.append(contentsOf: [0xED, 0xA0, 0x80]) // UTF-8-encoded surrogate: invalid
        bytes.append(contentsOf: [0x00, 0x1B, 0x5B, 0x33, 0x31, 0x6D]) // NUL + ANSI escape
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF])
        #expect(scanner.demangleAll(inBytes: bytes) == bytes)
        #expect(scanner.matches(inBytes: bytes).isEmpty)
    }

    @Test func everyByteValuePassesThroughWhenNoManglingIsPresent() {
        // The whole byte alphabet, no valid mangling anywhere: identity.
        let bytes = (0 ... 255).map { UInt8($0) }
        #expect(scanner.demangleAll(inBytes: bytes) == bytes)
    }

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(scanner.demangleAll(inBytes: []) == [])
        #expect(scanner.matches(inBytes: []).isEmpty)
    }

    // MARK: String entry points are views over the byte core

    @Test func stringDemangleAllAgreesWithByteDemangleAll() {
        let lines = [
            "no symbols at all",
            "frame $s4main3fooyyF + 12",
            #""_$s4main3fooyyF", referenced from: _OBJC_CLASS_$__TtC4test3Foo in main.o"#,
            "unicode Δ around _$s4main6ServerC5start4portySi_tF too",
            "at $s4main3fooyyF...",
        ]
        for line in lines {
            for style in DemangleStyle.allCases {
                let viaBytes = String(
                    decoding: scanner.demangleAll(inBytes: Array(line.utf8), style: style),
                    as: UTF8.self,
                )
                #expect(viaBytes == scanner.demangleAll(in: line, style: style))
            }
        }
    }

    // MARK: The mangling character-set predicate

    @Test func manglingCharacterSetIsExactlyTheDocumentedOne() {
        for value in 0 ... 255 {
            let byte = UInt8(value)
            let expected = (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || byte == UInt8(ascii: ".")
            #expect(MangledNameScanner.isManglingCharacter(byte) == expected, "byte \(value)")
        }
    }

    @Test func everyMatchedByteIsAManglingCharacterOrLeadingAt() {
        // The predicate really is the candidate alphabet: every byte of
        // every match satisfies it (the `@` of a macro prefix is the one
        // documented head exception).
        let text = "a $s4main3fooyyF b @__swiftmacro_1a13testStringifyAA1bySi_SitF9stringifyfMf_ c"
        let bytes = Array(text.utf8)
        for match in scanner.matches(inBytes: bytes) {
            for (offset, byte) in bytes[match.byteRange].enumerated() {
                let isHeadAt = offset == 0 && byte == UInt8(ascii: "@")
                #expect(MangledNameScanner.isManglingCharacter(byte) || isHeadAt)
            }
        }
    }
}
