// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Re-mangling for the long-tail node kinds — SIL impl-function types, autodiff
// thunks, key-path thunks, attached-macro expansions, dependent protocol
// conformances, SIL box types, and the outlined value-witness family. Ported
// from the matching `mangleXXX` methods of `lib/Demangling/Remangler.cpp`.

extension Remangler {
    // MARK: Impl-function types

    func mangleImplFunctionType(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        var pseudoGeneric = ""
        var genSig: SwiftSymbol?
        var patternSubs: SwiftSymbol?
        var invocationSubs: SwiftSymbol?
        for child in node.children {
            switch child.kind {
            case .ImplParameter, .ImplResult, .ImplYield, .ImplErrorResult:
                guard child.children.count >= 2, let last = child.children.last,
                      mangle(last, depth: d) else { return false }
            case .DependentPseudogenericSignature:
                pseudoGeneric = "P"; genSig = child
            case .DependentGenericSignature:
                genSig = child
            case .ImplPatternSubstitutions: patternSubs = child
            case .ImplInvocationSubstitutions: invocationSubs = child
            default: break
            }
        }
        if let genSig { guard mangle(genSig, depth: d) else { return false } }
        if let invocationSubs {
            emit("y")
            guard mangleChildNodes(invocationSubs.children[0], depth: d) else { return false }
            if invocationSubs.children.count >= 2 {
                guard mangle(invocationSubs.children[1], depth: d) else { return false }
            }
        }
        if let patternSubs {
            guard mangle(patternSubs.children[0], depth: d) else { return false }
            emit("y")
            guard mangleChildNodes(patternSubs.children[1], depth: d) else { return false }
            if patternSubs.children.count >= 3 {
                let retro = patternSubs.children[2]
                if retro.kind == .TypeList {
                    guard mangleChildNodes(retro, depth: d) else { return false }
                } else {
                    guard mangle(retro, depth: d) else { return false }
                }
            }
        }
        emit("I")
        if patternSubs != nil { emit("s") }
        if invocationSubs != nil { emit("I") }
        emitDynamic(pseudoGeneric)
        for child in node.children {
            switch child.kind {
            case .ImplDifferentiabilityKind: emit(UInt8(child.index ?? 0))
            case .ImplEscaping: emit("e")
            case .ImplErasedIsolation: emit("A")
            case .ImplNonisolatedNonsendingIsolation: emit("N")
            case .ImplSendingResult: emit("T")
            case .ImplConvention:
                guard let ch = implCalleeConvention(child.text) else { return false }
                emitDynamic(ch)
            case .ImplFunctionConvention:
                guard mangleImplFunctionConvention(child, depth: d) else { return false }
            case .ImplCoroutineKind:
                guard let ch = implCoroutineKind(child.text) else { return false }
                emitDynamic(ch)
            case .ImplFunctionAttribute:
                guard let ch = implFunctionAttribute(child.text) else { return false }
                emitDynamic(ch)
            case .ImplYield:
                emit("Y"); guard mangleImplParameter(child, depth: d) else { return false }
            case .ImplParameter:
                guard mangleImplParameter(child, depth: d) else { return false }
            case .ImplErrorResult:
                emit("z"); guard mangleImplResult(child, depth: d) else { return false }
            case .ImplResult:
                guard mangleImplResult(child, depth: d) else { return false }
            default: break
            }
        }
        emit("_")
        return true
    }

    private func mangleImplParameter(_ child: SwiftSymbol, depth _: Int) -> Bool {
        guard let convText = child.firstChild?.text, let ch = implParamConvention(convText) else { return false }
        emitDynamic(ch)
        guard child.children.count >= 1 else { return true }
        for i in 1 ..< max(1, child.children.count - 1) {
            let g = child.children[i]
            switch g.kind {
            case .ImplParameterResultDifferentiability:
                guard mangleImplParameterResultDifferentiability(g) else { return false }
            case .ImplParameterSending:
                guard implParamText(g, "sending", "T") else { return false }
            case .ImplParameterIsolated:
                guard implParamText(g, "isolated", "I") else { return false }
            case .ImplParameterImplicitLeading:
                guard implParamText(g, "sil_implicit_leading_param", "L") else { return false }
            default: return false
            }
        }
        return true
    }

    private func mangleImplResult(_ child: SwiftSymbol, depth _: Int) -> Bool {
        guard let convText = child.firstChild?.text, let ch = implResultConvention(convText) else { return false }
        emitDynamic(ch)
        if child.children.count == 3 {
            guard mangleImplParameterResultDifferentiability(child.children[1]) else { return false }
        } else if child.children.count == 4 {
            guard mangleImplParameterResultDifferentiability(child.children[1]),
                  implParamText(child.children[2], "sending", "T") else { return false }
        }
        return true
    }

    func mangleImplFunctionConvention(_ node: SwiftSymbol, depth _: Int) -> Bool {
        let text = node.firstChild?.text ?? ""
        guard let attr = implFunctionConventionName(text) else { return false }
        if attr == "B" || attr == "C", node.children.count > 1, node.children[1].kind == .ClangType {
            emit("z"); emitDynamic(attr); return mangleClangType(node.children[1])
        }
        emitDynamic(attr); return true
    }

    func mangleImplParameterResultDifferentiability(_ node: SwiftSymbol) -> Bool {
        let text = node.text ?? ""
        if text.isEmpty { return true }
        guard text == "@noDerivative" else { return false }
        emit("w"); return true
    }

    private func implParamText(_ node: SwiftSymbol, _ expected: String, _ ch: String) -> Bool {
        guard node.text == expected else { return false }
        emitDynamic(ch); return true
    }

    private func implCalleeConvention(_ text: String?) -> String? {
        switch text {
        case "@callee_unowned": "y"
        case "@callee_guaranteed": "g"
        case "@callee_owned": "x"
        case "@convention(thin)": "t"
        default: nil
        }
    }

    private func implParamConvention(_ text: String) -> String? {
        switch text {
        case "@in": "i"; case "@inout": "l"; case "@inout_aliasable": "b"
        case "@in_guaranteed": "n"; case "@in_cxx": "X"; case "@in_constant": "c"
        case "@owned": "x"; case "@guaranteed": "g"; case "@deallocating": "e"
        case "@unowned": "y"; case "@pack_guaranteed": "p"; case "@pack_owned": "v"
        case "@pack_inout": "m"; default: nil
        }
    }

    private func implResultConvention(_ text: String) -> String? {
        switch text {
        case "@out": "r"; case "@owned": "o"; case "@unowned": "d"
        case "@unowned_inner_pointer": "u"; case "@autoreleased": "a"; case "@pack_out": "k"
        case "@guaranteed_address": "l"; case "@guaranteed": "g"; case "@inout": "m"; default: nil
        }
    }

    private func implCoroutineKind(_ text: String?) -> String? {
        switch text {
        case "yield_once": "A"; case "yield_once_2": "I"; case "yield_many": "G"; default: nil
        }
    }

    private func implFunctionAttribute(_ text: String?) -> String? {
        switch text { case "@Sendable": "h"; case "@async": "H"; default: nil }
    }

    private func implFunctionConventionName(_ text: String) -> String? {
        switch text {
        case "block": "B"; case "c": "C"; case "method": "M"
        case "objc_method": "O"; case "closure": "K"; case "witness_method": "W"; default: nil
        }
    }

    // MARK: Autodiff thunks

    func mangleAutoDiffFunctionOrSimpleThunk(_ node: SwiftSymbol, _ op: String, depth: Int) -> Bool {
        let d = depth + 1
        var idx = 0
        while idx < node.children.count, node.children[idx].kind != .AutoDiffFunctionKind {
            guard mangle(node.children[idx], depth: d) else { return false }
            idx += 1
        }
        emitDynamic(op)
        guard idx + 2 < node.children.count else { return false }
        guard mangle(node.children[idx], depth: d) else { return false } // kind
        guard mangle(node.children[idx + 1], depth: d) else { return false } // param indices
        emit("p")
        guard mangle(node.children[idx + 2], depth: d) else { return false } // result indices
        emit("r")
        return true
    }

    func mangleAutoDiffSubsetParametersThunk(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        var idx = 0
        while idx < node.children.count, node.children[idx].kind != .AutoDiffFunctionKind {
            guard mangle(node.children[idx], depth: d) else { return false }
            idx += 1
        }
        emit("TJS")
        guard idx + 3 < node.children.count else { return false }
        guard mangle(node.children[idx], depth: d) else { return false }
        guard mangle(node.children[idx + 1], depth: d) else { return false }
        emit("p")
        guard mangle(node.children[idx + 2], depth: d) else { return false }
        emit("r")
        guard mangle(node.children[idx + 3], depth: d) else { return false }
        emit("P")
        return true
    }

    func mangleAutoDiffSelfReorderingReabstractionThunk(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        var idx = 0
        guard node.children.count >= 3 else { return false }
        guard mangle(node.children[idx], depth: d) else { return false }; idx += 1 // from
        guard mangle(node.children[idx], depth: d) else { return false }; idx += 1 // to
        if node.children[idx].kind == .DependentGenericSignature {
            guard mangleDependentGenericSignature(node.children[idx], depth: d) else { return false }; idx += 1
        }
        emit("TJO")
        guard idx < node.children.count else { return false }
        return mangle(node.children[idx], depth: d) // kind
    }

    func mangleDifferentiabilityWitness(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        var idx = 0
        while idx < node.children.count, node.children[idx].kind != .Index {
            guard mangle(node.children[idx], depth: d) else { return false }
            idx += 1
        }
        if node.children.last?.kind == .DependentGenericSignature, let last = node.children.last {
            guard mangle(last, depth: d) else { return false }
        }
        guard idx + 2 < node.children.count else { return false }
        emit("WJ"); emit(UInt8(node.children[idx].index ?? 0)); idx += 1
        guard mangle(node.children[idx], depth: d) else { return false }; emit("p"); idx += 1
        guard mangle(node.children[idx], depth: d) else { return false }; emit("r")
        return true
    }

    // MARK: Key-path thunk helpers

    func mangleKeyPathThunkHelper(_ node: SwiftSymbol, _ op: String, depth: Int) -> Bool {
        let d = depth + 1
        for child in node.children where child.kind != .IsSerialized {
            guard mangle(child, depth: d) else { return false }
        }
        emitDynamic(op)
        for child in node.children where child.kind == .IsSerialized {
            guard mangle(child, depth: d) else { return false }
        }
        return true
    }

    // MARK: Attached / freestanding macro expansions

    func mangleAttachedMacro(_ node: SwiftSymbol, _ char: String, depth: Int) -> Bool {
        let d = depth + 1
        var idx = 0
        while idx + 1 < node.children.count {
            guard mangleChildNode(node, idx, depth: d) else { return false }
            idx += 1
        }
        emit("fM"); emitDynamic(char)
        return mangleChildNode(node, idx, depth: d)
    }

    func mangleFreestandingMacroExpansion(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard mangleChildNode(node, 0, depth: d) else { return false }
        if node.children.count > 3 { guard mangle(node.children[3], depth: d) else { return false } }
        guard mangleChildNode(node, 1, depth: d) else { return false }
        emit("fMf")
        return mangleChildNode(node, 2, depth: d)
    }

    func mangleMacroExpansionUniqueName(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard mangleChildNode(node, 0, depth: d) else { return false }
        if node.children.count > 3 { guard mangle(node.children[3], depth: d) else { return false } }
        guard mangleChildNode(node, 1, depth: d) else { return false }
        emit("fMu")
        return mangleChildNode(node, 2, depth: d)
    }

    func mangleMacroExpansionLoc(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 4 else { return false }
        guard mangleChildNode(node, 0, depth: d), mangleChildNode(node, 1, depth: d) else { return false }
        emit("fMX")
        mangleIndex(node.children[2].index ?? 0)
        mangleIndex(node.children[3].index ?? 0)
        return true
    }

    // MARK: ObjC async completion handler impls

    func mangleObjCAsyncCompletionHandlerImpl(_ node: SwiftSymbol, _ op: String, depth: Int) -> Bool {
        let d = depth + 1
        guard mangleChildNode(node, 0, depth: d), mangleChildNode(node, 1, depth: d) else { return false }
        if node.children.count == 4 { guard mangleChildNode(node, 3, depth: d) else { return false } }
        emitDynamic(op)
        return mangleChildNode(node, 2, depth: d)
    }

    // MARK: Dependent protocol conformances

    func mangleDependentProtocolConformanceRoot(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 3, mangle(node.children[0], depth: d),
              manglePureProtocol(node.children[1], depth: d) else { return false }
        emit("HD")
        return mangleDependentConformanceIndex(node.children[2])
    }

    func mangleDependentProtocolConformanceInherited(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 3, mangleAnyProtocolConformance(node.children[0], depth: d),
              manglePureProtocol(node.children[1], depth: d) else { return false }
        emit("HI")
        return mangleDependentConformanceIndex(node.children[2])
    }

    func mangleDependentProtocolConformanceAssociated(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 3, mangleAnyProtocolConformance(node.children[0], depth: d),
              mangleDependentAssociatedConformance(node.children[1], depth: d) else { return false }
        emit("HA")
        return mangleDependentConformanceIndex(node.children[2])
    }

    func mangleDependentProtocolConformanceOpaque(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 2, mangleAnyProtocolConformance(node.children[0], depth: d),
              mangle(node.children[1], depth: d) else { return false }
        emit("HO")
        return true
    }

    func mangleDependentAssociatedConformance(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 2, mangle(node.children[0], depth: d) else { return false }
        return manglePureProtocol(node.children[1], depth: d)
    }

    /// The `DEPENDENT-CONFORMANCE-INDEX` encoding: `UnknownIndex` → 1, an
    /// `Index` → its value + 2 (apple/swift's `mangleDependentConformanceIndex`).
    func mangleDependentConformanceIndex(_ node: SwiftSymbol) -> Bool {
        if node.kind == .UnknownIndex { mangleIndex(1); return true }
        guard node.kind == .Index, let idx = node.index else { return false }
        mangleIndex(idx + 2)
        return true
    }

    func manglePackProtocolConformance(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard let first = node.firstChild, mangleAnyProtocolConformanceList(first, depth: depth + 1) else { return false }
        emit("HX")
        return true
    }

    func mangleAssociatedConformanceDescriptor(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 3, mangle(node.children[0], depth: d), mangle(node.children[1], depth: d),
              manglePureProtocol(node.children[2], depth: d) else { return false }
        emit("Tn"); return true
    }

    func mangleDefaultAssociatedConformanceAccessor(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 3, mangle(node.children[0], depth: d), mangle(node.children[1], depth: d),
              manglePureProtocol(node.children[2], depth: d) else { return false }
        emit("TN"); return true
    }

    func mangleBaseConformanceDescriptor(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 2, mangle(node.children[0], depth: d),
              manglePureProtocol(node.children[1], depth: d) else { return false }
        emit("Tb"); return true
    }

    // MARK: SIL box types

    func mangleSILBoxTypeWithLayout(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard let layout = node.firstChild, layout.kind == .SILBoxLayout else { return false }
        var layoutTypeList = SwiftSymbol(kind: .TypeList)
        for field in layout.children {
            guard field.children.count == 1, var fieldType = field.firstChild, fieldType.kind == .`Type` else { return false }
            if field.kind == .SILBoxMutableField {
                guard let inner = fieldType.firstChild else { return false }
                let inout0 = SwiftSymbol(kind: .InOut, child: inner)
                fieldType = SwiftSymbol(kind: .`Type`, child: inout0)
            }
            layoutTypeList.addChild(fieldType)
        }
        guard mangleTypeListNode(layoutTypeList, depth: d) else { return false }
        if node.children.count == 3 {
            let signature = node.children[1]
            let genericArgs = node.children[2]
            guard signature.kind == .DependentGenericSignature, genericArgs.kind == .TypeList else { return false }
            guard mangleTypeListNode(genericArgs, depth: d), mangleDependentGenericSignature(signature, depth: d) else { return false }
            emit("XX")
        } else {
            emit("Xx")
        }
        return true
    }

    private func mangleTypeListNode(_ node: SwiftSymbol, depth: Int) -> Bool {
        var first = true
        for child in node.children {
            guard mangle(child, depth: depth) else { return false }
            mangleListSeparator(&first)
        }
        mangleEndOfList(first)
        return true
    }

    // MARK: Extended-existential shapes

    func mangleExtendedExistentialTypeShape(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        let genSig: SwiftSymbol?
        let type: SwiftSymbol
        if node.children.count == 1 {
            genSig = nil; type = node.children[0]
        } else {
            guard node.children.count >= 2 else { return false }
            genSig = node.children[0]; type = node.children[1]
        }
        if let genSig { guard mangle(genSig, depth: d) else { return false } }
        guard mangle(type, depth: d) else { return false }
        emit(genSig != nil ? "XG" : "Xg")
        return true
    }

    func mangleSymbolicExtendedExistentialType(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        guard node.children.count >= 2, mangle(node.children[0], depth: d) else { return false }
        for arg in node.children[1].children where !mangle(arg, depth: d) {
            return false
        }
        if node.children.count > 2 {
            for conf in node.children[2].children where !mangle(conf, depth: d) {
                return false
            }
        }
        return true
    }

    // MARK: Generic partial specialization

    func mangleGenericPartialSpecialization(_ node: SwiftSymbol, _ op: String, depth: Int) -> Bool {
        let d = depth + 1
        for child in node.children where child.kind == .GenericSpecializationParam {
            guard mangleChildNode(child, 0, depth: d) else { return false }
            break
        }
        emitDynamic(op)
        for child in node.children where child.kind != .GenericSpecializationParam {
            guard mangle(child, depth: d) else { return false }
        }
        return true
    }

    // MARK: Outlined enum tag store / project

    func mangleOutlinedEnum(_ node: SwiftSymbol, _ op: String, depth: Int) -> Bool {
        let d = depth + 1
        guard !node.children.isEmpty, mangle(node.children[0], depth: d) else { return false }
        if node.children.count == 2 {
            emitDynamic(op); mangleIndex(node.children[1].index ?? 0)
        } else {
            guard node.children.count >= 3, mangle(node.children[1], depth: d) else { return false }
            emitDynamic(op); mangleIndex(node.children[2].index ?? 0)
        }
        return true
    }
}
