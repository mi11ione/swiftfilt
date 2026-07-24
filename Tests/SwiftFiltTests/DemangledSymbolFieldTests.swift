// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation
import SwiftFilt
import Testing

/// Every `DemangledSymbol` field asserted exactly on real corpus symbols, plus corpus-wide sweeps with pinned counts.
@Suite("DemangledSymbol curated fields")
struct DemangledSymbolFieldTests {
    // MARK: Construction

    @Test func parsingInitAndOptionalInitAgree() throws {
        let good = "$s4main3fooyyF"
        let symbol = try DemangledSymbol(parsing: good)
        let optional = DemangledSymbol(good)
        #expect(optional == symbol)
        #expect(symbol.mangledName == good)

        #expect(DemangledSymbol("not mangled") == nil)
        #expect(throws: DemangleError.notSwiftMangled) { try DemangledSymbol(parsing: "not mangled") }
        #expect(DemangledSymbol("$sZZZ") == nil)
        #expect(throws: DemangleError.malformed) { try DemangledSymbol(parsing: "$sZZZ") }
    }

    @Test func equalityAndHashingFollowTheParse() throws {
        let a = try DemangledSymbol(parsing: "$s4main3fooyyF")
        let b = try DemangledSymbol(parsing: "$s4main3fooyyF")
        let c = try DemangledSymbol(parsing: "$s4main3baryyF")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    // MARK: One symbol, every field

    @Test func methodFieldsAreExact() throws {
        let symbol = try DemangledSymbol(parsing: "$s4main6ServerC5start4portySi_tF")
        #expect(symbol.kind == .function)
        #expect(symbol.module == "main")
        #expect(symbol.path == ["Server", "start"])
        #expect(symbol.name == "start")
        #expect(symbol.qualifiedName == "main.Server.start")
        #expect(!symbol.isStatic)
        #expect(!symbol.isThunk)
        #expect(!symbol.isSpecialized)
        #expect(symbol.genericOrigin == nil)
        #expect(symbol.flavor == .standard)
        #expect(symbol.description == "main.Server.start(port: Swift.Int) -> ()")
        #expect(symbol.rendered() == symbol.description)
        #expect(symbol.rendered(.simplified) == "Server.start(port:)")
        #expect(symbol.rendered(.qualified) == "main.Server.start(port: Swift.Int) -> ()")
        #expect(symbol.rendered(.unqualified) == "start(port: Int) -> ()")
        #expect(symbol.symbol.kind == .Global)
    }

    @Test func staticGetterFieldsAreExact() throws {
        // static _SwiftData_SwiftUI.Query._propertyBehaviors.getter : Swift.UInt32
        let symbol = try DemangledSymbol(parsing: "$s011_SwiftData_A2UI5QueryV18_propertyBehaviorss6UInt32VvgZ")
        #expect(symbol.kind == .accessor(.getter))
        #expect(symbol.isStatic)
        #expect(symbol.module == "_SwiftData_SwiftUI")
        #expect(symbol.path == ["Query", "_propertyBehaviors"])
        #expect(symbol.name == "_propertyBehaviors")
    }

    @Test func accessorKindsDistinguishGetterSetterModify() throws {
        let base = "$s10XCTHarness038XCTHCrashLogBacktraceBackedByJSONCrashC6ThreadC4nameSSSgv"
        #expect(try DemangledSymbol(parsing: base + "g").kind == .accessor(.getter))
        #expect(try DemangledSymbol(parsing: base + "s").kind == .accessor(.setter))
        #expect(try DemangledSymbol(parsing: base + "M").kind == .accessor(.modify))
    }

    @Test func borrowFamilyAccessorsClassify() throws {
        // The borrow / mutate accessor entities and their yielding
        // (yield-once-2) coroutine twins, each oracle-verified:
        // `vb` borrow, `vz` mutate, `vy` yielding_borrow, `vx` yielding_mutate.
        let base = "$s4main1XV1vSiv"
        #expect(try DemangledSymbol(parsing: base + "b").kind == .accessor(.borrow))
        #expect(try DemangledSymbol(parsing: base + "z").kind == .accessor(.mutate))
        #expect(try DemangledSymbol(parsing: base + "y").kind == .accessor(.yieldingBorrow))
        #expect(try DemangledSymbol(parsing: base + "x").kind == .accessor(.yieldingMutate))
        #expect(try DemangledSymbol(parsing: base + "b").path == ["X", "v"])
    }

    @Test func subscriptDeclarationClassifiesWithSubscriptPath() throws {
        // A legacy subscript entity reference (`swift-demangle`:
        // Meow.MyCls.subscript (i: Swift.Int) -> Swift.Float).
        let symbol = try DemangledSymbol(parsing: "_TiC4Meow5MyCls9subscriptFT1iSi_Sf")
        #expect(symbol.kind == .subscriptDeclaration)
        #expect(symbol.module == "Meow")
        #expect(symbol.path == ["MyCls", "subscript"])
        #expect(symbol.name == "subscript")
    }

    @Test func initializerAndDeinitializerClassify() throws {
        let allocating = try DemangledSymbol(parsing: "$s10Foundation13__NSSwiftDataC20contentsOfMappedFile5errorACSSSg_yttKcfC")
        #expect(allocating.kind == .initializer)
        #expect(allocating.path == ["__NSSwiftData", "init"])
        let initializing = try DemangledSymbol(parsing: "$s10Foundation13__NSSwiftDataC20contentsOfMappedFile5errorACSSSg_yttKcfc")
        #expect(initializing.kind == .initializer)
        let deallocating = try DemangledSymbol(parsing: "$s012_AppIntents_A3Kit0A20EntityViewAnnotationCfD")
        #expect(deallocating.kind == .deinitializer)
        #expect(deallocating.path == ["AppEntityViewAnnotation", "deinit"])
        #expect(deallocating.name == "deinit")

        // ObjC-interop per-ivar entry points (`fe` / `fE`), oracle-verified
        // as __ivar_initializer / __ivar_destroyer.
        let ivarInit = try DemangledSymbol(parsing: "$s4main3FooCfe")
        #expect(ivarInit.kind == .initializer)
        #expect(ivarInit.path == ["Foo", "__ivar_initializer"])
        let ivarDestroy = try DemangledSymbol(parsing: "$s4main3FooCfE")
        #expect(ivarDestroy.kind == .deinitializer)
        #expect(ivarDestroy.path == ["Foo", "__ivar_destroyer"])
    }

    @Test func closureNamesItsHostFunction() throws {
        // closure #1 in static Accelerate.vDSP.meanSquare<…>
        let symbol = try DemangledSymbol(parsing: "$s10Accelerate4vDSPO10meanSquareySdxAA0A6BufferRzSd7ElementRtzlFZySRySdGXEfU_")
        #expect(symbol.kind == .closure)
        #expect(symbol.module == "Accelerate")
        #expect(symbol.path == ["vDSP", "meanSquare"])
        #expect(symbol.name == "meanSquare")
    }

    @Test func specializationFieldsNameTheGenericOrigin() throws {
        let symbol = try DemangledSymbol(parsing:
            "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF12PackageModel24ArtifactsArchiveMetadataV12ArtifactTypeO_Tg5")
        #expect(symbol.kind == .function)
        #expect(symbol.isSpecialized)
        #expect(symbol.genericOrigin
            == "Swift.ContiguousArray._createNewBuffer(bufferIsUnique: Swift.Bool, minimumCapacity: Swift.Int, growForAppend: Swift.Bool) -> ()")
        #expect(symbol.module == "Swift")
        #expect(symbol.path == ["ContiguousArray", "_createNewBuffer"])
    }

    @Test func genericOriginSymbolExposesTheOriginStructurally() throws {
        let symbol = try DemangledSymbol(parsing:
            "$ss15ContiguousArrayV16_createNewBuffer14bufferIsUnique15minimumCapacity13growForAppendySb_SiSbtF12PackageModel24ArtifactsArchiveMetadataV12ArtifactTypeO_Tg5")
        let origin = try #require(symbol.genericOriginSymbol)
        // The structural fields the string form made a consumer re-parse.
        #expect(origin.kind == .function)
        #expect(origin.module == "Swift")
        #expect(origin.path == ["ContiguousArray", "_createNewBuffer"])
        // Consistent with the string form: same tree, same full rendering.
        #expect(origin.rendered(.full) == symbol.genericOrigin)
        // The origin carries its OWN mangled name — the unspecialized
        // symbol's — which re-demangles to the same origin.
        #expect(!origin.mangledName.isEmpty)
        #expect(DemangledSymbol(origin.mangledName)?.rendered(.full) == symbol.genericOrigin)
    }

    @Test func genericOriginSymbolFallsBackToTheSourceManglingWhenTheOriginCannotReMangle() throws {
        // The coroutine-continuation prototype is a documented remangler gap
        // (demangles and renders, but `SwiftMangler` returns nil — KNOWN-DEVIATIONS
        // `remangler-gap-coroutine-continuation`). Wrapped under a specialization
        // marker, its origin renders but can't re-mangle, so genericOriginSymbol
        // falls back to the source symbol's mangled name.
        let coroutine = try DemangledSymbol(parsing:
            "$sxSo8_NSRangeVRlzCRl_Cr0_llySo12ModelRequestCyxq_GIsPetWAlYl_TC")
        let entity = try #require(coroutine.symbol.children.first)
        let specializationTree = SwiftSymbol(kind: .Global, children: [
            SwiftSymbol(kind: .GenericSpecialization),
            entity,
        ])
        let specialized = DemangledSymbol(specializationTree, mangledName: "$sSOURCE")
        #expect(specialized.isSpecialized)
        #expect(specialized.genericOrigin != nil) // renders non-empty
        let origin = try #require(specialized.genericOriginSymbol)
        #expect(origin.mangledName == "$sSOURCE") // remangle failed → source fallback
    }

    @Test func genericOriginSymbolIsNilExactlyWhenTheStringIs() throws {
        // Not a specialization: no origin, structurally or as a string.
        let plain = try DemangledSymbol(parsing: "$s4main3fooyyF")
        #expect(plain.genericOriginSymbol == nil && plain.genericOrigin == nil)
        // Specialized, but removing the markers leaves no entity.
        let empty = try DemangledSymbol(parsing: "$sSi_Tg5Sd_Tg5")
        #expect(empty.genericOriginSymbol == nil && empty.genericOrigin == nil)
        // Specialized, but the one remaining child renders empty (a
        // degenerate origin) — nil, never a symbol wrapping an empty render.
        let degenerate = try DemangledSymbol(parsing: "$sRv_Si_Tg5")
        #expect(degenerate.genericOriginSymbol == nil && degenerate.genericOrigin == nil)
        // Present exactly when the string form is present.
        let present = try DemangledSymbol(parsing: "$sSiTP0_")
        #expect(present.genericOriginSymbol != nil && present.genericOrigin != nil)
    }

    @Test func thunkKindsClassify() throws {
        // Dispatch thunk (Tj).
        let dispatch = try DemangledSymbol(parsing: "$s012_AppIntents_A3Kit0A20EntityViewAnnotationC6entity5stateACx_0aB00aD11VisualStateVtcAF0aD0RzlufCTj")
        #expect(dispatch.kind == .thunk(.dispatch))
        #expect(dispatch.isThunk)
        // Partial apply forwarder (TA).
        let forwarder = try DemangledSymbol(parsing: "$s10Accelerate4vDSPO10meanSquareySdxAA0A6BufferRzSd7ElementRtzlFZySRySdGXEfU_TA")
        #expect(forwarder.kind == .thunk(.partialApply))
        #expect(forwarder.isThunk)
        // Reabstraction thunk (TR): no statically-named target, module nil.
        let reabstraction = try DemangledSymbol(parsing: "$s10CAFCombine31CAFRemoteNotificationObservableCAA017CAFRequestContentD0CIeggg_AC_AEtIegn_TR")
        #expect(reabstraction.kind == .thunk(.reabstraction))
        #expect(reabstraction.module == nil)
        #expect(reabstraction.path.isEmpty)
        // Key-path thunk helper (TK) names its property.
        let keyPath = try DemangledSymbol(parsing: "$s10Accelerate10QuadratureV17absoluteToleranceSdvpACTK")
        #expect(keyPath.kind == .thunk(.keyPath))
        #expect(keyPath.path == ["Quadrature", "absoluteTolerance"])
    }

    @Test func objCBridgingMarkerMakesTheEntityAThunk() throws {
        let bridged = try DemangledSymbol(parsing: "$s10Foundation13__NSSwiftDataC20contentsOfMappedFile5errorACSSSg_yttKcfcTo")
        #expect(bridged.kind == .initializer, "the kind stays the entity's; @objc-ness is thunk-ness")
        #expect(bridged.isThunk)
        let plain = try DemangledSymbol(parsing: "$s10Foundation13__NSSwiftDataC20contentsOfMappedFile5errorACSSSg_yttKcfc")
        #expect(!plain.isThunk)
    }

    @Test func protocolWitnessFields() throws {
        let witness = try DemangledSymbol(parsing: "$s013CompilerSwiftA21PluginMessageHandling0C7FeatureOSQAASQ2eeoiySbx_xtFZTW")
        #expect(witness.kind == .protocolWitness)
        #expect(witness.isThunk)
        #expect(witness.module == "CompilerSwiftCompilerPluginMessageHandling")
        #expect(witness.path == ["PluginFeature", "=="])
        #expect(witness.name == "==")
    }

    @Test func typeAndMetadataSymbolsClassifyAndNameTheirType() throws {
        let legacyClass = try DemangledSymbol(parsing: "_TtC4test3Foo")
        #expect(legacyClass.kind == .type)
        #expect(legacyClass.module == "test")
        #expect(legacyClass.path == ["Foo"])

        let bareType = try DemangledSymbol(parsing: "$sSi")
        #expect(bareType.kind == .type)
        #expect(bareType.qualifiedName == "Swift.Int")

        let descriptor = try DemangledSymbol(parsing: "$s011_SwiftData_A2UI13ModelDocumentVMn")
        #expect(descriptor.kind == .metadata(.typeDescriptor))
        #expect(descriptor.path == ["ModelDocument"])

        let witnessTable = try DemangledSymbol(parsing: "$s013CompilerSwiftA21PluginMessageHandling0C7FeatureOWV")
        #expect(witnessTable.kind == .metadata(.valueWitness))
        #expect(witnessTable.module == "CompilerSwiftCompilerPluginMessageHandling")
        #expect(witnessTable.path == ["PluginFeature"])
    }

    @Test func macroExpansionFields() throws {
        let macro = try DemangledSymbol(parsing: "@__swiftmacro_18macro_expand_peers1SV1f20addCompletionHandlerfMp_")
        #expect(macro.kind == .macro)
        #expect(macro.module == "macro_expand_peers")
        #expect(macro.path == ["S", "f", "addCompletionHandler"])
        #expect(macro.name == "addCompletionHandler")
    }

    @Test func enumCaseRecordsClassify() throws {
        let record = try DemangledSymbol(parsing:
            "$s013CompilerSwiftA21PluginMessageHandling06HostTocD0O04loadC7LibraryyACSS_SStcACmFWC")
        #expect(record.kind == .enumCase)
        #expect(record.module == "CompilerSwiftCompilerPluginMessageHandling")
        #expect(record.path == ["HostToPluginMessage", "loadPluginLibrary"])
    }

    @Test func embeddedFlavorIsDetected() throws {
        #expect(try DemangledSymbol(parsing: "$e4main3fooyyF").flavor == .embedded)
        #expect(try DemangledSymbol(parsing: "_$e4main3fooyyF").flavor == .embedded)
        #expect(try DemangledSymbol(parsing: "$s4main3fooyyF").flavor == .standard)
        #expect(try DemangledSymbol(parsing: "_TtC4test3Foo").flavor == .standard)
    }

    @Test func suffixedSymbolKeepsItsEntityFields() throws {
        let suffixed = try DemangledSymbol(parsing:
            "$s013CompilerSwiftA21PluginMessageHandling0cD0O10DiagnosticV13PositionRangeV11startOffsetSivM.resume.0")
        #expect(suffixed.kind == .accessor(.modify))
        #expect(suffixed.name == "startOffset")
    }

    @Test func staticTypeManglingReportsStaticAndType() throws {
        // `$sSiZ` demangles (oracle: "static Swift.Int"): a Static shell
        // over a type mangling — kind stays .type, isStatic is true, and
        // the walk recurses through the shell for the name.
        let staticType = try DemangledSymbol(parsing: "$sSiZ")
        #expect(staticType.kind == .type)
        #expect(staticType.isStatic)
        #expect(staticType.qualifiedName == "Swift.Int")

        // The plain type mangling recurses Type -> Structure: not static.
        let plain = try DemangledSymbol(parsing: "$sSiD")
        #expect(plain.kind == .type)
        #expect(!plain.isStatic)
    }

    @Test func signatureOnlyThunkHasNoModuleAndPathOnlyQualifiedName() throws {
        // A reabstraction thunk mangles only its signatures: no defining
        // module exists, and the qualified name is exactly the (empty)
        // path joined — never a fabricated component.
        let thunk = try DemangledSymbol(parsing: "$sIeg_ytIegr_TR")
        #expect(thunk.kind == .thunk(.reabstraction))
        #expect(thunk.module == nil)
        #expect(thunk.path.isEmpty)
        #expect(thunk.name == nil)
        #expect(thunk.qualifiedName == "")
    }

    // MARK: Degenerate-but-parseable shapes

    // Grammar admits globals the compiler never emits (bare forwarders,
    // attribute-only globals, pack markers); every field must answer
    // deterministically, and each mangling parses on `swift-demangle` too.

    @Test func bareForwarderClassifiesAsItsOwnThunk() throws {
        // `$sTA` (oracle: "partial apply forwarder"): a forwarder with no
        // target — kind is the thunk itself, nothing is named.
        let forwarder = try DemangledSymbol(parsing: "$sTA")
        #expect(forwarder.kind == .thunk(.partialApply))
        #expect(forwarder.module == nil)
        #expect(forwarder.path.isEmpty)
        #expect(forwarder.description == "partial apply forwarder")
    }

    @Test func twinSpecializationAttributesCancelStructurally() throws {
        // `$sSi_Tg5Si_Tg5`: two byte-identical generic-specialization
        // attributes and no entity (the oracle renders the same nested-of
        // form). The attribute walk excludes the primary node by
        // structural equality, so the identical twin is excluded with it:
        // not specialized, no origin, out of the curated buckets.
        let stacked = try DemangledSymbol(parsing: "$sSi_Tg5Si_Tg5")
        #expect(stacked.kind == .other)
        #expect(!stacked.isSpecialized)
        #expect(stacked.genericOrigin == nil)
    }

    @Test func suffixSurfacesTheUnmangledTail() throws {
        // The dot-glued linker tail (`.stub`/`.got` and friends) distinguishes
        // physical atoms that share one logical identity.
        let stub = try DemangledSymbol(parsing: "_$s10Foundation11JSONEncoderCACycfc.stub")
        #expect(stub.suffix == ".stub")
        let got = try DemangledSymbol(parsing: "_$s10Foundation11JSONEncoderCACycfc.got")
        #expect(got.suffix == ".got")
        #expect(stub.identityKey == got.identityKey, "one logical identity")
        let plain = try DemangledSymbol(parsing: "$s4main3fooyyF")
        #expect(plain.suffix == nil)
    }

    @Test func kindSpellingsMatchTheJSONAndCensusVocabulary() throws {
        // `name` is the --json `kind` field; interpolation (description)
        // is the census table key — qualified for payload kinds.
        let getter = try DemangledSymbol(parsing: "$s10Foundation4DataV5countSivg")
        #expect(getter.kind.name == "accessor")
        #expect("\(getter.kind)" == "accessor.getter")
        let function = try DemangledSymbol(parsing: "$s4main3fooyyF")
        #expect(function.kind.name == "function")
        #expect("\(function.kind)" == "function")
        let metadata = try DemangledSymbol(parsing: "$s4main1SVMn")
        #expect(metadata.kind.name == "metadata")
        #expect("\(metadata.kind)" == "metadata.typeDescriptor")
        if case let .metadata(payload) = metadata.kind {
            #expect(payload.name == "typeDescriptor")
            #expect("\(payload)" == "typeDescriptor")
        }
        let curry = try DemangledSymbol(parsing: "$s4main3fooyyFTc")
        #expect("\(curry.kind)" == "thunk.curry")
        if case let .thunk(payload) = curry.kind {
            #expect("\(payload)" == "curry")
        }
        if case let .accessor(payload) = getter.kind {
            #expect("\(payload)" == "getter")
        }
    }

    @Test func compilerGeneratedMatchesTheCensusSplit() throws {
        // The library predicate IS the census machinery/human split.
        #expect(try DemangledSymbol(parsing: "$s4main3fooyyFTc").isCompilerGenerated) // thunk
        #expect(try DemangledSymbol(parsing: "$s4main1SVMn").isCompilerGenerated) // metadata
        #expect(try DemangledSymbol(parsing: "$s4main1SV1xSivpfi").isCompilerGenerated) // variable initializer
        #expect(try DemangledSymbol(parsing: "$s4main3fooyySiFfA_").isCompilerGenerated) // default argument
        #expect(try !DemangledSymbol(parsing: "$s4main3fooyyF").isCompilerGenerated) // function
        #expect(try !DemangledSymbol(parsing: "$s10Foundation4DataV5countSivg").isCompilerGenerated) // accessor
    }

    @Test func specializationOfNothingHasNoGenericOrigin() throws {
        // `$sSi_Tg5Sd_Tg5`: two stacked specializations with different
        // payloads and no entity. The symbol is specialized, but removing
        // the specialization markers leaves nothing — genericOrigin must
        // be nil, not "".
        let stacked = try DemangledSymbol(parsing: "$sSi_Tg5Sd_Tg5")
        #expect(stacked.isSpecialized)
        #expect(stacked.genericOrigin == nil)

        // `$sRv_Si_Tg5`: a specialization whose only other child is a
        // dependent-generic pack marker, which renders to nothing (the
        // reference printer aborts on a bare marker; ours renders the
        // empty string) — the empty origin rendering must become nil.
        let markerOrigin = try DemangledSymbol(parsing: "$sRv_Si_Tg5")
        #expect(markerOrigin.isSpecialized)
        #expect(markerOrigin.genericOrigin == nil)

        // `$sSiTP0_` keeps its first-element-marker sibling, so the same
        // walk yields a non-empty origin: present exactly when renderable.
        let markerSibling = try DemangledSymbol(parsing: "$sSiTP0_")
        #expect(markerSibling.isSpecialized)
        #expect(markerSibling.genericOrigin == " first-element-marker ")
    }

    @Test func packMarkerGlobalsRenderEmptyInEveryStyle() throws {
        // `$sRv_` (bare pack marker) and `$syxD` (label-list type mangling
        // of a dependent generic param): both parse, and every style
        // renders them empty — the degenerate class the reference printer
        // refuses (it aborts on the marker; it echoes `$syxD`).
        for mangled in ["$sRv_", "$syxD"] {
            let symbol = try DemangledSymbol(parsing: mangled)
            for style in DemangleStyle.allCases {
                #expect(symbol.rendered(style).isEmpty, "\(mangled) must render empty in \(style)")
            }
            #expect(symbol.identityKey.rawValue == mangled, "the key falls back to the mangled name")
        }
    }

    // MARK: Corpus-wide sweeps (pinned coverage)

    @Test func everyCorpusRowBuildsAndRendersAtFixtureParity() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        let failures = await onLargeStack { () -> [String] in
            var fails: [String] = []
            for row in rows {
                guard let symbol = DemangledSymbol(row.mangled) else {
                    fails.append("L\(row.lineNumber): init? nil")
                    continue
                }
                if symbol.mangledName != row.mangled { fails.append("L\(row.lineNumber): mangledName mutated") }
                if SwiftDemanglerCorpusParity.oracleDeclined(row.compact, for: row) { continue }
                if symbol.description != row.compact {
                    fails.append("L\(row.lineNumber): description != -compact fixture")
                }
                if symbol.rendered(.simplified) != row.simplified,
                   !SwiftDemanglerCorpusParity.oracleDeclined(row.simplified, for: row)
                {
                    fails.append("L\(row.lineNumber): simplified mismatch")
                }
                if symbol.rendered(.qualified) != row.noSugar,
                   !SwiftDemanglerCorpusParity.oracleDeclined(row.noSugar, for: row)
                {
                    fails.append("L\(row.lineNumber): qualified mismatch")
                }
            }
            return fails
        }
        #expect(failures.isEmpty, "\(failures.count) failures; first: \(failures.first ?? "")")
    }

    /// The classification and naming walks, held to pinned corpus-wide
    /// coverage: how many of the 10,105 real symbols fall out of the curated
    /// buckets (grammar corners only) and how many carry no statically-named
    /// module (signature-only thunks and module-less structural types only).
    /// A regression in either walk moves these counts.
    @Test func corpusClassificationCoverageIsPinned() async throws {
        let rows = try SwiftDemanglerCorpusParity.loadRows()
        try #require(rows.count == 10105, "fixture snapshot changed; re-pin the coverage counts")
        let (otherCount, nilModuleCount, emptyKeyCount, originMismatch) = await onLargeStack { () -> (Int, Int, Int, Int) in
            var other = 0, nilModule = 0, emptyKey = 0, origin = 0
            for row in rows {
                guard let symbol = DemangledSymbol(row.mangled) else { continue }
                if symbol.kind == .other { other += 1 }
                if symbol.module == nil { nilModule += 1 }
                if symbol.identityKey.rawValue.isEmpty { emptyKey += 1 }
                if (symbol.genericOrigin != nil) != symbol.isSpecialized { origin += 1 }
            }
            return (other, nilModule, emptyKey, origin)
        }
        #expect(otherCount == 13, "curated-kind fallout changed: \(otherCount)")
        #expect(nilModuleCount == 435, "module-extraction coverage changed: \(nilModuleCount)")
        #expect(emptyKeyCount == 0, "identity keys must never be empty")
        #expect(originMismatch == 0, "genericOrigin must be present exactly when isSpecialized")
    }
}
