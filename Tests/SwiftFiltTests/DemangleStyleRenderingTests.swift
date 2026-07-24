// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// The four `DemangleStyle` presets through the product entry points: corpus-wide fixture parity for the three oracle-backed styles, pinned known-good strings for `.unqualified`.
@Suite("DemangleStyle preset rendering")
struct DemangleStyleRenderingTests {
    @Test func exactlyTheFourValidatedPresetsExist() {
        #expect(DemangleStyle.allCases.count == 4)
        #expect(Set(DemangleStyle.allCases) == [.full, .simplified, .qualified, .unqualified])
    }

    @Test func theFourStylesRenderFourDistinctForms() {
        let mangled = "$s10XCTHarness038XCTHCrashLogBacktraceBackedByJSONCrashC6ThreadC4nameSSSgvg"
        let renderings = DemangleStyle.allCases.map { demangle(mangled, style: $0) }
        #expect(renderings == [
            "XCTHarness.XCTHCrashLogBacktraceBackedByJSONCrashLogThread.name.getter : Swift.String?",
            "XCTHCrashLogBacktraceBackedByJSONCrashLogThread.name.getter",
            "XCTHarness.XCTHCrashLogBacktraceBackedByJSONCrashLogThread.name.getter : Swift.Optional<Swift.String>",
            "name.getter : String?",
        ])
        #expect(Set(renderings).count == 4)
    }

    @Test func sugarDistinguishesFullFromQualified() {
        // `.full` synthesizes sugar ([Int], Int?); `.qualified` spells
        // Optional/Array out — the canonical, comparison-stable form.
        let mangled = "$s4main5fetch3urlSaySiGSgSS_tF"
        #expect(demangle(mangled, style: .full)
            == "main.fetch(url: Swift.String) -> [Swift.Int]?")
        #expect(demangle(mangled, style: .qualified)
            == "main.fetch(url: Swift.String) -> Swift.Optional<Swift.Array<Swift.Int>>")
    }

    @Test func simplifiedDropsModulesArgumentsAndSpecializations() {
        let specialized = "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF12PackageModel24ArtifactsArchiveMetadataV12ArtifactTypeO_Tg5"
        #expect(demangle(specialized, style: .simplified)
            == "specialized ContiguousArray._createNewBuffer(bufferIsUnique:minimumCapacity:growForAppend:)")
    }

    /// `.simplified` and `.qualified` corpus-wide, through the product entry
    /// point, against the oracle's `-simplified` and `-no-sugar` columns.
    /// (`.full` corpus parity lives in the entry-point suite.)
    @Test func corpusParityForSimplifiedAndQualified() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let failures = await onLargeStack { () -> [String] in
            var fails: [String] = []
            for row in rows {
                if !SwiftDemanglerCorpusParity.oracleDeclined(row.simplified, for: row),
                   demangle(row.mangled, style: .simplified) != row.simplified
                {
                    fails.append("L\(row.lineNumber) simplified")
                }
                if !SwiftDemanglerCorpusParity.oracleDeclined(row.noSugar, for: row),
                   demangle(row.mangled, style: .qualified) != row.noSugar
                {
                    fails.append("L\(row.lineNumber) qualified")
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(failures.count) mismatches; first: \(failures.first ?? "")")
    }

    /// `.unqualified` has no oracle CLI flag, so it is pinned to known-good
    /// renderings (its printer paths are exercised corpus-wide by the
    /// engine's ported suites).
    @Test func unqualifiedSpotChecks() {
        #expect(demangle("$s4main6ServerC5start4portySi_tF", style: .unqualified)
            == "start(port: Int) -> ()")
        #expect(demangle("$s4main5fetch3urlSaySiGSgSS_tF", style: .unqualified)
            == "fetch(url: String) -> [Int]?")
        #expect(demangle("_TtC4test3Foo", style: .unqualified) == "Foo")
    }
}
