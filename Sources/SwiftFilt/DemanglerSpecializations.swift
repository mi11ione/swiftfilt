// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Thunks, generic / function-signature specializations, witnesses, and
// autodiff for the current-mangling `Demangler` — ported from
// `lib/Demangling/Demangler.cpp`.

/// `FunctionSigSpecializationParamKind` from apple/swift's `Demangle.h`.
private enum FuncSpecParamKind {
    static let constantPropFunction: UInt64 = 0
    static let constantPropGlobal: UInt64 = 1
    static let constantPropInteger: UInt64 = 2
    static let constantPropFloat: UInt64 = 3
    static let constantPropString: UInt64 = 4
    static let closureProp: UInt64 = 5
    static let boxToValue: UInt64 = 6
    static let boxToStack: UInt64 = 7
    static let inOutToOut: UInt64 = 8
    static let constantPropKeyPath: UInt64 = 9
    static let constantPropStruct: UInt64 = 10
    static let closurePropPreviousArg: UInt64 = 11
    static let dead: UInt64 = 1 << 6
    static let ownedToGuaranteed: UInt64 = 1 << 7
    static let sroa: UInt64 = 1 << 8
    static let guaranteedToOwned: UInt64 = 1 << 9
    static let existentialToGeneric: UInt64 = 1 << 10
}

private let maxSpecializationPass = 10

extension Demangler {
    mutating func demangleThunkOrSpecialization() -> B.Node? {
        let c = nextChar()
        switch c {
        case 0x54: // 'T'
            switch nextChar() {
            case 0x49: return createWithChild(.SILThunkIdentity, popNode(DemanglerPredicates.isEntity)) // 'I'
            default: return nil
            }
        case 0x63: return createWithChild(.CurryThunk, popNode(DemanglerPredicates.isEntity)) // 'c'
        case 0x6A: return createWithChild(.DispatchThunk, popNode(DemanglerPredicates.isEntity)) // 'j'
        case 0x71: return createWithChild(.MethodDescriptor, popNode(DemanglerPredicates.isEntity)) // 'q'
        case 0x6F: return nb.make(kind: .ObjCAttribute) // 'o'
        case 0x4F: return nb.make(kind: .NonObjCAttribute) // 'O'
        case 0x44: return nb.make(kind: .DynamicAttribute) // 'D'
        case 0x64: return nb.make(kind: .DirectMethodReferenceAttribute) // 'd'
        case 0x45: return nb.make(kind: .DistributedThunk) // 'E'
        case 0x46: return nb.make(kind: .DistributedAccessor) // 'F'
        case 0x61: return nb.make(kind: .PartialApplyObjCForwarder) // 'a'
        case 0x41: return nb.make(kind: .PartialApplyForwarder) // 'A'
        case 0x6D: return nb.make(kind: .MergedFunction) // 'm'
        case 0x58: return nb.make(kind: .DynamicallyReplaceableFunctionVar) // 'X'
        case 0x78: return nb.make(kind: .DynamicallyReplaceableFunctionKey) // 'x'
        case 0x49: return nb.make(kind: .DynamicallyReplaceableFunctionImpl) // 'I'
        case 0x59, 0x51: // 'Y' suspend / 'Q' await
            let discriminator = demangleIndexAsNode()
            return createWithChild(c == 0x51 ? .AsyncAwaitResumePartialFunction : .AsyncSuspendResumePartialFunction,
                                   discriminator)
        case 0x43: // 'C'
            return createWithChild(.CoroutineContinuationPrototype, popNode(.`Type`))
        case 0x7A, 0x5A: // 'z' / 'Z' ObjC async completion handler impl
            let flagMode = demangleIndexAsNode()
            let sig = popNode(.DependentGenericSignature)
            let resultType = popNode(.`Type`)
            let implType = popNode(.`Type`)
            var node = createWithChildren(c == 0x7A ? .ObjCAsyncCompletionHandlerImpl : .CheckedObjCAsyncCompletionHandlerImpl,
                                          implType, resultType, flagMode)
            if let sig { node = addChild(node, sig) }
            return node
        case 0x56: // 'V'
            let base = popNode(DemanglerPredicates.isEntity)
            let derived = popNode(DemanglerPredicates.isEntity)
            return createWithChildren(.VTableThunk, derived, base)
        case 0x57: // 'W'
            let entity = popNode(DemanglerPredicates.isEntity)
            let conf = popProtocolConformance()
            return createWithChildren(.ProtocolWitness, conf, entity)
        case 0x53: // 'S'
            return createWithChild(.ProtocolSelfConformanceWitness, popNode(DemanglerPredicates.isEntity))
        case 0x52, 0x72, 0x79: // 'R','r','y' reabstraction thunks
            let kind: SwiftSymbol.Kind = if c == 0x52 { .ReabstractionThunkHelper }
            else if c == 0x79 { .ReabstractionThunkHelperWithSelf }
            else { .ReabstractionThunk }
            // The from/to types (and the self type for the with-self helper) are
            // required; a missing operand propagates nil rather than yielding a
            // childless thunk (matching the reference's `Thunk = addChild(...)`).
            var thunk: B.Node? = nb.make(kind: kind)
            if let genSig = popNode(.DependentGenericSignature) { thunk = addChild(thunk, genSig) }
            if kind == .ReabstractionThunkHelperWithSelf {
                thunk = addChild(thunk, popNode(.`Type`))
            }
            thunk = addChild(thunk, popNode(.`Type`))
            thunk = addChild(thunk, popNode(.`Type`))
            return thunk
        case 0x67: return demangleGenericSpecialization(.GenericSpecialization, droppedArguments: nil) // 'g'
        case 0x47: return demangleGenericSpecialization(.GenericSpecializationNotReAbstracted, droppedArguments: nil) // 'G'
        case 0x42: return demangleGenericSpecialization(.GenericSpecializationInResilienceDomain, droppedArguments: nil) // 'B'
        case 0x74: return demangleGenericSpecializationWithDroppedArguments() // 't'
        case 0x73: return demangleGenericSpecialization(.GenericSpecializationPrespecialized, droppedArguments: nil) // 's'
        case 0x69: return demangleGenericSpecialization(.InlinedGenericFunction, droppedArguments: nil) // 'i'
        case 0x70: // 'p'
            let spec = demangleSpecAttributes(.GenericPartialSpecialization)
            let param = createWithChild(.GenericSpecializationParam, popNode(.`Type`))
            return addChild(spec, param)
        case 0x50: // 'P'
            let spec = demangleSpecAttributes(.GenericPartialSpecializationNotReAbstracted)
            let param = createWithChild(.GenericSpecializationParam, popNode(.`Type`))
            return addChild(spec, param)
        case 0x66: return demangleFunctionSpecialization() // 'f'
        case 0x4B, 0x6B: return demangleKeyPathThunk(c) // 'K','k'
        case 0x6C: // 'l'
            guard let assocTypeName = popAssocTypeName() else { return nil }
            return createWithChild(.AssociatedTypeDescriptor, assocTypeName)
        case 0x4C: return createWithChild(.ProtocolRequirementsBaseDescriptor, popProtocol()) // 'L'
        case 0x4D: return createWithChild(.DefaultAssociatedTypeMetadataAccessor, popAssocTypeName()) // 'M'
        case 0x6E: // 'n'
            let requirementTy = popProtocol()
            let subject = popAssociatedConformanceWitnessAccessorSubject()
            let protoTy = popNode(.`Type`)
            return createWithChildren(.AssociatedConformanceDescriptor, protoTy, subject, requirementTy)
        case 0x4E: // 'N'
            let requirementTy = popProtocol()
            let subject = popAssociatedConformanceWitnessAccessorSubject()
            let protoTy = popNode(.`Type`)
            return createWithChildren(.DefaultAssociatedConformanceAccessor, protoTy, subject, requirementTy)
        case 0x62: // 'b'
            let requirementTy = popProtocol()
            let protoTy = popNode(.`Type`)
            return createWithChildren(.BaseConformanceDescriptor, protoTy, requirementTy)
        case 0x48, 0x68: return demangleKeyPathEqualsHashThunk(c) // 'H','h'
        case 0x76: // 'v'
            let idx = demangleIndex()
            if idx < 0 { return nil }
            if nextChar() == 0x72 { return nb.make(kind: .OutlinedReadOnlyObject, index: UInt64(idx)) } // 'r'
            return nb.make(kind: .OutlinedVariable, index: UInt64(idx))
        case 0x65: // 'e'
            let params = demangleBridgedMethodParams()
            if params.isEmpty { return nil }
            return nb.make(kind: .OutlinedBridgedMethod, name: params)
        case 0x75: return nb.make(kind: .AsyncFunctionPointer) // 'u'
        case 0x55: // 'U'
            guard let globalActor = popNode(.`Type`), let reabstraction = popNode() else { return nil }
            return nb.make(kind: .ReabstractionThunkHelperWithGlobalActor, children: [reabstraction, globalActor])
        case 0x4A: // 'J'
            switch peekChar() {
            case 0x53: pos += 1; return demangleAutoDiffSubsetParametersThunk() // 'S'
            case 0x4F: pos += 1; return demangleAutoDiffSelfReorderingReabstractionThunk() // 'O'
            case 0x56: pos += 1; return demangleAutoDiffFunctionOrSimpleThunk(.AutoDiffDerivativeVTableThunk) // 'V'
            default: return demangleAutoDiffFunctionOrSimpleThunk(.AutoDiffFunction)
            }
        case 0x77: // 'w'
            switch nextChar() {
            case 0x62: return nb.make(kind: .BackDeploymentThunk) // 'b'
            case 0x42: return nb.make(kind: .BackDeploymentFallback) // 'B'
            case 0x63: return nb.make(kind: .CoroFunctionPointer) // 'c'
            case 0x64: return nb.make(kind: .DefaultOverride) // 'd'
            case 0x53: return nb.make(kind: .HasSymbolQuery) // 'S'
            default: return nil
            }
        default: return nil
        }
    }

    private mutating func demangleKeyPathThunk(_ c: UInt8) -> B.Node? {
        let nodeKind: SwiftSymbol.Kind = if nextIf(Array("mu".utf8)) {
            .KeyPathUnappliedMethodThunkHelper
        } else if nextIf(Array("MA".utf8)) {
            .KeyPathAppliedMethodThunkHelper
        } else {
            c == 0x4B ? .KeyPathGetterThunkHelper : .KeyPathSetterThunkHelper
        }
        let isSerialized = nextIf(0x71) // 'q'
        var types: [B.Node] = []
        guard var node = popNode(), nb.kind(of: node) == .`Type` else { return nil }
        repeat {
            types.append(node)
            guard let next = popNode() else { break }
            node = next
        } while nb.kind(of: node) == .`Type`
        // `node` now holds the first non-Type node (decl or sig) or the last Type.
        var result: B.Node?
        let last = nodeStackLastConsumed(types: types, node: node)
        if let last {
            if nb.kind(of: last) == .DependentGenericSignature {
                guard let decl = popNode() else { return nil }
                result = createWithChildren(nodeKind, decl, last)
            } else {
                result = createWithChild(nodeKind, last)
            }
        } else {
            return nil
        }
        for t in types.reversed() {
            result = addChild(result, t)
        }
        if isSerialized { result = addChild(result, nb.make(kind: .IsSerialized)) }
        return result
    }

    /// Helper resolving the trailing decl/sig node consumed by the key-path
    /// thunk loop (`node` is the first non-Type popped, or the final Type when
    /// the stack was all types).
    private mutating func nodeStackLastConsumed(types _: [B.Node], node: B.Node) -> B.Node? {
        nb.kind(of: node) == .`Type` ? nil : node
    }

    private mutating func demangleKeyPathEqualsHashThunk(_ c: UInt8) -> B.Node? {
        let nodeKind: SwiftSymbol.Kind = c == 0x48 ? .KeyPathEqualsThunkHelper : .KeyPathHashThunkHelper
        let isSerialized = nextIf(0x71) // 'q'
        var genericSig: B.Node?
        var types: [B.Node] = []
        guard let node = popNode() else { return nil }
        if nb.kind(of: node) == .DependentGenericSignature {
            genericSig = node
        } else if nb.kind(of: node) == .`Type` {
            types.append(node)
        } else {
            return nil
        }
        while let n = popNode() {
            if nb.kind(of: n) != .`Type` { return nil }
            types.append(n)
        }
        var result = nb.make(kind: nodeKind)
        for t in types.reversed() {
            nb.appendChild(to: &result, t)
        }
        if let genericSig { nb.appendChild(to: &result, genericSig) }
        if isSerialized { nb.appendChild(to: &result, nb.make(kind: .IsSerialized)) }
        return result
    }

    mutating func demangleAutoDiffFunctionOrSimpleThunk(_ nodeKind: SwiftSymbol.Kind) -> B.Node? {
        var result = nb.make(kind: nodeKind)
        while let original = popNode() {
            nb.appendChild(to: &result, original)
        }
        nb.reverseChildren(of: &result)
        guard let kind = demangleAutoDiffFunctionKind() else { return nil }
        nb.appendChild(to: &result, kind)
        guard let subset1 = demangleIndexSubset() else { return nil }
        nb.appendChild(to: &result, subset1)
        guard nextIf(0x70) else { return nil } // 'p'
        guard let subset2 = demangleIndexSubset() else { return nil }
        nb.appendChild(to: &result, subset2)
        guard nextIf(0x72) else { return nil } // 'r'
        return result
    }

    mutating func demangleAutoDiffFunctionKind() -> B.Node? {
        let kind = nextChar()
        guard kind == 0x66 || kind == 0x72 || kind == 0x64 || kind == 0x70 else { return nil } // f,r,d,p
        return nb.make(kind: .AutoDiffFunctionKind, index: UInt64(kind))
    }

    mutating func demangleAutoDiffSubsetParametersThunk() -> B.Node? {
        var result = nb.make(kind: .AutoDiffSubsetParametersThunk)
        while let node = popNode() {
            nb.appendChild(to: &result, node)
        }
        nb.reverseChildren(of: &result)
        guard let kind = demangleAutoDiffFunctionKind() else { return nil }
        nb.appendChild(to: &result, kind)
        guard let s1 = demangleIndexSubset() else { return nil }
        nb.appendChild(to: &result, s1)
        guard nextIf(0x70) else { return nil } // 'p'
        guard let s2 = demangleIndexSubset() else { return nil }
        nb.appendChild(to: &result, s2)
        guard nextIf(0x72) else { return nil } // 'r'
        guard let s3 = demangleIndexSubset() else { return nil }
        nb.appendChild(to: &result, s3)
        guard nextIf(0x50) else { return nil } // 'P'
        return result
    }

    mutating func demangleAutoDiffSelfReorderingReabstractionThunk() -> B.Node? {
        var result = nb.make(kind: .AutoDiffSelfReorderingReabstractionThunk)
        if let sig = popNode(.DependentGenericSignature) { nb.appendChild(to: &result, sig) }
        if let t = popNode(.`Type`) { nb.appendChild(to: &result, t) }
        if let t = popNode(.`Type`) { nb.appendChild(to: &result, t) }
        nb.reverseChildren(of: &result)
        guard let kind = demangleAutoDiffFunctionKind() else { return nil }
        nb.appendChild(to: &result, kind)
        return result
    }

    mutating func demangleDifferentiabilityWitness() -> B.Node? {
        var result = nb.make(kind: .DifferentiabilityWitness)
        let optionalGenSig = popNode(.DependentGenericSignature)
        while let node = popNode() {
            nb.appendChild(to: &result, node)
        }
        nb.reverseChildren(of: &result)
        let kind: UInt64
        switch nextChar() {
        case 0x66: kind = UInt64(UInt8(ascii: "f")) // Forward
        case 0x72: kind = UInt64(UInt8(ascii: "r")) // Reverse
        case 0x64: kind = UInt64(UInt8(ascii: "d")) // Normal
        case 0x6C: kind = UInt64(UInt8(ascii: "l")) // Linear
        default: return nil
        }
        nb.appendChild(to: &result, nb.make(kind: .Index, index: kind))
        guard let s1 = demangleIndexSubset() else { return nil }
        nb.appendChild(to: &result, s1)
        guard nextIf(0x70) else { return nil } // 'p'
        guard let s2 = demangleIndexSubset() else { return nil }
        nb.appendChild(to: &result, s2)
        guard nextIf(0x72) else { return nil } // 'r'
        if let optionalGenSig { nb.appendChild(to: &result, optionalGenSig) }
        return result
    }

    mutating func demangleIndexSubset() -> B.Node? {
        var str: [UInt8] = []
        while peekChar() == 0x53 || peekChar() == 0x55 { // 'S','U'
            str.append(nextChar())
        }
        if str.isEmpty { return nil }
        return nb.make(kind: .IndexSubset, name: String(decoding: str, as: UTF8.self))
    }

    mutating func demangleDifferentiableFunctionType() -> B.Node? {
        let kind: UInt64
        switch nextChar() {
        case 0x66: kind = UInt64(UInt8(ascii: "f"))
        case 0x72: kind = UInt64(UInt8(ascii: "r"))
        case 0x64: kind = UInt64(UInt8(ascii: "d"))
        case 0x6C: kind = UInt64(UInt8(ascii: "l"))
        default: return nil
        }
        return nb.make(kind: .DifferentiableFunctionType, index: kind)
    }

    mutating func demangleBridgedMethodParams() -> String {
        if nextIf(0x5F) { return "" } // '_'
        var str: [UInt8] = []
        let kind = nextChar()
        switch kind {
        case 0x6F, 0x70, 0x61, 0x6D: str.append(kind) // 'o','p','a','m'
        default: return ""
        }
        while !nextIf(0x5F) { // '_'
            let c = nextChar()
            if c != 0x6E, c != 0x62, c != 0x67 { return "" } // 'n','b','g'
            str.append(c)
        }
        return String(decoding: str, as: UTF8.self)
    }

    // MARK: Generic / function-signature specializations

    mutating func demangleGenericSpecialization(_ specKind: SwiftSymbol.Kind, droppedArguments: B.Node?) -> B.Node? {
        guard var spec = demangleSpecAttributes(specKind) else { return nil }
        if let droppedArguments {
            for a in 0 ..< nb.childCount(of: droppedArguments) {
                nb.appendChild(to: &spec, nb.child(of: droppedArguments, at: a))
            }
        }
        guard let typeList = popTypeList() else { return nil }
        for i in 0 ..< nb.childCount(of: typeList) {
            guard let param = createWithChild(.GenericSpecializationParam, nb.child(of: typeList, at: i)) else { return nil }
            nb.appendChild(to: &spec, param)
        }
        return spec
    }

    mutating func demangleGenericSpecializationWithDroppedArguments() -> B.Node? {
        pushBack()
        var tmp = nb.make(kind: .GenericSpecialization)
        while nextIf(0x74) { // 't'
            let n = demangleNatural()
            nb.appendChild(to: &tmp, nb.make(kind: .DroppedArgument, index: UInt64(n < 0 ? 0 : n + 1)))
        }
        let specKind: SwiftSymbol.Kind
        switch nextChar() {
        case 0x67: specKind = .GenericSpecialization // 'g'
        case 0x47: specKind = .GenericSpecializationNotReAbstracted // 'G'
        case 0x42: specKind = .GenericSpecializationInResilienceDomain // 'B'
        default: return nil
        }
        return demangleGenericSpecialization(specKind, droppedArguments: tmp)
    }

    mutating func demangleFunctionSpecialization() -> B.Node? {
        guard var spec = demangleSpecAttributes(.FunctionSignatureSpecialization) else { return nil }
        if let fc = nb.firstChild(of: spec), nb.kind(of: fc) == .RepresentationChanged { return spec }
        while !nextIf(0x5F) { // '_'
            guard let param = demangleFuncSpecParam(.FunctionSignatureSpecializationParam) else { return nil }
            nb.appendChild(to: &spec, param)
        }
        if !nextIf(0x6E) { // 'n'
            guard let ret = demangleFuncSpecParam(.FunctionSignatureSpecializationReturn) else { return nil }
            nb.appendChild(to: &spec, ret)
        }

        // Fill in the deferred operands (identifiers / types) for each param,
        // in reverse order, then reverse each param's fixed children.
        let count = nb.childCount(of: spec)
        for idx in 0 ..< count {
            let paramIndex = count - idx - 1
            var param = nb.child(of: spec, at: paramIndex)
            guard nb.kind(of: param) == .FunctionSignatureSpecializationParam else { continue }
            let fixedChildren = nb.childCount(of: param)
            for childIdx in 0 ..< fixedChildren {
                let kindNode = nb.child(of: param, at: fixedChildren - childIdx - 1)
                guard nb.kind(of: kindNode) == .FunctionSignatureSpecializationParamKind,
                      let kindValue = nb.index(of: kindNode) else { continue }
                switch kindValue {
                case FuncSpecParamKind.closureProp:
                    while let ty = popNode(.`Type`) {
                        nb.appendChild(to: &param, ty)
                    }
                case FuncSpecParamKind.constantPropKeyPath:
                    if let t = popNode(.`Type`) { nb.appendChild(to: &param, t) }
                    if let t = popNode(.`Type`) { nb.appendChild(to: &param, t) }
                case FuncSpecParamKind.constantPropStruct:
                    if let t = popNode(.`Type`) { nb.appendChild(to: &param, t) }
                    continue
                case FuncSpecParamKind.constantPropFunction, FuncSpecParamKind.constantPropGlobal,
                     FuncSpecParamKind.constantPropString:
                    break
                default:
                    continue
                }
                // The propagated operand (closure / constant-prop function name,
                // string content) is kept as a plain `Identifier` holding the raw
                // mangled text — matching swift-demangle, which does NOT recurse
                // into it and keeps a ConstantPropString's leading `_` escape
                // verbatim in the tree (it is dropped only on PRINT). The remangler
                // reads this child positionally via mangleIdentifierImpl, so the
                // node kind is re-mangle-agnostic and the escape round-trips.
                if let ident = popNode(.Identifier) {
                    nb.appendChild(to: &param, nb.make(kind: .Identifier, name: nb.text(of: ident) ?? ""))
                }
            }
            if nb.childCount(of: param) > fixedChildren {
                nb.reverseChildrenSuffix(of: &param, from: fixedChildren)
            }
            nb.setChild(of: &spec, at: paramIndex, to: param)
        }
        return spec
    }

    mutating func demangleFuncSpecParam(_ kind: SwiftSymbol.Kind) -> B.Node? {
        var param = nb.make(kind: kind)
        switch nextChar() {
        case 0x6E: return param // 'n'
        case 0x63: // 'c'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.closureProp))
            return param
        case 0x43: // 'C'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.closurePropPreviousArg))
            let prevArgIdx = demangleNatural()
            if prevArgIdx < 0 { return nil }
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamPayload, index: UInt64(prevArgIdx)))
            return param
        case 0x70: // 'p'
            return demangleConstantProp(&param)
        case 0x65: return funcSpecParamFlags(&param, base: FuncSpecParamKind.existentialToGeneric, allowExtra: true) // 'e'
        case 0x64: return funcSpecParamFlags(&param, base: FuncSpecParamKind.dead, allowExtra: true, includeFirstGuaranteed: true) // 'd'
        case 0x67: // 'g'
            var value = FuncSpecParamKind.ownedToGuaranteed
            if nextIf(0x58) { value |= FuncSpecParamKind.sroa } // 'X'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: value))
            return param
        case 0x6F: // 'o'
            var value = FuncSpecParamKind.guaranteedToOwned
            if nextIf(0x58) { value |= FuncSpecParamKind.sroa } // 'X'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: value))
            return param
        case 0x78: // 'x'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.sroa))
            return param
        case 0x69: // 'i'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.boxToValue))
            return param
        case 0x73: // 's'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.boxToStack))
            return param
        case 0x72: // 'r'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.inOutToOut))
            return param
        default: return nil
        }
    }

    private mutating func funcSpecParamFlags(_ param: inout B.Node, base: UInt64, allowExtra _: Bool, includeFirstGuaranteed: Bool = false) -> B.Node {
        var value = base
        if includeFirstGuaranteed, nextIf(0x47) { value |= FuncSpecParamKind.ownedToGuaranteed } // 'G'
        else if base == FuncSpecParamKind.existentialToGeneric {
            if nextIf(0x44) { value |= FuncSpecParamKind.dead } // 'D'
            if nextIf(0x47) { value |= FuncSpecParamKind.ownedToGuaranteed } // 'G'
            if nextIf(0x4F) { value |= FuncSpecParamKind.guaranteedToOwned } // 'O'
            if nextIf(0x58) { value |= FuncSpecParamKind.sroa } // 'X'
            nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: value))
            return param
        }
        if base == FuncSpecParamKind.dead {
            if nextIf(0x4F) { value |= FuncSpecParamKind.guaranteedToOwned } // 'O'
            if nextIf(0x58) { value |= FuncSpecParamKind.sroa } // 'X'
        }
        nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: value))
        return param
    }

    private mutating func demangleConstantProp(_ param: inout B.Node) -> B.Node? {
        while true {
            switch nextChar() {
            case 0x53: // 'S'
                nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.constantPropStruct))
            case 0x66: // 'f'
                nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.constantPropFunction))
            case 0x67: // 'g'
                nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.constantPropGlobal))
            case 0x69: // 'i'
                if !addFuncSpecParamNumber(&param, kind: FuncSpecParamKind.constantPropInteger) { return nil }
            case 0x64: // 'd'
                if !addFuncSpecParamNumber(&param, kind: FuncSpecParamKind.constantPropFloat) { return nil }
            case 0x73: // 's'
                let encoding: String
                switch nextChar() {
                case 0x62: encoding = "u8" // 'b'
                case 0x77: encoding = "u16" // 'w'
                case 0x63: encoding = "objc" // 'c'
                default: return nil
                }
                nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.constantPropString))
                nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamPayload, name: encoding))
            case 0x6B: // 'k'
                nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: FuncSpecParamKind.constantPropKeyPath))
            default:
                pushBack()
                return param
            }
        }
    }

    private mutating func addFuncSpecParamNumber(_ param: inout B.Node, kind: UInt64) -> Bool {
        nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamKind, index: kind))
        var str: [UInt8] = []
        while ManglingChars.isDigit(peekChar()) {
            str.append(nextChar())
        }
        if str.isEmpty { return false }
        nb.appendChild(to: &param, nb.make(kind: .FunctionSignatureSpecializationParamPayload, name: String(decoding: str, as: UTF8.self)))
        return true
    }

    mutating func demangleSpecAttributes(_ specKind: SwiftSymbol.Kind) -> B.Node? {
        let isSerialized = nextIf(0x71) // 'q'
        let asyncRemoved = nextIf(0x61) // 'a'
        let representationChanged = nextIf(0x72) // 'r'
        let passID = Int(nextChar()) - 0x30
        if passID < 0 || passID >= maxSpecializationPass { return nil }
        var specNode = nb.make(kind: specKind)
        if isSerialized { nb.appendChild(to: &specNode, nb.make(kind: .IsSerialized)) }
        if asyncRemoved { nb.appendChild(to: &specNode, nb.make(kind: .AsyncRemoved)) }
        if representationChanged { nb.appendChild(to: &specNode, nb.make(kind: .RepresentationChanged)) }
        nb.appendChild(to: &specNode, nb.make(kind: .SpecializationPassID, index: UInt64(passID)))
        return specNode
    }

    // MARK: Witnesses

    mutating func demangleWitness() -> B.Node? {
        let c = nextChar()
        switch c {
        case 0x43: return createWithChild(.EnumCase, popNode(DemanglerPredicates.isEntity)) // 'C'
        case 0x56: return createWithChild(.ValueWitnessTable, popNode(.`Type`)) // 'V'
        case 0x76: // 'v'
            let directness: UInt64
            switch nextChar() {
            case 0x64: directness = 0 // 'd' Direct
            case 0x69: directness = 1 // 'i' Indirect
            default: return nil
            }
            return createWithChildren(.FieldOffset, nb.make(kind: .Directness, index: directness),
                                      popNode(DemanglerPredicates.isEntity))
        case 0x53: return createWithChild(.ProtocolSelfConformanceWitnessTable, popProtocol()) // 'S'
        case 0x50: return createWithChild(.ProtocolWitnessTable, popProtocolConformance()) // 'P'
        case 0x70: return createWithChild(.ProtocolWitnessTablePattern, popProtocolConformance()) // 'p'
        case 0x47: return createWithChild(.GenericProtocolWitnessTable, popProtocolConformance()) // 'G'
        case 0x49: return createWithChild(.GenericProtocolWitnessTableInstantiationFunction, popProtocolConformance()) // 'I'
        case 0x72: return createWithChild(.ResilientProtocolWitnessTable, popProtocolConformance()) // 'r'
        case 0x6C: // 'l'
            let conf = popProtocolConformance()
            let type = popNode(.`Type`)
            return createWithChildren(.LazyProtocolWitnessTableAccessor, type, conf)
        case 0x4C: // 'L'
            let conf = popProtocolConformance()
            let type = popNode(.`Type`)
            return createWithChildren(.LazyProtocolWitnessTableCacheVariable, type, conf)
        case 0x61: return createWithChild(.ProtocolWitnessTableAccessor, popProtocolConformance()) // 'a'
        case 0x74: // 't'
            let name = popNode(DemanglerPredicates.isDeclName)
            let conf = popProtocolConformance()
            return createWithChildren(.AssociatedTypeMetadataAccessor, conf, name)
        case 0x54: // 'T'
            let protoTy = popNode(.`Type`)
            let conformingType = popAssocTypePath()
            let conf = popProtocolConformance()
            return createWithChildren(.AssociatedTypeWitnessTableAccessor, conf, conformingType, protoTy)
        case 0x62: // 'b'
            let protoTy = popNode(.`Type`)
            let conf = popProtocolConformance()
            return createWithChildren(.BaseWitnessTableAccessor, conf, protoTy)
        case 0x4F: return demangleOutlinedNoValueWitness() // 'O'
        case 0x5A, 0x7A: return demangleGlobalVariableOnce(c) // 'Z','z'
        case 0x4A: return demangleDifferentiabilityWitness() // 'J'
        default: return nil
        }
    }

    private mutating func demangleOutlinedNoValueWitness() -> B.Node? {
        let kind: SwiftSymbol.Kind
        switch nextChar() {
        case 0x42: kind = .OutlinedInitializeWithTakeNoValueWitness // 'B'
        case 0x43: kind = .OutlinedInitializeWithCopyNoValueWitness // 'C'
        case 0x44: kind = .OutlinedAssignWithTakeNoValueWitness // 'D'
        case 0x46: kind = .OutlinedAssignWithCopyNoValueWitness // 'F'
        case 0x48: kind = .OutlinedDestroyNoValueWitness // 'H'
        case 0x79: kind = .OutlinedCopy // 'y'
        case 0x65: kind = .OutlinedConsume // 'e'
        case 0x72: kind = .OutlinedRetain // 'r'
        case 0x73: kind = .OutlinedRelease // 's'
        case 0x62: kind = .OutlinedInitializeWithTake // 'b'
        case 0x63: kind = .OutlinedInitializeWithCopy // 'c'
        case 0x64: kind = .OutlinedAssignWithTake // 'd'
        case 0x66: kind = .OutlinedAssignWithCopy // 'f'
        case 0x68: kind = .OutlinedDestroy // 'h'
        case 0x67: kind = .OutlinedEnumGetTag // 'g'
        case 0x69: // 'i'
            let enumCaseIdx = demangleIndexAsNode()
            if let sig = popNode(.DependentGenericSignature) {
                return createWithChildren(.OutlinedEnumTagStore, popNode(.`Type`), sig, enumCaseIdx)
            }
            return createWithChildren(.OutlinedEnumTagStore, popNode(.`Type`), enumCaseIdx)
        case 0x6A: // 'j'
            let enumCaseIdx = demangleIndexAsNode()
            if let sig = popNode(.DependentGenericSignature) {
                return createWithChildren(.OutlinedEnumProjectDataForLoad, popNode(.`Type`), sig, enumCaseIdx)
            }
            return createWithChildren(.OutlinedEnumProjectDataForLoad, popNode(.`Type`), enumCaseIdx)
        default: return nil
        }
        if let sig = popNode(.DependentGenericSignature) {
            return createWithChildren(kind, popNode(.`Type`), sig)
        }
        return createWithChild(kind, popNode(.`Type`))
    }

    private mutating func demangleGlobalVariableOnce(_ c: UInt8) -> B.Node? {
        var declList = nb.make(kind: .GlobalVariableOnceDeclList)
        var vars: [B.Node] = []
        while popNode(.FirstElementMarker) != nil {
            guard let identifier = popNode(DemanglerPredicates.isDeclName) else { return nil }
            vars.append(identifier)
        }
        for v in vars.reversed() {
            nb.appendChild(to: &declList, v)
        }
        guard let context = popContext() else { return nil }
        let kind: SwiftSymbol.Kind = c == 0x5A ? .GlobalVariableOnceFunction : .GlobalVariableOnceToken
        return nb.make(kind: kind, children: [context, declList])
    }
}
