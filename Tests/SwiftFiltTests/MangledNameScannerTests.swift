// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// The scanner against realistic artifact text: true positives in crash-log/nm/linker/build lines, a false-positive corpus that survives byte-for-byte, range correctness, and `demangleAll` idempotence.
@Suite("Mangled-name scanning in arbitrary text")
struct MangledNameScannerTests {
    private let scanner = MangledNameScanner()

    // MARK: True positives from realistic artifact lines

    @Test func crashLogFrameRewrites() {
        let line = "6   MyApp                         0x0000000100004abc $s4main3fooyyF + 12"
        #expect(demangleAll(in: line)
            == "6   MyApp                         0x0000000100004abc main.foo() -> () + 12")
    }

    @Test func nmOutputRewrites() {
        let line = "0000000100003f50 T _$s4main6ServerC5start4portySi_tF"
        #expect(demangleAll(in: line)
            == "0000000100003f50 T main.Server.start(port: Swift.Int) -> ()")
    }

    @Test func linkerErrorLineRewritesBothSymbols() {
        let line = #""_$s4main3fooyyF", referenced from: _OBJC_CLASS_$__TtC4test3Foo in main.o"#
        #expect(demangleAll(in: line)
            == #""main.foo() -> ()", referenced from: _OBJC_CLASS_$_test.Foo in main.o"#)
    }

    @Test func ansiColoredBuildOutputRewrites() {
        let line = "\u{1B}[1m\u{1B}[31merror:\u{1B}[0m undefined symbol \u{1B}[36m_$s4main3fooyyF\u{1B}[0m"
        #expect(demangleAll(in: line)
            == "\u{1B}[1m\u{1B}[31merror:\u{1B}[0m undefined symbol \u{1B}[36mmain.foo() -> ()\u{1B}[0m")
    }

    @Test func sentenceEndingPeriodSurvives() {
        // The candidate charset includes `.` (LLVM suffixes), but trailing
        // dots are trimmed — prose punctuation is not part of the symbol.
        #expect(demangleAll(in: "crashed in $s4main3fooyyF. See frame 6.")
            == "crashed in main.foo() -> (). See frame 6.")
        #expect(demangleAll(in: "at $s4main3fooyyF...")
            == "at main.foo() -> ()...")
    }

    @Test func llvmSuffixedSymbolInAFrameRewrites() {
        let line = "7   Plugin  0x00018 $s013CompilerSwiftA21PluginMessageHandling0cD0O10DiagnosticV13PositionRangeV11startOffsetSivM.resume.0 + 40"
        let expected = "7   Plugin  0x00018 CompilerSwiftCompilerPluginMessageHandling.PluginMessage.Diagnostic.PositionRange.startOffset.modify : Swift.Int with unmangled suffix \".resume.0\" + 40"
        #expect(demangleAll(in: line) == expected)
    }

    @Test func everyPrefixEraIsFoundMidText() {
        #expect(demangleAll(in: "old _T04main3fooyyF and class _TtC4test3Foo here")
            == "old main.foo() -> () and class test.Foo here")
        #expect(demangleAll(in: "swift4 $S4main3fooyyF embedded $e4main3fooyyF")
            == "swift4 main.foo() -> () embedded main.foo() -> ()")
        // Legacy subscript entities (`_Ti…`) and stdlib-substitution forms
        // (`_TS…`) are found through the same grammar-exact operator set the
        // engine pre-filter uses — byte-identical to `swift-demangle`'s
        // stream output for these lines (the legacy grammar keeps unparsed
        // trailing text as a suffix, so `_TSized` genuinely demangles while
        // `_TABLE_SIZE` and `_ToC4main3Foo` never start a candidate).
        #expect(demangleAll(in: "crash in _TiC4Meow5MyCls9subscriptFT1iSi_Sf here")
            == "crash in Meow.MyCls.subscript(i: Swift.Int) -> Swift.Float here")
        #expect(demangleAll(in: "then _TSized there, but _TABLE_SIZE and _ToC4main3Foo stay")
            == "then Swift.Int with unmangled suffix \"zed\" there, but _TABLE_SIZE and _ToC4main3Foo stay")
        // A macro-expansion buffer name in a diagnostics path: the `.swift`
        // extension joins the symbol as an unmangled suffix — byte-identical
        // to `swift-demangle`'s stream output for the same line (the
        // charset's `.` is what makes `.resume.0` suffixes work).
        #expect(demangleAll(in: "macro at @__swiftmacro_18macro_expand_peers1SV1f20addCompletionHandlerfMp_.swift:3:1")
            == "macro at peer macro @addCompletionHandler expansion #1 of f in macro_expand_peers.S with unmangled suffix \".swift\":3:1")
    }

    @Test func multipleAdjacentAndEdgeSymbolsRewrite() {
        #expect(demangleAll(in: "$s4main3fooyyF $s4main3fooyySiF")
            == "main.foo() -> () main.foo(Swift.Int) -> ()")
        #expect(demangleAll(in: "$s4main3fooyyF at start") == "main.foo() -> () at start")
        #expect(demangleAll(in: "at end $s4main3fooyyF") == "at end main.foo() -> ()")
        #expect(demangleAll(in: "$s4main3fooyyF") == "main.foo() -> ()")
    }

    @Test func nonASCIISurroundingTextIsPreserved() {
        #expect(demangleAll(in: "émoji 🚀 _$s4main3fooyyF 中文 fin")
            == "émoji 🚀 main.foo() -> () 中文 fin")
    }

    @Test func styleParameterAppliesToReplacements() {
        let line = "0x1 $s4main6ServerC5start4portySi_tF + 8"
        #expect(demangleAll(in: line, style: .simplified) == "0x1 Server.start(port:) + 8")
        #expect(scanner.demangleAll(in: line, style: .unqualified) == "0x1 start(port: Int) -> () + 8")
    }

    @Test func freeFunctionAndScannerMethodAgree() {
        let line = "T _$s4main3fooyyF and _TtC4test3Foo"
        #expect(demangleAll(in: line) == scanner.demangleAll(in: line))
    }

    @Test func candidateParsingButRenderingEmptyInFullIsNotAMatch() {
        // `$sRv_` parses but renders empty in EVERY style, including the
        // validating `.full` — so it fails the accept gate outright: the
        // scan leaves it untouched and resumes one byte later, never
        // treating it as a match (contrast `$ss`, which is a match whose
        // `.simplified` rendering happens to be empty).
        let line = "frame $sRv_ end"
        #expect(scanner.demangleAll(in: line) == line)
        #expect(scanner.matches(in: line).isEmpty)
    }

    @Test func matchesRenderingEmptyInTheSelectedStyleKeepTheirText() {
        // `$ss` passes the full-style validation gate but renders empty in
        // .simplified (`swift-demangle -simplified` echoes it too): the
        // rewrite keeps the original text rather than deleting the match.
        let line = "frame $ss end"
        #expect(scanner.demangleAll(in: line, style: .simplified) == line)
        #expect(demangleAll(in: line, style: .simplified) == line)
        #expect(scanner.demangleAll(in: line) == "frame Swift end")
    }

    @Test func combiningMarkGluedToAMatchStaysUnmatchedInTheStringView() {
        // A combining mark directly after a match's last ASCII byte joins
        // it into one grapheme, so the match's end is not a character
        // boundary: the String-view scan skips the match (positions must
        // exist in the String), while the byte-level scan — the documented
        // binary-safe authority — still finds and rewrites it.
        let text = "$sSiN\u{0301} tail"
        #expect(scanner.matches(in: text).isEmpty)
        let byteMatches = scanner.matches(inBytes: Array(text.utf8))
        #expect(byteMatches.map(\.mangled) == ["$sSiN"])
        #expect(scanner.demangleAll(in: text) == "type metadata for Swift.Int\u{0301} tail")
        // The same match with an ordinary boundary is found by both scans.
        #expect(scanner.matches(in: "$sSiN tail").map(\.mangled) == ["$sSiN"])
    }

    // MARK: False positives stay untouched

    @Test(arguments: [
        // Plain English, currency, underscore-heavy C names.
        "The quick brown fox jumps over the lazy dog.",
        "Total cost was $100 and the _TABLE_SIZE stayed fixed.",
        "_TK_LOGGING enabled, US$stock rallied, see FAQ.",
        "let $s = 1 // a dollar identifier in Swift source",
        // C++ manglings.
        "U _ZN4llvm3fooEv and __ZTVN3fooE from libLLVM.a",
        "0000000000401d80 T _ZNSt6vectorIiSaIiEE9push_backEOi",
        // Base64 (URL-safe alphabet contains `_T`) and hex.
        "token eyJhbGciOi_T0JIUzI1NiIsInR5cCI6IkpXVCJ9 refused",
        "b64 eyJ_T0JIUzI1 blob",
        "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        // URLs, UUIDs, paths.
        "GET https://example.com/$something?x=_T99&y=$s HTTP/1.1",
        "id 550e8400-e29b-41d4-a716-446655440000 at /usr/lib/swift/libswiftCore.dylib",
        // JSON and shell.
        #"{"symbol": "_Z", "price_T0": 3, "$schema": "v1"}"#,
        "export PS1='$ ' && echo $SHELL",
        // Swift-prefixed garbage that fails the parse.
        "$sZZZ is not a symbol, nor is $s alone, nor @__swiftmacro_",
        "",
    ])
    func falsePositiveCorpusSurvivesByteForByte(_ line: String) {
        #expect(demangleAll(in: line) == line)
        #expect(scanner.matches(in: line).isEmpty)
    }

    @Test func gluedTrailingGarbageIsNotAMatch() {
        // Candidates are maximal charset runs (exactly `swift-demangle`'s
        // stream behavior): a symbol fused to trailing garbage fails the
        // parse and is left alone.
        let line = "fused $s4main3fooyyFghij stays"
        #expect(demangleAll(in: line) == line)
    }

    // MARK: Matches: ranges, trees, replacements

    @Test func matchRangesSliceToTheirMangledText() throws {
        let line = #""_$s4main3fooyyF", referenced from: _OBJC_CLASS_$__TtC4test3Foo in x.o"#
        let matches = scanner.matches(in: line)
        try #require(matches.count == 2)
        for match in matches {
            #expect(String(line[match.range]) == match.mangled)
            #expect(match.symbol.kind == .Global)
        }
        #expect(matches[0].mangled == "_$s4main3fooyyF")
        #expect(matches[0].demangled() == "main.foo() -> ()")
        #expect(matches[1].mangled == "_TtC4test3Foo")
        #expect(matches[1].demangled() == "test.Foo")
        #expect(matches[1].demangled(.simplified) == "Foo")
    }

    @Test func rangeBasedReplacementReconstructsDemangleAll() {
        let line = "frame $s4main3fooyyF then _$s4main6ServerC5start4portySi_tF end"
        var rebuilt = line
        for match in scanner.matches(in: line).reversed() {
            rebuilt.replaceSubrange(match.range, with: match.demangled())
        }
        #expect(rebuilt == demangleAll(in: line))
    }

    @Test func matchRangesAreOrderedAndNonOverlapping() {
        let line = "$s4main3fooyyF $s4main3fooyySiF $s4main3fooyySSF"
        let matches = scanner.matches(in: line)
        #expect(matches.count == 3)
        for (a, b) in zip(matches, matches.dropFirst()) {
            #expect(a.range.upperBound <= b.range.lowerBound)
        }
    }

    @Test func matchesInNonASCIITextSliceCorrectly() {
        let line = "🚀🚀 _$s4main3fooyyF 中文 $s4main3fooyySiF"
        let matches = scanner.matches(in: line)
        #expect(matches.count == 2)
        for match in matches {
            #expect(String(line[match.range]) == match.mangled)
        }
    }

    // MARK: Idempotence

    @Test func demangleAllIsIdempotentOnRealisticLines() {
        let lines = [
            "6   MyApp   0x0000000100004abc $s4main3fooyyF + 12",
            "0000000100003f50 T _$s4main6ServerC5start4portySi_tF",
            #""_$s4main3fooyyF", referenced from: _OBJC_CLASS_$__TtC4test3Foo"#,
            "old _T04main3fooyyF and $S4main3fooyyF and $e4main3fooyyF",
            "plain prose without any symbols at all",
            "$sZZZ and _ZN4llvm3fooEv stay put",
        ]
        for line in lines {
            let once = demangleAll(in: line)
            #expect(demangleAll(in: once) == once, "not a fixed point: \(line)")
        }
    }

    /// Corpus-scale idempotence: one rewrite pass is a fixed point for every real
    /// symbol except the pinned 7 whose demangled form embeds a raw mangled name
    /// (constant-propagated closure payloads the printer emits raw, shared with
    /// `swift-demangle`) — exactly the rows whose rewritten text still scans as mangled.
    @Test func demangleAllIsIdempotentAcrossTheCorpus() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let (violations, characterized) = await onLargeStack { () -> ([String], Int) in
            let scanner = MangledNameScanner()
            var bad: [String] = []
            var stillMangled = 0
            for row in rows {
                let line = "0000000100003f50 T \(row.mangled) + 12"
                let once = scanner.demangleAll(in: line)
                let twice = scanner.demangleAll(in: once)
                if once == twice { continue }
                // Non-idempotence is only legitimate when pass one's output
                // still contains a validated mangling.
                if scanner.matches(in: once).isEmpty {
                    bad.append("L\(row.lineNumber) \(row.mangled)")
                } else {
                    stillMangled += 1
                }
            }
            return (bad, stillMangled)
        }
        #expect(violations.isEmpty, "unexplained non-idempotence: \(violations.prefix(3))")
        #expect(characterized == 7, "raw-payload symbol count moved: \(characterized)")
    }

    /// Re-scanning the oracle's demangled output leaves it untouched (demangled text
    /// has no manglings) for every row but the pinned raw-payload symbols. Oracle-declined
    /// rows are skipped — their "output" is still a mangled name by definition.
    @Test func fixtureDemangledOutputsAreFixedPoints() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let rewritten = await onLargeStack { () -> Int in
            let scanner = MangledNameScanner()
            var count = 0
            for row in rows {
                if SwiftDemanglerCorpusParity.oracleDeclined(row.compact, for: row) { continue }
                if scanner.demangleAll(in: row.compact) != row.compact { count += 1 }
            }
            return count
        }
        #expect(rewritten == 7, "demangled-output fixed-point exceptions moved: \(rewritten)")
    }
}
