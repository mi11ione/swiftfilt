// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFiltParityCore
import Testing

/// The oracle-version floor: the print and tree legs compare rendering
/// strings and node kinds, both of which upstream renames between releases
/// (measured 6.2.4 → 6.4: `predefined @objc completion handler block
/// implementation` → `checked …`, and the
/// `FunctionSignatureSpecializationParamPayload` node kind → `Identifier`).
/// An oracle below the reference therefore reports skew that reads exactly
/// like an engine defect, so those runs report in full but must not gate.
@Suite("Oracle reference version")
struct OracleReferenceVersionTests {
    @Test func parsesBothIdentityForms() {
        // Apple's toolchain token, the shape `Oracle.identity` prefers.
        #expect(Oracle.version(of: "swiftlang-6.4.0.27.1")! == (6, 4))
        #expect(Oracle.version(of: "swiftlang-6.2.4.1.4")! == (6, 2))
        // A swift.org build has no swiftlang token, so identity falls back
        // to the first line of `swift --version`.
        #expect(Oracle.version(of: "Swift version 6.3.3 (swift-6.3.3-RELEASE)")! == (6, 3))
        #expect(Oracle.version(of: "Apple Swift version 6.4 (swiftlang-6.4.0.27.1 clang-2100.3.27.1)")! == (6, 4))
    }

    @Test func unreadableVersionsAreNil() {
        #expect(Oracle.version(of: "swift-demangle (version unknown)") == nil)
        #expect(Oracle.version(of: "") == nil)
        // A bare major with no minor is not a version.
        #expect(Oracle.version(of: "swiftlang-6") == nil)
    }

    @Test func skipsRunsThatAreNotVersionsAndFindsTheOneThatIs() {
        // The scan must not stop at a number that has no `.MINOR` after it.
        #expect(Oracle.version(of: "build 20260715 of 6.3.3")! == (6, 3))
    }

    /// The trap this floor is easiest to get wrong on: the run summary's
    /// oracle line carries the tool PATH as well as the token, and an
    /// `Xcode_26.3.app` path component parses as version 26.3 — which would
    /// clear any realistic floor and silently re-enable gating.
    @Test func pathComponentsMustNotBeMistakenForTheVersion() {
        let composed = "/Applications/Xcode_26.3.app/Contents/Developer/Toolchains/"
            + "XcodeDefault.xctoolchain/usr/bin/swift-demangle [swiftlang-6.2.4.1.4]"
        #expect(Oracle.version(of: composed)! == (26, 3), "the composed line parses as the PATH's number")
        #expect(Oracle.belowReference(composed) == nil, "which is exactly why callers must pass the raw token")
        // The raw token is what the commands actually feed it.
        #expect(Oracle.belowReference("swiftlang-6.2.4.1.4") != nil)
    }

    @Test func belowReferenceIsNilAtOrAboveTheFloor() {
        let reference = Oracle.referenceVersion
        #expect(Oracle.belowReference("swiftlang-\(reference.major).\(reference.minor).0.1") == nil)
        #expect(Oracle.belowReference("swiftlang-\(reference.major).\(reference.minor + 1)") == nil)
        #expect(Oracle.belowReference("swiftlang-\(reference.major + 1).0") == nil)
    }

    @Test func belowReferenceExplainsItselfWhenOlder() {
        let reason = Oracle.belowReference("swiftlang-6.2.4.1.4")
        #expect(reason != nil)
        #expect(reason?.contains("ADVISORY") == true)
        #expect(reason?.contains("6.2") == true, "names the oracle it actually found")
        #expect(reason?.contains("\(Oracle.referenceVersion.major).\(Oracle.referenceVersion.minor)") == true)
    }

    @Test func unreadableVersionIsAdvisoryAndSaysSo() {
        let reason = Oracle.belowReference("swift-demangle (version unknown)")
        #expect(reason != nil, "an unconfirmable oracle must not gate")
        #expect(reason?.contains("unreadable") == true)
    }
}
