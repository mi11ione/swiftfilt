// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Entity, function-type, generic-signature, and specialization rendering for
// `NodePrinter` — ported from the helper methods of
// `lib/Demangling/NodePrinter.cpp`, plus `classify` from `swift-demangle.cpp`.

/// `NodePrinter`'s methods are generic (over the node builder), and Swift forbids
/// a type nested inside a generic function; this impl-function-type walk state
/// lives at file scope instead (was a local `enum State` in `printImplFunctionType`).
private enum ImplFunctionTypePrintState: Int { case attrs, inputs, results }

extension NodePrinter {
    // MARK: Function types

    mutating func printFunctionType(labelList: B.Node?, _ node: B.Node, depth: Int) {
        let d = depth + 1
        if nb.childCount(of: node) < 2 { setInvalid(); return }

        func printConventionWithMangledCType(_ convention: String) {
            emitDynamic("@convention(\(convention)")
            if nb.firstChild(of: node).map({ nb.kind(of: $0) }) == .ClangType {
                emit(", mangledCType: \""); _ = print(nb.child(of: node, at: 0), depth: d); emit("\"")
            }
            emit(") ")
        }

        switch nb.kind(of: node) {
        case .FunctionType, .UncurriedFunctionType, .NoEscapeFunctionType: break
        case .AutoClosureType, .EscapingAutoClosureType: emit("@autoclosure ")
        case .ThinFunctionType: emit("@convention(thin) ")
        case .CFunctionPointer: printConventionWithMangledCType("c")
        case .EscapingObjCBlock: emit("@escaping "); printConventionWithMangledCType("block")
        case .ObjCBlock: printConventionWithMangledCType("block")
        default: break
        }

        let argIndex = nb.childCount(of: node) - 2
        var startIndex = 0
        var isSendable = false, isAsync = false, hasSendingResult = false
        var diffKind: UnicodeScalar = "\0"
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .ClangType { startIndex += 1 }
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .SendingResultFunctionType { startIndex += 1; hasSendingResult = true }
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .IsolatedAnyFunctionType { _ = print(nb.child(of: node, at: startIndex), depth: d); startIndex += 1 }
        var nonIsolatedCaller: B.Node?
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .NonIsolatedCallerFunctionType { nonIsolatedCaller = nb.child(of: node, at: startIndex); startIndex += 1 }
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .GlobalActorFunctionType { _ = print(nb.child(of: node, at: startIndex), depth: d); startIndex += 1 }
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .DifferentiableFunctionType {
            diffKind = UnicodeScalar(UInt8(nb.index(of: nb.child(of: node, at: startIndex)) ?? 0)); startIndex += 1
        }
        var thrownErrorNode: B.Node?
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .ThrowsAnnotation || nb.kind(of: nb.child(of: node, at: startIndex)) == .TypedThrowsAnnotation {
            thrownErrorNode = nb.child(of: node, at: startIndex); startIndex += 1
        }
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .ConcurrentFunctionType { startIndex += 1; isSendable = true }
        if nb.kind(of: nb.child(of: node, at: startIndex)) == .AsyncAnnotation { startIndex += 1; isAsync = true }

        switch diffKind {
        case "f": emit("@differentiable(_forward) ")
        case "r": emit("@differentiable(reverse) ")
        case "l": emit("@differentiable(_linear) ")
        case "d": emit("@differentiable ")
        default: break
        }
        if let nonIsolatedCaller { _ = print(nonIsolatedCaller, depth: d) }
        if isSendable { emit("@Sendable ") }

        printFunctionParameters(labelList: labelList, nb.child(of: node, at: argIndex), depth: depth, showTypes: options.showFunctionArgumentTypes)
        if !options.showFunctionArgumentTypes { return }
        if isAsync { emit(" async") }
        if let thrownErrorNode { _ = print(thrownErrorNode, depth: d) }
        emit(" -> ")
        if hasSendingResult { emit("sending ") }
        _ = print(nb.child(of: node, at: argIndex + 1), depth: d)
    }

    mutating func printFunctionParameters(labelList: B.Node?, _ parameterType: B.Node, depth: Int, showTypes: Bool) {
        let d = depth + 1
        guard nb.kind(of: parameterType) == .ArgumentTuple else { setInvalid(); return }
        guard let parameters = nb.firstChild(of: parameterType).flatMap({ nb.firstChild(of: $0) }) else { return }
        if nb.kind(of: parameters) != .Tuple {
            if showTypes { emit("("); _ = print(parameters, depth: d); emit(")") } else { emit("(_:)") }
            return
        }
        let hasLabels = (labelList.map { nb.childCount(of: $0) } ?? 0) > 0
        emit("(")
        for index in 0 ..< nb.childCount(of: parameters) {
            let param = nb.child(of: parameters, at: index)
            if index != 0 { emit(showTypes ? ", " : "") }
            if hasLabels, let label = labelList.flatMap({ child($0, index) }) {
                // Sequential emits instead of `(text ?? "_") + ":"` string
                // interpolation — byte-identical (an `.Identifier` without
                // text still renders `_`), no intermediate `String`.
                if nb.kind(of: label) == .Identifier, nb.hasText(of: label) {
                    emitText(of: label)
                } else {
                    emit("_")
                }
                emit(":")
            } else if !showTypes {
                if let label = childIf(param, .TupleElementName) {
                    emitText(of: label); emit(":")
                } else { emit("_:") }
            }
            if hasLabels, showTypes { emit(" ") }
            if showTypes { _ = print(param, depth: d) }
        }
        emit(")")
    }

    // MARK: Generic signature

    mutating func printGenericSignature(_ node: B.Node, depth: Int) {
        let d = depth + 1
        emit("<")
        let numChildren = nb.childCount(of: node)
        var numGenericParams = 0
        while numGenericParams < numChildren, nb.kind(of: nb.child(of: node, at: numGenericParams)) == .DependentGenericParamCount {
            numGenericParams += 1
        }
        var firstRequirement = numGenericParams
        while firstRequirement < numChildren {
            var c = nb.child(of: node, at: firstRequirement)
            if nb.kind(of: c) == .`Type` { c = nb.firstChild(of: c) ?? c }
            if nb.kind(of: c) != .DependentGenericParamPackMarker, nb.kind(of: c) != .DependentGenericParamValueMarker { break }
            firstRequirement += 1
        }

        func isGenericParamPack(_ gpDepth: UInt64, _ index: UInt64) -> Bool {
            for i in numGenericParams ..< firstRequirement {
                var c = nb.child(of: node, at: i)
                guard nb.kind(of: c) == .DependentGenericParamPackMarker else { continue }
                guard let inner = nb.firstChild(of: c) else { continue }
                c = inner
                guard nb.kind(of: c) == .`Type`, let pt = nb.firstChild(of: c), nb.kind(of: pt) == .DependentGenericParamType else { continue }
                if index == nb.firstChild(of: pt).flatMap({ nb.index(of: $0) }), gpDepth == child(pt, 1).flatMap({ nb.index(of: $0) }) { return true }
            }
            return false
        }
        func isGenericParamValue(_ gpDepth: UInt64, _ index: UInt64) -> B.Node? {
            for i in numGenericParams ..< firstRequirement {
                let marker = nb.child(of: node, at: i)
                // The value marker wraps the parameter (`Type` → `DependentGenericParamType`)
                // as child 0 and the value's type as child 1.
                guard nb.kind(of: marker) == .DependentGenericParamValueMarker,
                      let inner = nb.firstChild(of: marker), nb.kind(of: inner) == .`Type`,
                      let param = nb.firstChild(of: inner), nb.kind(of: param) == .DependentGenericParamType,
                      let type = child(marker, 1) else { continue }
                if index == nb.firstChild(of: param).flatMap({ nb.index(of: $0) }), gpDepth == child(param, 1).flatMap({ nb.index(of: $0) }) { return type }
            }
            return nil
        }

        for gpDepth in 0 ..< numGenericParams {
            if gpDepth != 0 { emit("><") }
            let count = nb.index(of: nb.child(of: node, at: gpDepth)) ?? 0
            var index: UInt64 = 0
            while index < count {
                if index != 0 { emit(", ") }
                if index >= 128 { emit("..."); break }
                if isGenericParamPack(UInt64(gpDepth), index) { emit("each ") }
                let value = isGenericParamValue(UInt64(gpDepth), index)
                if value != nil { emit("let ") }
                emitDynamic(options.genericParameterName(depth: UInt64(gpDepth), index: index))
                index += 1
            }
        }
        if firstRequirement != numChildren, options.displayWhereClauses {
            emit(" where ")
            for i in firstRequirement ..< numChildren {
                if i > firstRequirement { emit(", ") }
                _ = print(nb.child(of: node, at: i), depth: d)
            }
        }
        emit(">")
    }

    mutating func printLayoutRequirement(_ node: B.Node, depth: Int) {
        let d = depth + 1
        printChild0(node, d); emit(": ")
        guard let layout = child(node, 1), let c = (nb.text(of: layout) ?? "").first else { return }
        let name = switch c {
        case "U": "_UnknownLayout"
        case "R": "_RefCountedObject"
        case "N": "_NativeRefCountedObject"
        case "C": "AnyObject"
        case "D": "_NativeClass"
        case "T": "_Trivial"
        case "E", "e": "_Trivial"
        case "M", "m": "_TrivialAtMost"
        default: ""
        }
        emitDynamic(name)
        if nb.childCount(of: node) > 2 {
            emit("("); _ = print(nb.child(of: node, at: 2), depth: d)
            if nb.childCount(of: node) > 3 { emit(", "); _ = print(nb.child(of: node, at: 3), depth: d) }
            emit(")")
        }
    }

    // MARK: Specializations

    mutating func printSpecializationPrefix(_ node: B.Node, _ description: String, depth: Int, paramPrefix: String = "") {
        if !options.displayGenericSpecializations {
            if !specializationPrefixPrinted { emit("specialized "); specializationPrefixPrinted = true }
            return
        }
        if nb.firstChild(of: node).map({ nb.kind(of: $0) }) == .RepresentationChanged { emit("representation changed of "); return }
        emitDynamic(description); emit(" <")
        var separator = ""
        var argNum = 0
        for i in 0 ..< nb.childCount(of: node) {
            let child = nb.child(of: node, at: i)
            switch nb.kind(of: child) {
            case .SpecializationPassID, .DroppedArgument: break
            case .IsSerialized:
                emitDynamic(separator); separator = ", "; _ = print(child, depth: depth + 1)
            default:
                if nb.childCount(of: child) != 0 {
                    emitDynamic(separator); emitDynamic(paramPrefix); separator = ", "
                    switch nb.kind(of: child) {
                    case .FunctionSignatureSpecializationParam:
                        emit("Arg["); emit(UInt64(argNum)); emit("] = "); printFunctionSigSpecializationParams(child, depth: depth)
                    case .FunctionSignatureSpecializationReturn:
                        emit("Return = "); printFunctionSigSpecializationParams(child, depth: depth)
                    default:
                        _ = print(child, depth: depth + 1)
                    }
                }
                argNum += 1
            }
        }
        emit("> of ")
    }

    mutating func printFunctionSigSpecializationParams(_ node: B.Node, depth: Int) {
        // Two-cursor walk mirroring swift's NodePrinter.cpp: `idx` iterates the
        // param's kinds (and the inline Integer/Float/String payloads), while
        // `argIdx` (via `printNextParamChildNode`) scans past kind/payload nodes
        // to the Type/Identifier operand of a struct / key-path / propagated
        // function or global. A single cursor cannot express this: a composite's
        // kinds all precede its operands (e.g. `[Struct : A][Struct : B]`).
        let d = depth + 1
        var idx = 0
        var argIdx = 0
        let end = nb.childCount(of: node)
        while idx < end {
            guard let k = nb.index(of: nb.child(of: node, at: idx)) else { return }
            switch k {
            case 6, 7, 8: // BoxToValue, BoxToStack, InOutToOut
                _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
            case 0, 1: // ConstantPropFunction, ConstantPropGlobal
                emit("["); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit(" : "); printNextParamChildNode(node, &argIdx, kind: k, depth: depth)
                emit("]")
            case 2, 3: // ConstantPropInteger, ConstantPropFloat
                if idx + 2 > end { return }
                emit("["); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit(" : "); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1; emit("]")
            case 4: // ConstantPropString
                if idx + 2 > end { return }
                emit("["); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit(" : "); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit("'"); printNextParamChildNode(node, &argIdx, kind: k, depth: depth); emit("'")
                emit("]")
            case 9: // ConstantPropKeyPath
                emit("["); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit(" : "); printNextParamChildNode(node, &argIdx, kind: k, depth: depth)
                emit("<"); printNextParamChildNode(node, &argIdx, kind: k, depth: depth)
                emit(","); printNextParamChildNode(node, &argIdx, kind: k, depth: depth)
                emit(">]")
            case 10: // ConstantPropStruct
                emit("["); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit(" : "); printNextParamChildNode(node, &argIdx, kind: k, depth: depth); emit("]")
            case 5: // ClosureProp
                if idx + 2 > end { return }
                emit("["); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit(" : "); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit(", Argument Types : [")
                while idx < nb.childCount(of: node) {
                    let c = nb.child(of: node, at: idx)
                    if nb.kind(of: c) != .`Type` { break }
                    _ = print(c, depth: d); idx += 1
                    if idx < nb.childCount(of: node), nb.text(of: nb.child(of: node, at: idx)) != nil { emit(", ") }
                }
                emit("]")
            case 11: // ClosurePropPreviousArg ("Same As Argument"): kind then index
                if idx + 2 > end { return }
                emit("["); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
                emit(" "); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1; emit("]")
            default:
                _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
            }
        }
    }

    /// Print the next operand child of a FunctionSignatureSpecializationParam,
    /// advancing `argIdx` past kind/payload nodes to the operand. Mirrors swift's
    /// `printNextParamChildNode`: struct / key-path operands are Types; a
    /// propagated function/global name is demangled; a constant-prop string drops
    /// its leading `_` escape on print.
    private mutating func printNextParamChildNode(_ node: B.Node, _ argIdx: inout Int, kind: UInt64, depth: Int) {
        while argIdx < nb.childCount(of: node) {
            let child = nb.child(of: node, at: argIdx); argIdx += 1
            if nb.kind(of: child) == .FunctionSignatureSpecializationParamKind
                || nb.kind(of: child) == .FunctionSignatureSpecializationParamPayload
            {
                continue
            }
            switch kind {
            case 2, 3: // ConstantPropInteger, ConstantPropFloat
                guard let text = nb.text(of: child) else { return }
                let dm = demangleSymbolAsString(text)
                emitDynamic(dm.isEmpty ? text : dm)
            case 4: // ConstantPropString
                if let text = nb.text(of: child), text.first == "_" {
                    emitDynamic(String(text.dropFirst())); return
                }
                _ = print(child, depth: depth + 1)
            case 0, 1: // ConstantPropFunction, ConstantPropGlobal
                let dm = demangleSymbolAsString(nb.text(of: child) ?? "")
                emitDynamic(dm.isEmpty ? (nb.text(of: child) ?? "") : dm)
            default:
                _ = print(child, depth: depth + 1)
            }
            return
        }
    }

    mutating func printFunctionSigSpecializationParamKind(_ node: B.Node) {
        let raw = nb.index(of: node) ?? 0
        var printed = false
        if raw & (1 << 10) != 0 { printed = true; emit("Existential To Protocol Constrained Generic") } // ExistentialToGeneric
        if raw & (1 << 6) != 0 { if printed { emit(" and ") }; printed = true; emit("Dead") }
        if raw & (1 << 7) != 0 { if printed { emit(" and ") }; printed = true; emit("Owned To Guaranteed") }
        if raw & (1 << 9) != 0 { if printed { emit(" and ") }; printed = true; emit("Guaranteed To Owned") }
        if raw & (1 << 8) != 0 { if printed { emit(" and ") }; emit("Exploded"); return }
        if printed { return }
        switch raw {
        case 6: emit("Value Promoted from Box")
        case 7: emit("Stack Promoted from Box")
        case 8: emit("InOut Converted to Out")
        case 0: emit("Constant Propagated Function")
        case 1: emit("Constant Propagated Global")
        case 2: emit("Constant Propagated Integer")
        case 3: emit("Constant Propagated Float")
        case 4: emit("Constant Propagated String")
        case 9: emit("Constant Propagated KeyPath")
        case 10: emit("Constant Propagated Struct")
        case 5: emit("Closure Propagated")
        case 11: emit("Same As Argument")
        default: break
        }
    }

    mutating func printImplFunctionType(_ node: B.Node, depth: Int) {
        let d = depth + 1
        var patternSubs: B.Node?
        var invocationSubs: B.Node?
        var sendingResult: B.Node?
        typealias State = ImplFunctionTypePrintState
        var curState: State = .attrs
        func transition(to newState: State) {
            while curState != newState {
                switch curState {
                case .attrs:
                    if let patternSubs { emit("@substituted "); _ = print(nb.child(of: patternSubs, at: 0), depth: d); emit(" ") }
                    emit("(")
                case .inputs:
                    emit(") -> ")
                    if let sendingResult { _ = print(sendingResult, depth: d); emit(" ") }
                    emit("(")
                case .results: break
                }
                curState = State(rawValue: curState.rawValue + 1) ?? .results
            }
        }
        for i in 0 ..< nb.childCount(of: node) {
            let child = nb.child(of: node, at: i)
            if nb.kind(of: child) == .ImplParameter {
                if curState == .inputs { emit(", ") }
                transition(to: .inputs); _ = print(child, depth: d)
            } else if nb.kind(of: child) == .ImplResult || nb.kind(of: child) == .ImplYield || nb.kind(of: child) == .ImplErrorResult {
                if curState == .results { emit(", ") }
                transition(to: .results); _ = print(child, depth: d)
            } else if nb.kind(of: child) == .ImplPatternSubstitutions {
                patternSubs = child
            } else if nb.kind(of: child) == .ImplInvocationSubstitutions {
                invocationSubs = child
            } else if nb.kind(of: child) == .ImplSendingResult {
                sendingResult = child
            } else {
                _ = print(child, depth: d); emit(" ")
            }
        }
        transition(to: .results)
        emit(")")
        if let patternSubs { emit(" for <"); printChildren(nb.child(of: patternSubs, at: 1), depth: depth); emit(">") }
        if let invocationSubs { emit(" for <"); printChildren(nb.child(of: invocationSubs, at: 0), depth: depth); emit(">") }
    }

    // MARK: Autodiff / witnesses / boxes / existentials

    mutating func printAutoDiffFunction(_ node: B.Node, depth: Int) {
        let d = depth + 1
        var prefixEnd = 0
        while prefixEnd != nb.childCount(of: node), nb.kind(of: nb.child(of: node, at: prefixEnd)) != .AutoDiffFunctionKind {
            prefixEnd += 1
        }
        guard prefixEnd + 2 < nb.childCount(of: node) else { return }
        let funcKind = nb.child(of: node, at: prefixEnd)
        let paramIndices = nb.child(of: node, at: prefixEnd + 1)
        let resultIndices = nb.child(of: node, at: prefixEnd + 2)
        if nb.kind(of: node) == .AutoDiffDerivativeVTableThunk { emit("vtable thunk for ") }
        _ = print(funcKind, depth: d); emit(" of ")
        var optionalGenSig: B.Node?
        for i in 0 ..< prefixEnd {
            if i == prefixEnd - 1, nb.kind(of: nb.child(of: node, at: i)) == .DependentGenericSignature { optionalGenSig = nb.child(of: node, at: i); break }
            _ = print(nb.child(of: node, at: i), depth: d)
        }
        if options.shortenThunk { return }
        emit(" with respect to parameters "); _ = print(paramIndices, depth: d)
        emit(" and results "); _ = print(resultIndices, depth: d)
        if let optionalGenSig, options.displayWhereClauses { emit(" with "); _ = print(optionalGenSig, depth: d) }
    }

    mutating func printAutoDiffSelfReordering(_ node: B.Node, depth: Int) {
        let d = depth + 1
        emit("autodiff self-reordering reabstraction thunk ")
        var idx = 0
        guard nb.childCount(of: node) >= 2 else { return }
        let fromType = nb.child(of: node, at: idx); idx += 1
        let toType = nb.child(of: node, at: idx); idx += 1
        if options.shortenThunk { emit("for "); _ = print(fromType, depth: d); return }
        var optionalGenSig: B.Node?
        if idx < nb.childCount(of: node), nb.kind(of: nb.child(of: node, at: idx)) == .DependentGenericSignature { optionalGenSig = nb.child(of: node, at: idx); idx += 1 }
        emit("for ")
        if idx < nb.childCount(of: node) { _ = print(nb.child(of: node, at: idx), depth: d); idx += 1 }
        if let optionalGenSig { _ = print(optionalGenSig, depth: d); emit(" ") }
        emit(" from "); _ = print(fromType, depth: d)
        emit(" to "); _ = print(toType, depth: d)
    }

    mutating func printAutoDiffSubsetParameters(_ node: B.Node, depth: Int) {
        let d = depth + 1
        emit("autodiff subset parameters thunk for ")
        var currentIndex = nb.childCount(of: node) - 1
        guard currentIndex >= 3 else { return }
        let toParamIndices = nb.child(of: node, at: currentIndex); currentIndex -= 1
        let resultIndices = nb.child(of: node, at: currentIndex); currentIndex -= 1
        let paramIndices = nb.child(of: node, at: currentIndex); currentIndex -= 1
        let kind = nb.child(of: node, at: currentIndex); currentIndex -= 1
        _ = print(kind, depth: d); emit(" from ")
        if currentIndex == 0 { _ = print(nb.child(of: node, at: 0), depth: d) }
        else { for i in 0 ..< currentIndex {
            _ = print(nb.child(of: node, at: i), depth: d)
        } }
        if options.shortenThunk { return }
        emit(" with respect to parameters "); _ = print(paramIndices, depth: d)
        emit(" and results "); _ = print(resultIndices, depth: d)
        emit(" to parameters "); _ = print(toParamIndices, depth: d)
        if currentIndex > 0 { emit(" of type "); _ = print(nb.child(of: node, at: currentIndex), depth: d) }
    }

    mutating func printDifferentiabilityWitness(_ node: B.Node, depth: Int) {
        let d = depth + 1
        let kindNodeIndex = nb.childCount(of: node) - (nb.lastChild(of: node).map { nb.kind(of: $0) } == .DependentGenericSignature ? 4 : 3)
        guard kindNodeIndex >= 0, kindNodeIndex < nb.childCount(of: node) else { return }
        switch UnicodeScalar(UInt8(nb.index(of: nb.child(of: node, at: kindNodeIndex)) ?? 0)) {
        case "f": emit("forward-mode")
        case "r": emit("reverse-mode")
        case "d": emit("normal")
        case "l": emit("linear")
        default: break
        }
        emit(" differentiability witness for ")
        var idx = 0
        while idx < nb.childCount(of: node), nb.kind(of: nb.child(of: node, at: idx)) != .Index {
            _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
        }
        idx += 1 // skip kind
        guard idx + 1 < nb.childCount(of: node) else { return }
        emit(" with respect to parameters "); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
        emit(" and results "); _ = print(nb.child(of: node, at: idx), depth: d); idx += 1
        if idx < nb.childCount(of: node) { emit(" with "); _ = print(nb.child(of: node, at: idx), depth: d) }
    }

    mutating func printSILBoxTypeWithLayout(_ node: B.Node, depth: Int) {
        let d = depth + 1
        guard let layout = nb.firstChild(of: node) else { return }
        var genericArgs: B.Node?
        if nb.childCount(of: node) == 3 {
            _ = print(nb.child(of: node, at: 1), depth: d); emit(" ")
            genericArgs = nb.child(of: node, at: 2)
        }
        _ = print(layout, depth: d)
        if let genericArgs {
            emit(" <")
            for i in 0 ..< nb.childCount(of: genericArgs) {
                if i > 0 { emit(", ") }; _ = print(nb.child(of: genericArgs, at: i), depth: d)
            }
            emit(">")
        }
    }

    mutating func printExtendedExistentialTypeShape(_ node: B.Node, depth: Int) {
        let d = depth + 1
        let savedWhere = options.displayWhereClauses
        options.displayWhereClauses = true
        let genSig: B.Node? = nb.childCount(of: node) == 2 ? child(node, 1) : nil
        let type: B.Node? = nb.childCount(of: node) == 2 ? child(node, 2) : child(node, 1)
        emit("existential shape for ")
        if let genSig { _ = print(genSig, depth: d); emit(" ") }
        emit("any ")
        if let type { _ = print(type, depth: d) } else { emit("<null node pointer>") }
        options.displayWhereClauses = savedWhere
    }

    mutating func printProtocolConformance(_ node: B.Node, depth: Int) {
        let d = depth + 1
        guard nb.childCount(of: node) >= 3 else { return }
        let c0 = nb.child(of: node, at: 0), c1 = nb.child(of: node, at: 1), c2 = nb.child(of: node, at: 2)
        if nb.childCount(of: node) == 4 {
            emit("property behavior storage of "); _ = print(c2, depth: d)
            emit(" in "); _ = print(c0, depth: d); emit(" : "); _ = print(c1, depth: d)
        } else {
            _ = print(c0, depth: d)
            if options.displayProtocolConformances {
                emit(" : "); _ = print(c1, depth: d); emit(" in "); _ = print(c2, depth: d)
            }
        }
    }

    // MARK: Entities

    mutating func printAbstractStorage(_ node: B.Node, depth: Int, asPrefixContext: Bool, extraName: String) -> B.Node? {
        switch nb.kind(of: node) {
        case .Variable:
            printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .withColon, hasName: true, extraName: extraName)
        case .Subscript:
            printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .withColon, hasName: false,
                        extraName: extraName, extraIndex: -1, overwriteName: "subscript")
        default:
            nil
        }
    }

    mutating func printEntity(_ entity0: B.Node, depth: Int, asPrefixContext: Bool, type typePr0: TypePrinting,
                              hasName: Bool, extraName: String = "", extraIndex: Int = -1, overwriteName: String = "") -> B.Node?
    {
        var entity = entity0
        var typePr = typePr0
        var extraName = extraName
        var extraIndex = extraIndex
        let d = depth + 1

        var genericFunctionTypeList: B.Node?
        if nb.kind(of: entity) == .BoundGenericFunction, nb.childCount(of: entity) >= 2 {
            genericFunctionTypeList = nb.child(of: entity, at: 1)
            entity = nb.child(of: entity, at: 0)
        }

        // A byte scan as a SHORT-CIRCUIT, not a replacement. `contains(" ")` is a
        // grapheme search over the whole string, run on every entity printed —
        // and `printEntity` is the hottest path in the printer. The two
        // predicates are not interchangeable in general: a U+0020 followed by a
        // combining scalar is ONE grapheme and is not `" "`, so a byte scan
        // answers true where the grapheme search answers false. The implication
        // that IS exhaustively true is the other direction — a `" "` grapheme
        // requires the byte 0x20, since U+0020 has no canonical decomposition and
        // nothing decomposes to it — so a missing 0x20 settles the answer as
        // false with no search at all, and the grapheme search still decides
        // every string that does carry the byte (the handful of entity kinds
        // whose extra name holds a space: `default argument `, the macro
        // expansions). The predicate is therefore identical, not merely
        // equivalent on the corpus.
        var multiWordName = extraName.utf8.contains(0x20) && extraName.contains(" ")
        let localName = hasName && nb.childCount(of: entity) > 1 && nb.kind(of: nb.child(of: entity, at: 1)) == .LocalDeclName
        if localName, options.displayLocalNameContexts { multiWordName = true }

        if asPrefixContext, typePr != .noType || multiWordName { return entity }

        var postfixContext: B.Node?
        if let context = nb.firstChild(of: entity), printContext(context) {
            if multiWordName {
                postfixContext = context
            } else {
                // Byte position, as the reference's `Printer.getStringRef().size()`
                // (NodePrinter.cpp printEntity) — "did the context emit anything".
                // `bytes.count` is that byte length directly (the accumulator IS
                // the byte buffer now), so this is the reference probe verbatim.
                let pos = bytes.count
                postfixContext = print(context, depth: d, asPrefixContext: true)
                if bytes.count != pos { emit(".") }
            }
        }

        printFunctionName(hasName: hasName, overwriteName: overwriteName, extraName: &extraName,
                          multiWordName: multiWordName, extraIndex: &extraIndex, entity: entity, depth: depth)

        if typePr != .noType {
            guard let type = childIf(entity, .`Type`).flatMap({ nb.firstChild(of: $0) }) else { setInvalid(); return nil }
            if typePr == .functionStyle {
                var t = type
                while nb.kind(of: t) == .DependentGenericType, let inner = child(t, 1).flatMap({ nb.firstChild(of: $0) }) {
                    t = inner
                }
                switch nb.kind(of: t) {
                case .FunctionType, .NoEscapeFunctionType, .UncurriedFunctionType, .CFunctionPointer, .ThinFunctionType: break
                default: typePr = .withColon
                }
            }
            if typePr == .withColon {
                if options.displayEntityTypes { emit(" : "); printEntityType(entity, type, genericFunctionTypeList, depth: depth) }
            } else if shouldShowEntityType(nb.kind(of: entity)) {
                if multiWordName || needSpaceBeforeType(type) { emit(" ") }
                printEntityType(entity, type, genericFunctionTypeList, depth: depth)
            }
        }
        if !asPrefixContext, let context = postfixContext, !localName || options.displayLocalNameContexts {
            switch nb.kind(of: entity) {
            case .DefaultArgumentInitializer, .Initializer, .PropertyWrapperBackingInitializer,
                 .PropertyWrappedFieldInitAccessor, .PropertyWrapperInitFromProjectedValue:
                emit(" of ")
            default:
                emit(" in ")
            }
            _ = print(context, depth: d)
            return nil
        }
        return postfixContext
    }

    mutating func printFunctionName(hasName: Bool, overwriteName: String, extraName: inout String, multiWordName: Bool,
                                    extraIndex: inout Int, entity: B.Node, depth: Int)
    {
        if hasName || !overwriteName.isEmpty {
            if !extraName.isEmpty, multiWordName {
                emitDynamic(extraName)
                if extraIndex >= 0 { emitDynamic(String(extraIndex)) }
                emit(" of "); extraName = ""; extraIndex = -1
            }
            // Byte position, as the reference's `CurrentPosition` byte probe
            // (NodePrinter.cpp) — `bytes.count` is that offset directly.
            let pos = bytes.count
            if !overwriteName.isEmpty {
                emitDynamic(overwriteName)
            } else if nb.childCount(of: entity) > 1 {
                let name = nb.child(of: entity, at: 1)
                if nb.kind(of: name) != .PrivateDeclName { _ = print(name, depth: depth + 1) }
                if let privateName = childIf(entity, .PrivateDeclName) { _ = print(privateName, depth: depth + 1) }
            }
            if bytes.count != pos, !extraName.isEmpty { emit(".") }
        }
        if !extraName.isEmpty {
            emitDynamic(extraName)
            if extraIndex >= 0 { emitDynamic(String(extraIndex)) }
        }
    }

    mutating func printEntityType(_ entity: B.Node, _ type0: B.Node, _ genericFunctionTypeList: B.Node?, depth: Int) {
        let d = depth + 1
        var type = type0
        let labelList = childIf(entity, .LabelList)
        if labelList != nil || genericFunctionTypeList != nil {
            if let genericFunctionTypeList { emit("<"); printChildren(genericFunctionTypeList, depth: depth, separator: ", "); emit(">") }
            if nb.kind(of: type) == .DependentGenericType {
                if genericFunctionTypeList == nil { _ = print(nb.child(of: type, at: 0), depth: d) }
                if let dependentType = child(type, 1) {
                    if needSpaceBeforeType(dependentType) { emit(" ") }
                    if let inner = nb.firstChild(of: dependentType) { type = inner }
                }
            }
            printFunctionType(labelList: labelList, type, depth: depth)
        } else {
            _ = print(type, depth: d)
        }
    }

    private mutating func printChild0(_ node: B.Node, _ depth: Int) {
        if let c = nb.firstChild(of: node) { _ = print(c, depth: depth) }
    }
}
