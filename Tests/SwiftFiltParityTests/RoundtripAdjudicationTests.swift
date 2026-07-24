// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFiltParityCore
import Testing

/// The `-remangle-new` stream reconstruction: the reference tool aborts the stdin stream at the first failing row (error to stderr with the symbol name, rows after it unprocessed), so the adjudicator must map the successful prefix, mark the errored row, and resume after it — refusing to guess on any invariant violation. Driven with a stub oracle scripted like the measured tool.
@Suite("Reference remangler stream reconstruction")
struct ReferenceRemangleTests {
    /// A stub oracle: echoes each stdin line prefixed `RM:`, but for any line containing
    /// `FAIL` prints the reference tool's error to stderr and exits — the measured abort behavior.
    private func makeStubOracle() throws -> String {
        let directory = NSTemporaryDirectory() + "/parity-stub-\(UInt64.random(in: 0 ... .max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/stub-remangler.sh"
        let script = """
        #!/bin/bash
        while IFS= read -r line; do
          case "$line" in
            *FAIL*) echo "Error: (7:1) unable to re-mangle $line" >&2; exit 1;;
            *) echo "RM:$line";;
          esac
        done
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func cleanBatchMapsOneToOne() throws {
        let stub = try makeStubOracle()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }
        let result = referenceRemangle(["$sA", "$sB", "$sC"], oracle: stub, timeout: 30)
        #expect(result != nil)
        #expect(result?.count == 3)
        #expect(result?[0] == "RM:$sA")
        #expect(result?[2] == "RM:$sC")
    }

    @Test func abortAtErrorResumesAfterTheErroredRow() throws {
        let stub = try makeStubOracle()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }
        let result = referenceRemangle(["$sA", "FAIL1", "$sB", "FAIL2", "$sC"], oracle: stub, timeout: 30)
        #expect(result != nil)
        #expect(result?.count == 5)
        #expect(result?[0] == "RM:$sA")
        #expect(result?[1] == nil, "the errored row is nil, not misattributed")
        #expect(result?[2] == "RM:$sB")
        #expect(result?[3] == nil)
        #expect(result?[4] == "RM:$sC")
    }

    @Test func errorOnFirstAndLastRowsReconstructs() throws {
        let stub = try makeStubOracle()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }
        let result = referenceRemangle(["FAILx", "$sA", "FAILy"], oracle: stub, timeout: 30)
        #expect(result != nil)
        #expect(result?[0] == nil)
        #expect(result?[1] == "RM:$sA")
        #expect(result?[2] == nil)
    }

    @Test func misalignedOracleOutputRefusesToGuess() throws {
        // A stub whose stderr names a symbol that is NOT the next
        // unaccounted row: the reconstruction invariant must fail loudly
        // (nil), never misattribute verdicts.
        let directory = NSTemporaryDirectory() + "/parity-stub-\(UInt64.random(in: 0 ... .max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/lying-remangler.sh"
        let script = """
        #!/bin/bash
        echo "Error: (1:1) unable to re-mangle NOT-A-ROW" >&2
        exit 1
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(referenceRemangle(["$sA", "$sB"], oracle: path, timeout: 30) == nil)
    }

    @Test func unlaunchableOracleReturnsNil() {
        #expect(referenceRemangle(["$sA"], oracle: "/nonexistent/tool", timeout: 5) == nil)
    }
}

/// The truncation pair space: a budget covering it must visit every (symbol, cut-length) pair exactly once — sweeping EVERY prefix length of every symbol, not only the short ones.
@Suite("Truncation plan coverage")
struct TruncationPlanTests {
    @Test func everyPrefixOfEverySymbolIsVisitedExactlyOnce() {
        // Prefix-disjoint symbols so every (symbol, cut) pair is a
        // distinct string — the walk must be a permutation of the space.
        let plan = TruncationPlan(symbols: ["abcd", "xyzabcdefjklmn", "qrs"])
        let expectedPairs = 4 + 14 + 3
        #expect(plan.totalPairs == expectedPairs)
        var seen: [String: Int] = [:]
        for item in 0 ..< plan.totalPairs {
            seen[plan.input(for: item), default: 0] += 1
        }
        #expect(seen.count == expectedPairs, "stride is a permutation of the pair space")
        #expect(seen.values.allSatisfy { $0 == 1 })
        #expect(seen["a"] != nil, "1-byte prefixes are visited")
        #expect(seen["xyzabcdefjklmn"] != nil, "full-length prefixes are visited")
    }

    @Test func sharedPrefixesCountOncePerPairNotPerString() {
        // "$sAB" and "$s4main3fooyyF" share the "$s" prefix: the pair
        // space still visits both pairs (the string just repeats).
        let plan = TruncationPlan(symbols: ["$sAB", "$s4main3fooyyF"])
        var seen: [String: Int] = [:]
        for item in 0 ..< plan.totalPairs {
            seen[plan.input(for: item), default: 0] += 1
        }
        #expect(seen.values.reduce(0, +) == plan.totalPairs)
        #expect(seen["$s"] == 2, "both symbols contribute their $s prefix pair")
    }

    @Test func deterministicAcrossCalls() {
        let plan = TruncationPlan(symbols: ["$s4main3fooyyF", "$sSi"])
        for item in [0, 7, 13] {
            #expect(plan.input(for: item) == plan.input(for: item))
        }
    }

    @Test func emptySourceFallsBackSafely() {
        let plan = TruncationPlan(symbols: [])
        #expect(!plan.input(for: 0).isEmpty)
        #expect(TruncationPlan(symbols: [""]).input(for: 5) == "$s4main3fooyyF")
    }
}

/// The classify-marker grammar: only `{X(,X)*}` with X in {N, C, T:…} is a marker — a demangling that itself begins with a brace (SIL box types render `{ let Swift.Int }`) is not.
@Suite("Classify marker grammar")
struct ClassifyMarkerGrammarTests {
    @Test func validMarkerShapes() {
        #expect(leadingBraceTokens("{N} echoed") == "{N}")
        #expect(leadingBraceTokens("{C} some name") == "{C}")
        #expect(leadingBraceTokens("{T:$s3foo3barC3basyyF} thunk") == "{T:$s3foo3barC3basyyF}")
        #expect(leadingBraceTokens("{T:$s3fooyyF,C} both") == "{T:$s3fooyyF,C}")
    }

    @Test func boxTypeRenderingsAreNotMarkers() {
        #expect(leadingBraceTokens("{ let Swift.Int }").isEmpty)
        #expect(leadingBraceTokens("{ var Swift.Int, let Swift.UInt }").isEmpty)
        #expect(leadingBraceTokens("{}").isEmpty)
    }

    @Test func nonLeadingAndMalformedGroupsAreNotMarkers() {
        #expect(leadingBraceTokens("name {N}").isEmpty)
        #expect(leadingBraceTokens("{X} nope").isEmpty)
        #expect(leadingBraceTokens("{N,} trailing-empty-token").isEmpty)
        #expect(leadingBraceTokens("{unclosed").isEmpty)
    }
}
