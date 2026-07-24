// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// C3 arena zero-copy identifier tagging: verbatim-ASCII `inputRange` vs `owned` (punycode/operator/word-subst/non-ASCII), pinned indirectly through `demangle` bytes since the tag isn't publicly observable; oracle `swift-demangle -compact`.
@Suite("Arena zero-copy identifier text (C3 tagging + materialize)")
struct ArenaZeroCopyTextTests {
    /// `SwiftSymbol` value-backend render of `mangled` in `style` — the in-process oracle
    /// the arena path must match byte-for-byte; `nil` when it doesn't demangle or renders empty.
    private static func valueRender(_ mangled: String, _ style: SwiftDemanglerPrinter.Style) -> String? {
        let adapted = mangled.hasPrefix("__T") ? String(mangled.dropFirst()) : mangled
        guard let tree = SwiftDemangler().demangle(symbol: adapted) else { return nil }
        let rendered = SwiftDemanglerPrinter().print(tree, style: style)
        return rendered.isEmpty ? nil : rendered
    }

    /// Arena product render styles, each paired with its `SwiftSymbol` value-backend style.
    private static let styles: [(DemangleStyle, SwiftDemanglerPrinter.Style)] = [
        (.full, .full), (.simplified, .simplified), (.qualified, .qualified), (.unqualified, .unqualified),
    ]

    /// Assert the arena render of `mangled` equals the `SwiftSymbol` render in every style,
    /// and its `.full` render equals `oracle` (the `swift-demangle -compact` output).
    private static func expectArenaMatchesOracleAndValue(_ mangled: String, oracle: String) {
        #expect(SwiftFilt.demangle(mangled, style: .full) == oracle)
        for (arenaStyle, valueStyle) in styles {
            #expect(SwiftFilt.demangle(mangled, style: arenaStyle) == valueRender(mangled, valueStyle),
                    "arena vs SwiftSymbol diverged for \(mangled) [\(arenaStyle)]")
        }
    }

    @Test("plain ASCII identifiers render zero-copy, byte-exact (inputRange tag)")
    func plainAsciiIdentifiersRenderByteExact() {
        // "test" (module) and "foo" are plain length-prefixed ASCII identifiers —
        // the verbatim inputRange fast path. Module "test" additionally exercises
        // the Identifier→Module `changingKind` tag carry-through.
        Self.expectArenaMatchesOracleAndValue("$s4test3fooyyF", oracle: "test.foo() -> ()")
        Self.expectArenaMatchesOracleAndValue("$s4main1AV", oracle: "main.A")
    }

    @Test("punycode identifier renders decoded Unicode, not raw bytes (owned tag)")
    func punycodeIdentifierRendersDecodedUnicode() {
        // The associated-type name is a punycode (`00…`) identifier decoding to an
        // emoji. It MUST be owned: tagged inputRange it would emit the raw mangled
        // bytes `004JqIh…` instead of `👻`, diverging from swift-demangle.
        Self.expectArenaMatchesOracleAndValue(
            "_$s004JqIh17_StringProcessing16TypedIntProtocolPTl",
            oracle: "associated type descriptor for _StringProcessing.TypedIntProtocol.👻",
        )
    }

    @Test("operator spelling renders translated, not mangled letters (owned tag)")
    func operatorSpellingRendersTranslated() {
        // `2eeoi` mangles the infix `==`; the operator spelling is built by the
        // demangler (owned), never a verbatim input slice. Tagged inputRange it
        // would emit `ee` instead of `==`.
        Self.expectArenaMatchesOracleAndValue(
            "_$s011RedditCore_aB11MediaModels0C8AuthInfoC2eeoiySbAC_ACtFZ",
            oracle: "static RedditCore_RedditCoreMediaModels.MediaAuthInfo.== infix(RedditCore_RedditCoreMediaModels.MediaAuthInfo, RedditCore_RedditCoreMediaModels.MediaAuthInfo) -> Swift.Bool",
        )
    }

    @Test("word-substituted identifier renders assembled text, byte-exact (owned tag)")
    func wordSubstitutedIdentifierRendersByteExact() {
        // `0C8AuthInfo` assembles the identifier `MediaAuthInfo` from a harvested
        // word (`Media`) plus a literal run (`AuthInfo`) — a leading-'0' word
        // substitution, so it is owned (not a single input slice).
        let out = SwiftFilt.demangle("_$s011RedditCore_aB11MediaModels0C8AuthInfoC2eeoiySbAC_ACtFZ", style: .full)
        #expect(out?.contains("MediaAuthInfo") == true)
    }

    @Test("non-ASCII plain identifier falls back to owned decode, arena == SwiftSymbol")
    func nonAsciiPlainIdentifierFallsBackToOwned() {
        // A plain (non-punycode) identifier body carrying non-ASCII bytes appears
        // only in malformed input — `String(decoding:as:UTF8)` would be lossy, so
        // C3 tags it OWNED (never a wrong-bytes inputRange). swift-demangle
        // declines it (non-ASCII is always punycoded when well-formed), so the
        // pin is the C3 superset invariant: both backends leniently agree.
        let mangled = "$s4main2\u{00E9}V" // module "main", 2-byte identifier "é", struct
        #expect(SwiftFilt.demangle(mangled, style: .full) == "main.\u{00E9}")
        for (arenaStyle, valueStyle) in Self.styles {
            #expect(SwiftFilt.demangle(mangled, style: arenaStyle) == Self.valueRender(mangled, valueStyle))
        }
    }

    @Test("opaque-return rewrite materializes inputRange identifiers, byte-exact")
    func opaqueReturnMaterializesInputRangeIdentifiers() {
        // An opaque return type drives the arena's `materialize`/`adopt` seam
        // (`setParentForOpaqueReturnTypeNodes`): its verbatim inputRange identifiers
        // must reify from the input slice into the identical `String` the value backend carries.
        Self.expectArenaMatchesOracleAndValue(
            "_$s012_JetUI_SwiftB015JUPresenterViewV4bodyQrvpQOMQ",
            oracle: "opaque type descriptor for <<opaque return type of _JetUI_SwiftUI.JUPresenterView.body : some>>",
        )
    }
}
