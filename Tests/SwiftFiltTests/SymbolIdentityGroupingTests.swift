// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// The identity key's grouping semantics on real corpus families: what collapses onto one key, what deliberately keeps its own, and that the key is deterministic and never empty.
@Suite("Identity-key crash grouping")
struct SymbolIdentityGroupingTests {
    private func key(_ mangled: String) throws -> DemangledSymbol.IdentityKey {
        try #require(DemangledSymbol(mangled), "\(mangled) must demangle").identityKey
    }

    // MARK: Families that collapse onto one key

    @Test func genericSpecializationsOfOneOriginShareOneKey() throws {
        // Three real generic specializations of ContiguousArray._createNewBuffer
        // (three different type arguments) plus the hand-derived unspecialized
        // origin: one key.
        let family = [
            "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF12PackageModel24ArtifactsArchiveMetadataV12ArtifactTypeO_Tg5",
            "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF26XCResultKit_ArgumentParser11InputOriginV_SSt_Tg5",
            "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtFSo18WFWorkflowTypeNamea_Tg5",
            "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF",
        ]
        let keys = try family.map(key)
        #expect(Set(keys).count == 1, "specializations and their origin must group: \(keys)")
        #expect(keys[0].rawValue
            == "Swift.ContiguousArray._createNewBuffer(bufferIsUnique: Swift.Bool, minimumCapacity: Swift.Int, growForAppend: Swift.Bool) -> ()")
    }

    @Test func backDeploymentThunkFallbackAndSpecializationShareTheOriginKey() throws {
        // Real rows: the back-deployment fallback copy (TwB), the thunk (Twb),
        // a generic specialization of the thunk (Twb…Tg5), and the plain
        // function: one key.
        let family = [
            "$ss31withCheckedThrowingContinuation9isolation8function_xScA_pSgYi_SSyScCyxs5Error_pGXEtYaKlFTwB",
            "$ss31withCheckedThrowingContinuation9isolation8function_xScA_pSgYi_SSyScCyxs5Error_pGXEtYaKlFTwb",
            "$ss31withCheckedThrowingContinuation9isolation8function_xScA_pSgYi_SSyScCyxs5Error_pGXEtYaKlFTwbs5Int64V_Tg5",
            "$ss31withCheckedThrowingContinuation9isolation8function_xScA_pSgYi_SSyScCyxs5Error_pGXEtYaKlF",
        ]
        #expect(try Set(family.map(key)).count == 1)
    }

    @Test func objCBridgingThunkSharesItsMethodKey() throws {
        let plain = try key("$s10Foundation13__NSSwiftDataC20contentsOfMappedFile5errorACSSSg_yttKcfc")
        let bridged = try key("$s10Foundation13__NSSwiftDataC20contentsOfMappedFile5errorACSSSg_yttKcfcTo")
        #expect(plain == bridged)
    }

    @Test func dispatchThunkUnwrapsToItsTargetKey() throws {
        let allocating = try key("$s012_AppIntents_A3Kit0A20EntityViewAnnotationC6entity5stateACx_0aB00aD11VisualStateVtcAF0aD0RzlufC")
        let dispatch = try key("$s012_AppIntents_A3Kit0A20EntityViewAnnotationC6entity5stateACx_0aB00aD11VisualStateVtcAF0aD0RzlufCTj")
        #expect(allocating == dispatch)
    }

    @Test func allocatingAndInitializingInitShareOneKey() throws {
        // fC (allocating) and fc (initializing) are one source-level init —
        // the same target derivation `swift-demangle -classify` performs.
        let allocating = try key("$s10Foundation13__NSSwiftDataC20contentsOfMappedFile5errorACSSSg_yttKcfC")
        let initializing = try key("$s10Foundation13__NSSwiftDataC20contentsOfMappedFile5errorACSSSg_yttKcfc")
        #expect(allocating == initializing)
        #expect(allocating.rawValue.contains(".init("))
        #expect(!allocating.rawValue.contains("__allocating_init"))
    }

    @Test func deinitFlavorsShareOneKey() throws {
        let deallocating = try key("$s012_AppIntents_A3Kit0A20EntityViewAnnotationCfD")
        let plain = try key("$s012_AppIntents_A3Kit0A20EntityViewAnnotationCfd")
        #expect(deallocating == plain)
        #expect(plain.rawValue == "_AppIntents_AppKit.AppEntityViewAnnotation.deinit")
    }

    @Test func asyncAwaitPartialsShareTheFunctionKey() throws {
        // Real rows: the suspend-resume partial (TY0_) and the dispatch
        // thunk's await-resume partial (TjTQ0_), plus the hand-derived plain
        // async method: one key — every await point of one function groups.
        let family = [
            "$s10Accelerate9BNNSGraphO7ContextC12setBatchSize_11forFunctionySi_SSSgtYaFTY0_",
            "$s10Accelerate9BNNSGraphO7ContextC12setBatchSize_11forFunctionySi_SSSgtYaFTjTQ0_",
            "$s10Accelerate9BNNSGraphO7ContextC12setBatchSize_11forFunctionySi_SSSgtYaF",
        ]
        #expect(try Set(family.map(key)).count == 1)
    }

    @Test func llvmSuffixedPiecesShareTheirFunctionKey() throws {
        // Real row: an async accessor's `.resume.0` outlined piece.
        let suffixed = try key("$s013CompilerSwiftA21PluginMessageHandling0cD0O10DiagnosticV13PositionRangeV11startOffsetSivM.resume.0")
        let base = try key("$s013CompilerSwiftA21PluginMessageHandling0cD0O10DiagnosticV13PositionRangeV11startOffsetSivM")
        #expect(suffixed == base)
        #expect(try key("$s4main3fooyyF.llvm.123") == key("$s4main3fooyyF"))
    }

    @Test func partialApplyForwarderSharesItsClosureKey() throws {
        let forwarder = try key("$s10Accelerate4vDSPO10meanSquareySdxAA0A6BufferRzSd7ElementRtzlFZySRySdGXEfU_TA")
        let closure = try key("$s10Accelerate4vDSPO10meanSquareySdxAA0A6BufferRzSd7ElementRtzlFZySRySdGXEfU_")
        #expect(forwarder == closure)
        #expect(closure.rawValue.hasPrefix("closure #1"))
    }

    @Test func forwarderOfReabstractionThunkSharesTheThunkKey() throws {
        // Real rows: a reabstraction thunk and a partial apply of it — the
        // forwarder unwraps to the thunk, which keeps its own signature-keyed
        // identity (no target exists in the mangling).
        let thunk = try key("$s10CAFCombine31CAFRemoteNotificationObservableCAA017CAFRequestContentD0CIeggg_AC_AEtIegn_TR")
        let forwarded = try key("$s10CAFCombine31CAFRemoteNotificationObservableCAA017CAFRequestContentD0CIeggg_AC_AEtIegn_TRTA")
        #expect(thunk == forwarded)
        #expect(thunk.rawValue.contains("reabstraction thunk"))
    }

    // MARK: Boundaries that deliberately do NOT collapse

    @Test func protocolWitnessKeepsItsOwnKey() throws {
        // Documented choice: a witness is per-conformance code. It groups
        // neither with the protocol requirement (which would merge every
        // conforming type) nor with the concrete method (which the mangling
        // does not carry).
        let witness = try key("$s013CompilerSwiftA21PluginMessageHandling0C7FeatureOSQAASQ2eeoiySbx_xtFZTW")
        let requirement = try key("$sSQ2eeoiySbx_xtFZ")
        let concrete = try key("$s013CompilerSwiftA21PluginMessageHandling0C7FeatureO2eeoiySbAC_ACtFZ")
        #expect(witness != requirement)
        #expect(witness != concrete)
        #expect(witness.rawValue
            == "protocol witness for static Swift.Equatable.== infix(A, A) -> Swift.Bool in conformance CompilerSwiftCompilerPluginMessageHandling.PluginFeature : Swift.Equatable in CompilerSwiftCompilerPluginMessageHandling")
    }

    @Test func gettersAndSettersKeepDistinctKeys() throws {
        let base = "$s10XCTHarness038XCTHCrashLogBacktraceBackedByJSONCrashC6ThreadC4nameSSSgv"
        #expect(try key(base + "g") != key(base + "s"))
    }

    @Test func keyPathHelperDoesNotMergeIntoThePropertyAccessor() throws {
        let helper = try key("$s10Accelerate10QuadratureV17absoluteToleranceSdvpACTK")
        let getter = try key("$s10Accelerate10QuadratureV17absoluteToleranceSdvg")
        #expect(helper != getter)
        #expect(helper.rawValue.contains("key path getter"))
    }

    @Test func overloadsKeepDistinctKeys() throws {
        #expect(try key("$s4main3fooyySiF") != key("$s4main3fooyySSF"))
    }

    @Test func staticnessStaysInTheKey() throws {
        let staticGetter = try key("$s011_SwiftData_A2UI5QueryV18_propertyBehaviorss6UInt32VvgZ")
        #expect(staticGetter.rawValue.hasPrefix("static "))
    }

    // MARK: Determinism, non-emptiness, ergonomics

    @Test func degenerateManglingsFallBackAlongTheDocumentedChain() throws {
        // The documented non-empty fallback chain, exercised end to end on
        // parseable degenerates the compiler never emits.
        // `$sRv_` / `$syxD` render empty in every style (the reference
        // printer refuses these shapes), so normalized and un-normalized
        // renderings are both empty: the key is the mangled name itself.
        #expect(try key("$sRv_").rawValue == "$sRv_")
        #expect(try key("$syxD").rawValue == "$syxD")
        // `$sRv_Si_Tg5` normalizes to the bare marker (empty rendering)
        // but renders non-empty un-normalized: the middle link.
        #expect(try key("$sRv_Si_Tg5").rawValue == "generic specialization <Swift.Int> of ")
        // A bare forwarder is its own target and keys as itself.
        #expect(try key("$sTA").rawValue == "partial apply forwarder")
        // An attribute-only global normalizes to nothing and passes
        // through un-normalized.
        #expect(try key("$sSi_Tg5Sd_Tg5").rawValue
            == "generic specialization <Swift.Double> of generic specialization <Swift.Int> of ")
    }

    @Test func keysAreDeterministicAcrossIndependentParses() throws {
        let mangled = "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF12PackageModel24ArtifactsArchiveMetadataV12ArtifactTypeO_Tg5"
        let first = try key(mangled)
        for _ in 0 ..< 5 {
            #expect(try key(mangled) == first)
        }
        let symbol = try #require(DemangledSymbol(mangled))
        #expect(symbol.identityKey == symbol.identityKey)
    }

    @Test func keysGroupAsDictionaryKeys() throws {
        let frames = [
            "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF12PackageModel24ArtifactsArchiveMetadataV12ArtifactTypeO_Tg5",
            "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF26XCResultKit_ArgumentParser11InputOriginV_SSt_Tg5",
            "$s4main3fooyySiF",
        ]
        var buckets: [DemangledSymbol.IdentityKey: Int] = [:]
        for frame in frames {
            try buckets[key(frame), default: 0] += 1
        }
        #expect(buckets.count == 2)
        #expect(buckets.values.sorted() == [1, 2])
    }

    @Test func keyDescriptionIsItsRawValue() throws {
        let k = try key("$s4main3fooyyF")
        #expect(k.description == k.rawValue)
        #expect(k.rawValue == "main.foo() -> ()")
    }

    /// Determinism at corpus scale: recomputing every key from a fresh parse
    /// yields byte-identical strings.
    @Test func corpusKeysAreStableAcrossRecomputation() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let mismatches = await onLargeStack { () -> Int in
            var bad = 0
            for row in rows {
                guard let first = DemangledSymbol(row.mangled)?.identityKey,
                      let second = DemangledSymbol(row.mangled)?.identityKey
                else { continue }
                if first != second { bad += 1 }
            }
            return bad
        }
        #expect(mismatches == 0)
    }
}
