// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `explain`'s library surface: era detection, the success/notSwift/malformed
// outcome split, failure diagnosis (truncated identifier, stray byte, unfinished
// production, empty body, legacy fallback), the scanner→identity bridge, the
// error code, and the engine's progress-reporting seam.

import SwiftFilt
import Testing

@Suite("Mangling era detection")
struct ManglingEraTests {
    @Test func detectsEveryEraFromItsPrefix() {
        #expect(ManglingEra.detected(in: "$s4main3fooyyF") == .stableABI)
        #expect(ManglingEra.detected(in: "$S4main3fooyyF") == .stableABI)
        #expect(ManglingEra.detected(in: "_$s4main3fooyyF") == .stableABI)
        #expect(ManglingEra.detected(in: "$e4main3fooyyF") == .embedded)
        #expect(ManglingEra.detected(in: "_$e4main3fooyyF") == .embedded)
        #expect(ManglingEra.detected(in: "_T04main3fooyyF") == .swift4)
        #expect(ManglingEra.detected(in: "__T04main3fooyyF") == .swift4)
        #expect(ManglingEra.detected(in: "_TtC4main3Foo") == .legacy)
        #expect(ManglingEra.detected(in: "__TMSi") == .legacy)
        #expect(ManglingEra.detected(in: "@__swiftmacro_4mainfoo") == .macro)
    }

    @Test func rejectsNamesWithNoRecognizedPrefix() {
        #expect(ManglingEra.detected(in: "hello_world") == nil)
        #expect(ManglingEra.detected(in: "_Z3fooiii") == nil)
        #expect(ManglingEra.detected(in: "$x1234") == nil, "$ but not s/S/e")
        #expect(ManglingEra.detected(in: "_$x") == nil, "_$ but not s/S/e")
        #expect(ManglingEra.detected(in: "_Ta") == nil, "_T then a non-operator")
        #expect(ManglingEra.detected(in: "_T") == nil, "_T with nothing after")
        #expect(ManglingEra.detected(in: "") == nil)
    }

    @Test func everyEraHasNamePrefixAndLabel() {
        for era in ManglingEra.allCases {
            #expect(!era.name.isEmpty)
            #expect(!era.prefix.isEmpty)
            #expect(era.label.contains(era.prefix), "\(era.name) label names its prefix")
        }
        #expect(ManglingEra.stableABI.name == "stableABI")
        #expect(ManglingEra.embedded.name == "embedded")
        #expect(ManglingEra.swift4.name == "swift4")
        #expect(ManglingEra.legacy.name == "legacy")
        #expect(ManglingEra.macro.name == "macro")
        #expect(ManglingEra.stableABI.prefix == "$s")
        #expect(ManglingEra.embedded.prefix == "$e")
        #expect(ManglingEra.swift4.prefix == "_T0")
        #expect(ManglingEra.legacy.prefix == "_T")
        #expect(ManglingEra.macro.prefix == "@__swiftmacro_")
    }
}

@Suite("Symbol explanation outcomes")
struct SymbolExplanationOutcomeTests {
    @Test func demangledCarriesTheCuratedSymbolAndEra() throws {
        let explanation = SymbolExplanation(parsing: "$s4main3fooyyF")
        #expect(explanation.era == .stableABI)
        #expect(explanation.isMalformed == false)
        let symbol = try #require(explanation.demangledSymbol)
        #expect(symbol.description == "main.foo() -> ()")
        if case let .demangled(same) = explanation.outcome {
            #expect(same == symbol)
        } else {
            Issue.record("expected .demangled")
        }
    }

    @Test func legacyAndMacroNamesAlsoDemangle() {
        #expect(SymbolExplanation(parsing: "_TtC4main3Foo").demangledSymbol?.description == "main.Foo")
        #expect(SymbolExplanation(parsing: "__TMSi").era == .legacy)
        #expect(SymbolExplanation(parsing: "__TMSi").demangledSymbol != nil)
    }

    @Test func notSwiftNamesHintAtTheirRealScheme() {
        assertNotSwift("_Z3fooiii", foreign: .cxxItanium)
        assertNotSwift("__Z3fooiii", foreign: .cxxItanium)
        assertNotSwift("_RNvNtC7mycrate3foo3bar", foreign: .rust)
        assertNotSwift("hello_world", foreign: nil)
    }

    private func assertNotSwift(_ name: String, foreign: SymbolExplanation.ForeignMangling?) {
        let explanation = SymbolExplanation(parsing: name)
        #expect(explanation.era == nil)
        #expect(explanation.demangledSymbol == nil)
        #expect(explanation.isMalformed == false)
        if case let .notSwiftMangled(hint) = explanation.outcome {
            #expect(hint == foreign)
        } else {
            Issue.record("expected .notSwiftMangled for \(name)")
        }
    }

    @Test func foreignHintsCarryToolAndLabel() {
        #expect(SymbolExplanation.ForeignMangling.cxxItanium.tool == "c++filt")
        #expect(SymbolExplanation.ForeignMangling.rust.tool == "rustfilt")
        #expect(SymbolExplanation.ForeignMangling.cxxItanium.label.contains("c++filt"))
        #expect(SymbolExplanation.ForeignMangling.rust.label.contains("rustfilt"))
    }
}

@Suite("Malformed diagnosis")
struct MalformedDiagnosisTests {
    private func malformed(_ name: String) throws -> SymbolExplanation.Malformed {
        let explanation = SymbolExplanation(parsing: name)
        #expect(explanation.isMalformed)
        return try #require(explanation.malformed, "expected .malformed for \(name)")
    }

    @Test func truncatedIdentifierReadsTheDeclaredLength() throws {
        let single = try malformed("$s4main9foo")
        #expect(single.stoppedAtByteOffset == 8)
        #expect(single.reason == .truncatedIdentifier(declaredLength: 9, availableBytes: 3))

        let multiDigit = try malformed("$s6modern10fetchThi")
        #expect(multiDigit.reason == .truncatedIdentifier(declaredLength: 10, availableBytes: 8))
    }

    @Test func aLengthPastTheWholeInputSaturatesToMax() throws {
        // "$s5" declares a 5-byte identifier with the whole input only 3
        // bytes — larger than the input, so the length saturates.
        let saturated = try malformed("$s5")
        #expect(saturated.reason == .truncatedIdentifier(declaredLength: Int.max, availableBytes: 0))
    }

    @Test func emptyBodyIsJustAPrefix() throws {
        #expect(try malformed("$s").reason == .emptyBody)
        #expect(try malformed("$e").reason == .emptyBody)
        #expect(try malformed("_T0").reason == .emptyBody)
        #expect(try malformed("@__swiftmacro_").reason == .emptyBody)
    }

    @Test func aStrayByteIsReportedWhereItSits() throws {
        let garbage = try malformed("$sXXXXXXXX")
        #expect(garbage.stoppedAtByteOffset < Array("$sXXXXXXXX".utf8).count)
        if case let .unexpectedByte(byte) = garbage.reason {
            #expect(byte == UInt8(ascii: "X"))
        } else {
            Issue.record("expected .unexpectedByte")
        }
        // A raw non-ASCII byte lands here too (identifiers are punycode).
        if case let .unexpectedByte(byte) = try malformed("$s4main😀yyF").reason {
            #expect(byte >= 0x80)
        } else {
            Issue.record("expected .unexpectedByte for the emoji")
        }
    }

    @Test func anUnfinishedProductionAtTheEndIsIncomplete() throws {
        #expect(try malformed("$s4main6ServerC5start4portySi_tX").reason == .incompleteInput)
        #expect(try malformed("$s4main3fooyyFS").reason == .incompleteInput, "dangling substitution")
    }

    @Test func legacyFailuresReportUnparseableWithNoFabricatedOffset() throws {
        let legacy = try malformed("_TtC4main3Fo")
        #expect(legacy.reason == .unparseable)
        #expect(legacy.stoppedAtByteOffset == 0)
    }

    @Test func machODoubledUnderscoreShiftsTheReportedOffset() throws {
        // "__T0" is Swift-4 behind the Mach-O double underscore; the engine
        // sees "_T0", and the reported offset is shifted back by the dropped
        // byte — an empty body diagnosed on the original name.
        let adapted = try malformed("__T0")
        #expect(adapted.reason == .emptyBody)
        #expect(adapted.stoppedAtByteOffset == 4)
    }

    @Test func embeddedNamesAreTheNearestMiss() throws {
        let trailing = try malformed("$s4main3fooyyF trailing junk")
        #expect(trailing.embeddedSymbols == ["$s4main3fooyyF"])

        // A repeated embedded name is listed once (de-duplicated).
        let repeated = try malformed("$s4main3fooyyF x $s4main3fooyyF")
        #expect(repeated.embeddedSymbols == ["$s4main3fooyyF"])

        // A plain truncation embeds nothing extractable.
        #expect(try malformed("$s4main9foo").embeddedSymbols.isEmpty)
    }
}

@Suite("Scanner to identity bridge")
struct ScannerIdentityBridgeTests {
    @Test func liftingATreeMatchesParsingTheName() throws {
        let name = "$s4main6ServerC5start4portySi_tF"
        let parsed = try #require(DemangledSymbol(name))
        let lifted = DemangledSymbol(parsed.symbol, mangledName: name)
        #expect(lifted.mangledName == name)
        #expect(lifted.identityKey == parsed.identityKey)
        #expect(lifted.description == parsed.description)
        #expect(lifted.kind == parsed.kind)
    }

    @Test func stringMatchesReachTheIdentityKeyWithoutReparsing() throws {
        let text = "0  App  0x1  $s4main3fooyyFSi_Tg5 + 4"
        let match = try #require(MangledNameScanner().matches(in: text).first)
        let expected = try #require(DemangledSymbol(match.mangled)).identityKey
        #expect(match.identityKey == expected)
        #expect(match.demangledSymbol.identityKey == expected)
        #expect(match.demangledSymbol.mangledName == match.mangled)
    }

    @Test func byteMatchesReachTheIdentityKeyToo() throws {
        let bytes = Array("_$s4main3fooyyF".utf8)
        let match = try #require(MangledNameScanner().matches(inBytes: bytes).first)
        #expect(match.demangledSymbol.description == "main.foo() -> ()")
        #expect(match.identityKey.rawValue == "main.foo() -> ()")
    }
}

@Suite("DemangleError code")
struct DemangleErrorCodeTests {
    @Test func codeIsTheShortStableName() {
        #expect(DemangleError.notSwiftMangled.code == "notSwiftMangled")
        #expect(DemangleError.malformed.code == "malformed")
        // The long sentence stays on `description`, distinct from `code`.
        #expect(DemangleError.malformed.description != DemangleError.malformed.code)
    }

    @Test func thrownErrorsCarryTheCode() {
        do {
            _ = try demangle(validating: "not a symbol")
            Issue.record("expected a throw")
        } catch {
            #expect(error.code == "notSwiftMangled")
        }
    }
}

@Suite("Engine progress reporting")
struct EngineProgressReportingTests {
    @Test func aSuccessfulParseConsumesEveryByte() {
        let (symbol, consumed) = SwiftDemangler().demangleReportingProgress(symbol: "$s4main3fooyyF")
        #expect(symbol != nil)
        #expect(consumed == Array("$s4main3fooyyF".utf8).count)
    }

    @Test func aFailedParseReportsWhereItStopped() {
        let (symbol, consumed) = SwiftDemangler().demangleReportingProgress(symbol: "$s4main9foo")
        #expect(symbol == nil)
        #expect(consumed == 8, "the engine stops at the start of the identifier it cannot fill")
    }
}
