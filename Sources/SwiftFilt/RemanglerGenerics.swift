// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The structurally non-trivial `Remangler` methods (Global ordering, function
// signatures, generic signatures / requirements, dependent types, function /
// generic specializations, builtins, conformances) — ported from
// `lib/Demangling/Remangler.cpp`.

extension Remangler {
    /// The node kinds `mangleGlobal` emits *after* the entity they precede
    /// (the explicit list from the reference — note it excludes the
    /// partial-apply forwarders, which mangle in place).
    private func isGlobalReverseOrderAttr(_ kind: SwiftSymbol.Kind) -> Bool {
        switch kind {
        case .FunctionSignatureSpecialization, .GenericSpecialization,
             .GenericSpecializationPrespecialized, .GenericSpecializationNotReAbstracted,
             .GenericSpecializationInResilienceDomain, .InlinedGenericFunction,
             .GenericPartialSpecialization, .GenericPartialSpecializationNotReAbstracted,
             .OutlinedBridgedMethod, .OutlinedVariable, .OutlinedReadOnlyObject,
             .ObjCAttribute, .NonObjCAttribute, .DynamicAttribute, .VTableAttribute,
             .DirectMethodReferenceAttribute, .MergedFunction, .DistributedThunk,
             .DistributedAccessor, .DynamicallyReplaceableFunctionKey,
             .DynamicallyReplaceableFunctionImpl, .DynamicallyReplaceableFunctionVar,
             .AsyncFunctionPointer, .AsyncAwaitResumePartialFunction,
             .AsyncSuspendResumePartialFunction, .AccessibleFunctionRecord,
             .BackDeploymentThunk, .BackDeploymentFallback, .HasSymbolQuery,
             .CoroFunctionPointer, .DefaultOverride:
            true
        default:
            false
        }
    }

    func mangleGlobal(_ node: SwiftSymbol, depth: Int) -> Bool {
        emitDynamic(flavor == .embedded ? SwiftManglingConstants.embeddedManglingPrefix : SwiftManglingConstants.manglingPrefix)
        var mangleInReverseOrder = false
        for (idx, child) in node.children.enumerated() {
            if isGlobalReverseOrderAttr(child.kind) {
                mangleInReverseOrder = true
                continue
            }
            guard mangle(child, depth: depth + 1) else { return false }
            if mangleInReverseOrder {
                var reverseIdx = idx
                while reverseIdx > 0 {
                    reverseIdx -= 1
                    let prev = node.children[reverseIdx]
                    guard isGlobalReverseOrderAttr(prev.kind) else { break }
                    guard mangle(prev, depth: depth + 1) else { return false }
                }
                mangleInReverseOrder = false
            }
        }
        return true
    }

    func mangleFunction(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard mangleChildNode(node, 0, depth: depth), mangleChildNode(node, 1, depth: depth) else { return false }
        let hasLabels = node.children.count > 2 && node.children[2].kind == .LabelList
        let typeChildIdx = hasLabels ? 3 : 2
        guard typeChildIdx < node.children.count, let funcType = node.children[typeChildIdx].firstChild else { return false }
        if hasLabels { guard mangleChildNode(node, 2, depth: depth) else { return false } }
        if funcType.kind == .DependentGenericType {
            guard funcType.children.count > 1, let inner = funcType.children[1].firstChild,
                  mangleFunctionSignature(inner, depth: depth), mangleChildNode(funcType, 0, depth: depth)
            else { return false }
        } else {
            guard mangleFunctionSignature(funcType, depth: depth) else { return false }
        }
        emit("F")
        return true
    }

    // MARK: Generic signatures / requirements

    func mangleDependentGenericSignature(_ node: SwiftSymbol, depth: Int) -> Bool {
        var paramCountEnd = 0
        for (idx, child) in node.children.enumerated() {
            if child.kind == .DependentGenericParamCount {
                paramCountEnd = idx + 1
            } else {
                guard mangle(child, depth: depth + 1) else { return false }
            }
        }
        if paramCountEnd == 1, node.children[0].index == 1 {
            emit("l"); return true
        }
        emit("r")
        for idx in 0 ..< paramCountEnd {
            let count = node.children[idx].index ?? 0
            if count > 0 { mangleIndex(count - 1) } else { emit("z") }
        }
        emit("l")
        return true
    }

    func mangleDependentGenericParamType(_ node: SwiftSymbol) -> Bool {
        guard node.children.count >= 2 else { return false }
        if node.children[0].index == 0, node.children[1].index == 0 { emit("x"); return true }
        emit("q"); mangleDependentGenericParamIndex(node); return true
    }

    func mangleDependentMemberType(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard let (numMembers, dependentBase) = mangleConstrainedType(node, depth: depth) else { return false }
        switch numMembers {
        case -1: break // substitution
        case 0: return false
        case 1:
            emit("Q")
            if let dependentBase { mangleDependentGenericParamIndex(dependentBase, nonZeroPrefix: "y", zeroOp: 0x7A) } else { emit("x") }
        default:
            emit("Q")
            if let dependentBase { mangleDependentGenericParamIndex(dependentBase, nonZeroPrefix: "Y", zeroOp: 0x5A) } else { emit("X") }
        }
        return true
    }

    func mangleDependentAssociatedTypeRef(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard let first = node.firstChild else { return false }
        mangleIdentifierImpl(first, isOperator: false)
        if node.children.count > 1 { return mangleChildNode(node, 1, depth: depth) }
        return true
    }

    func mangleConformanceRequirement(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard node.children.count == 2 else { return false }
        let protoOrClass = node.children[1]
        guard let first = protoOrClass.firstChild else { return false }
        if first.kind == .protocolNode {
            guard manglePureProtocol(protoOrClass, depth: depth),
                  let (numMembers, paramIdx) = mangleConstrainedType(node.children[0], depth: depth) else { return false }
            switch numMembers {
            case -1: emit("RQ"); return true
            case 0: emit("R")
            case 1: emit("Rp")
            default: emit("RP")
            }
            if let paramIdx { mangleDependentGenericParamIndex(paramIdx) }
            return true
        }
        guard mangle(protoOrClass, depth: depth + 1),
              let (numMembers, paramIdx) = mangleConstrainedType(node.children[0], depth: depth) else { return false }
        switch numMembers {
        case -1: emit("RB"); return true
        case 0: emit("Rb")
        case 1: emit("Rc")
        default: emit("RC")
        }
        if let paramIdx { mangleDependentGenericParamIndex(paramIdx) }
        return true
    }

    func mangleSameTypeRequirement(_ node: SwiftSymbol, _ subOp: String, _ zeroOp: String, _ oneOp: String, _ manyOp: String, depth: Int) -> Bool {
        guard mangleChildNode(node, 1, depth: depth),
              let (numMembers, paramIdx) = mangleConstrainedType(node.children[0], depth: depth) else { return false }
        switch numMembers {
        case -1: emitDynamic(subOp); return true
        case 0: emitDynamic(zeroOp)
        case 1: emitDynamic(oneOp)
        default: emitDynamic(manyOp)
        }
        if let paramIdx { mangleDependentGenericParamIndex(paramIdx) }
        return true
    }

    func mangleInverseRequirement(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard node.children.count == 2 else { return false }
        guard let (numMembers, paramIdx) = mangleConstrainedType(node.children[0], depth: depth) else { return false }
        let bitIndex = node.children[1].index ?? 0
        switch numMembers {
        case -1: emit("RI"); mangleIndex(bitIndex); return true
        case 0: emit("Ri")
        case 1: emit("Rj")
        default: emit("RJ")
        }
        mangleIndex(bitIndex)
        if let paramIdx { mangleDependentGenericParamIndex(paramIdx) }
        return true
    }

    func mangleSameShapeRequirement(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard mangleChildNode(node, 1, depth: depth),
              let (numMembers, paramIdx) = mangleConstrainedType(node.children[0], depth: depth), numMembers == 0 else { return false }
        emit("Rh")
        if let paramIdx { mangleDependentGenericParamIndex(paramIdx) }
        return true
    }

    func mangleLayoutRequirement(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard let (numMembers, paramIdx) = mangleConstrainedType(node.children[0], depth: depth) else { return false }
        switch numMembers {
        case -1: emit("RL")
        case 0: emit("Rl")
        case 1: emit("Rm")
        default: emit("RM")
        }
        if numMembers != -1, let paramIdx { mangleDependentGenericParamIndex(paramIdx) }
        guard node.children.count > 1, node.children[1].kind == .Identifier,
              let layoutName = node.children[1].text, layoutName.count == 1 else { return false }
        emitDynamic(layoutName)
        if node.children.count >= 3 { guard mangleChildNode(node, 2, depth: depth) else { return false } }
        if node.children.count >= 4 { guard mangleChildNode(node, 3, depth: depth) else { return false } }
        return true
    }

    // MARK: Specializations

    func mangleGenericSpecializationNode(_ node: SwiftSymbol, _ specKind: String, depth: Int) -> Bool {
        var firstParam = true
        for child in node.children where child.kind == .GenericSpecializationParam {
            guard mangleChildNode(child, 0, depth: depth) else { return false }
            mangleListSeparator(&firstParam)
        }
        if firstParam { return false }
        emit("T")
        for child in node.children where child.kind == .DroppedArgument {
            guard mangle(child, depth: depth + 1) else { return false }
        }
        emitDynamic(specKind)
        for child in node.children where child.kind != .GenericSpecializationParam && child.kind != .DroppedArgument {
            guard mangle(child, depth: depth + 1) else { return false }
        }
        return true
    }

    func mangleFunctionSignatureSpecialization(_ node: SwiftSymbol, depth: Int) -> Bool {
        // The constant-prop / closure-prop operands (the propagated name as a
        // word-substituted identifier, plus any closure capture types) are
        // emitted *before* `Tf`, keyed on each param's kind (Remangler.cpp).
        for param in node.children
            where param.kind == .FunctionSignatureSpecializationParam && !param.children.isEmpty
        {
            // A param may carry SEVERAL kinds (e.g. a composite
            // `[ConstantPropStruct][ConstantPropStruct][ConstantPropString]`),
            // each with its own pre-`Tf` operand. Walk every kind and pull its
            // operand from a cursor that skips the kind/payload nodes — peeking
            // only `children[0]` drops every operand after the first kind.
            var argIdx = 0
            func nextOperand() -> SwiftSymbol? {
                while argIdx < param.children.count {
                    let c = param.children[argIdx]; argIdx += 1
                    if c.kind == .FunctionSignatureSpecializationParamKind
                        || c.kind == .FunctionSignatureSpecializationParamPayload { continue }
                    return c
                }
                return nil
            }
            for kindNd in param.children where kindNd.kind == .FunctionSignatureSpecializationParamKind {
                guard let kind = kindNd.index else { continue }
                switch kind {
                case 0, 1, 4: // ConstantPropFunction, ConstantPropGlobal, ConstantPropString
                    // ConstantPropString's leading `_` escape is kept verbatim in
                    // the Identifier operand, so mangle it as-is.
                    guard let op = nextOperand() else { return false }
                    mangleIdentifierImpl(op, isOperator: false)
                case 5, 9: // ClosureProp, ConstantPropKeyPath — identifier + captures
                    guard let op = nextOperand() else { return false }
                    mangleIdentifierImpl(op, isOperator: false)
                    while let capture = nextOperand() {
                        guard mangle(capture, depth: depth + 1) else { return false }
                    }
                case 10: // ConstantPropStruct — the struct's `Type` is the pre-`Tf` payload
                    guard let op = nextOperand() else { return false }
                    guard mangle(op, depth: depth + 1) else { return false }
                default:
                    break
                }
            }
        }
        emit("Tf")
        var returnValMangled = false
        for child in node.children {
            if child.kind == .RepresentationChanged { returnValMangled = true }
            if child.kind == .FunctionSignatureSpecializationReturn { emit("_"); returnValMangled = true }
            guard mangleFuncSpecParamOrAttr(child, depth: depth + 1) else { return false }
        }
        if !returnValMangled { emit("_n") }
        return true
    }

    /// Mangle a child of a FunctionSignatureSpecialization: the param/return
    /// nodes encode their kind inline; other children dispatch normally.
    private func mangleFuncSpecParamOrAttr(_ node: SwiftSymbol, depth: Int) -> Bool {
        switch node.kind {
        case .FunctionSignatureSpecializationParam, .FunctionSignatureSpecializationReturn:
            mangleFuncSpecParam(node)
        default:
            mangle(node, depth: depth)
        }
    }

    private func mangleFuncSpecParam(_ node: SwiftSymbol) -> Bool {
        if node.children.isEmpty { emit("n"); return true }
        var constPropPrefix = "p"
        var idx = 0
        while idx < node.children.count {
            let kindNd = node.children[idx]; idx += 1
            guard kindNd.kind == .FunctionSignatureSpecializationParamKind, let kindValue = kindNd.index else { continue }
            switch kindValue {
            case 0: emitDynamic(constPropPrefix + "f"); constPropPrefix = "" // ConstantPropFunction
            case 1: emitDynamic(constPropPrefix + "g"); constPropPrefix = "" // ConstantPropGlobal
            case 2: // ConstantPropInteger
                emitDynamic(constPropPrefix + "i"); constPropPrefix = ""
                if idx < node.children.count { emitDynamic(node.children[idx].text ?? ""); idx += 1 }
            case 3: // ConstantPropFloat
                emitDynamic(constPropPrefix + "d"); constPropPrefix = ""
                if idx < node.children.count { emitDynamic(node.children[idx].text ?? ""); idx += 1 }
            case 4: // ConstantPropString
                emitDynamic(constPropPrefix + "s"); constPropPrefix = ""
                guard idx < node.children.count else { return false }
                switch node.children[idx].text {
                case "u8": emit("b")
                case "u16": emit("w")
                case "objc": emit("c")
                default: return false
                }
                idx += 1
            case 9: emitDynamic(constPropPrefix + "k"); constPropPrefix = "" // ConstantPropKeyPath
            case 10: emitDynamic(constPropPrefix + "S"); constPropPrefix = "" // ConstantPropStruct
            case 5: emit("c") // ClosureProp
            case 11: // ClosurePropPreviousArg
                emit("C")
                if idx < node.children.count { emitDynamic(String(node.children[idx].index ?? 0)); idx += 1 }
            case 6: emit("i") // BoxToValue
            case 7: emit("s") // BoxToStack
            case 8: emit("r") // InOutToOut
            case 1 << 8: emit("x") // SROA
            default:
                emitFuncSpecFlags(kindValue)
            }
        }
        return true
    }

    private func emitFuncSpecFlags(_ kindValue: UInt64) {
        let existentialToGeneric: UInt64 = 1 << 10, dead: UInt64 = 1 << 6
        let ownedToGuaranteed: UInt64 = 1 << 7, guaranteedToOwned: UInt64 = 1 << 9, sroa: UInt64 = 1 << 8
        if kindValue & existentialToGeneric != 0 {
            emit("e")
            if kindValue & dead != 0 { emit("D") }
            if kindValue & ownedToGuaranteed != 0 { emit("G") }
            if kindValue & guaranteedToOwned != 0 { emit("O") }
        } else if kindValue & dead != 0 {
            emit("d")
            if kindValue & ownedToGuaranteed != 0 { emit("G") }
            if kindValue & guaranteedToOwned != 0 { emit("O") }
        } else if kindValue & ownedToGuaranteed != 0 {
            emit("g")
        } else if kindValue & guaranteedToOwned != 0 {
            emit("o")
        }
        if kindValue & sroa != 0 { emit("X") }
    }

    // MARK: Conformances

    func mangleProtocolConformance(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard let typeChild = node.firstChild, var ty = typeChild.firstChild else { return false }
        var genSig: SwiftSymbol?
        if ty.kind == .DependentGenericType {
            genSig = ty.firstChild
            guard ty.children.count > 1 else { return false }
            ty = ty.children[1]
        }
        guard mangle(ty, depth: depth + 1) else { return false }
        if node.children.count == 4 { guard mangleChildNode(node, 3, depth: depth) else { return false } }
        guard node.children.count > 1, manglePureProtocol(node.children[1], depth: depth),
              mangleChildNode(node, 2, depth: depth) else { return false }
        if let genSig { return mangle(genSig, depth: depth + 1) }
        return true
    }

    func mangleConcreteProtocolConformance(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard mangleChildNode(node, 0, depth: depth), mangleChildNode(node, 1, depth: depth) else { return false }
        if node.children.count > 2 {
            guard mangleAnyProtocolConformanceList(node.children[2], depth: depth) else { return false }
        } else {
            emit("y")
        }
        emit("HC")
        return true
    }

    func mangleAnyProtocolConformance(_ node: SwiftSymbol, depth: Int) -> Bool {
        mangle(node, depth: depth)
    }

    // MARK: Builtin type names

    func mangleBuiltinTypeName(_ node: SwiftSymbol) -> Bool {
        emit("B")
        let text = node.text ?? ""
        let map: [String: String] = [
            "Builtin.ImplicitActor": "A", "Builtin.BridgeObject": "b",
            "Builtin.UnsafeValueBuffer": "B", "Builtin.UnknownObject": "O",
            "Builtin.NativeObject": "o", "Builtin.RawPointer": "p",
            "Builtin.RawUnsafeContinuation": "c", "Builtin.Job": "j",
            "Builtin.DefaultActorStorage": "D", "Builtin.NonDefaultDistributedActorStorage": "d",
            "Builtin.Executor": "e", "Builtin.SILToken": "t",
            "Builtin.IntLiteral": "I", "Builtin.Word": "w", "Builtin.PackIndex": "P",
        ]
        if let op = map[text] { emitDynamic(op); return true }
        if text.hasPrefix("Builtin.Int") { emit("i"); emitDynamic(String(text.dropFirst("Builtin.Int".count))); emit("_"); return true }
        if text.hasPrefix("Builtin.FPIEEE") { emit("f"); emitDynamic(String(text.dropFirst("Builtin.FPIEEE".count))); emit("_"); return true }
        if text.hasPrefix("Builtin.Vec") {
            let rest = String(text.dropFirst("Builtin.Vec".count))
            guard let xPos = rest.firstIndex(of: "x") else { return false }
            let count = String(rest[rest.startIndex ..< xPos])
            let element = String(rest[rest.index(after: xPos)...])
            if element == "RawPointer" { emit("p") }
            else if element.hasPrefix("FPIEEE") { emit("f"); emitDynamic(String(element.dropFirst("FPIEEE".count))); emit("_") }
            else if element.hasPrefix("Int") { emit("i"); emitDynamic(String(element.dropFirst("Int".count))); emit("_") }
            else { return false }
            emit("Bv"); emitDynamic(count); emit("_")
            return true
        }
        return false
    }
}
