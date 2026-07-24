// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Per-node-kind re-mangling for `Remangler` — ported from the `mangleXXX`
// methods of `lib/Demangling/Remangler.cpp`. The dispatch covers the node
// kinds the corpus exercises; an unported kind returns `false` (a failed
// mangle, surfaced as round-trip-unavailable rather than a wrong answer).

extension Remangler {
    // MARK: Shared helpers

    func mangleFunctionSignature(_ funcType: SwiftSymbol, depth: Int) -> Bool {
        mangleChildNodesReversed(funcType, depth: depth + 1)
    }

    func mangleAnyGenericType(_ node: SwiftSymbol, _ typeOp: String, depth: Int) -> Bool {
        if !trySubstitution(node) {
            guard mangleChildNodes(node, depth: depth + 1) else { return false }
            emit(typeOp)
            addSubstitution(node)
        }
        return true
    }

    func mangleAnyNominalType(_ node: SwiftSymbol, depth: Int) -> Bool {
        if depth > Remangler.maxDepth { return false }
        if isSpecialized(node) {
            if trySubstitution(node) { return true }
            guard let unbound = getUnspecialized(node) else { return false }
            guard mangleAnyNominalType(unbound, depth: depth + 1) else { return false }
            var separator: UInt8 = 0x79 // 'y'
            guard mangleGenericArgs(node, separator: &separator, depth: depth + 1) else { return false }
            if node.children.count == 3 {
                for child in node.children[2].children where !mangle(child, depth: depth + 1) {
                    return false
                }
            }
            emit(UInt8(0x47)) // 'G'
            addSubstitution(node)
            return true
        }
        switch node.kind {
        case .Structure: return mangleAnyGenericType(node, "V", depth: depth)
        case .Enum: return mangleAnyGenericType(node, "O", depth: depth)
        case .Class: return mangleAnyGenericType(node, "C", depth: depth)
        case .OtherNominalType: return mangleAnyGenericType(node, "XY", depth: depth)
        case .TypeAlias: return mangleAnyGenericType(node, "a", depth: depth)
        case .protocolNode: return mangleAnyGenericType(node, "P", depth: depth)
        default: return false
        }
    }

    func mangleGenericArgs(_ node: SwiftSymbol, separator: inout UInt8, depth: Int, fullSubstitutionMap: Bool = false) -> Bool {
        var fullSubstitutionMap = fullSubstitutionMap
        switch node.kind {
        case .protocolNode, .Structure, .Enum, .Class, .TypeAlias:
            if node.kind == .TypeAlias { fullSubstitutionMap = true }
            guard let first = node.firstChild,
                  mangleGenericArgs(first, separator: &separator, depth: depth + 1, fullSubstitutionMap: fullSubstitutionMap)
            else { return false }
            emit(separator); separator = 0x5F // '_'
            return true
        case .Function, .Getter, .Setter, .WillSet, .DidSet, .ReadAccessor, .ModifyAccessor,
             .UnsafeAddressor, .UnsafeMutableAddressor, .Allocator, .Constructor, .Destructor,
             .Variable, .Subscript, .ExplicitClosure, .ImplicitClosure, .DefaultArgumentInitializer,
             .Initializer, .PropertyWrapperBackingInitializer, .PropertyWrappedFieldInitAccessor,
             .PropertyWrapperInitFromProjectedValue, .Static:
            if !fullSubstitutionMap { return true }
            guard let first = node.firstChild,
                  mangleGenericArgs(first, separator: &separator, depth: depth + 1, fullSubstitutionMap: fullSubstitutionMap)
            else { return false }
            if DemanglerPredicates.nodeConsumesGenericArgs(node.kind) {
                emit(separator); separator = 0x5F
            }
            return true
        case .BoundGenericOtherNominalType, .BoundGenericStructure, .BoundGenericEnum,
             .BoundGenericClass, .BoundGenericProtocol, .BoundGenericTypeAlias:
            if node.kind == .BoundGenericTypeAlias { fullSubstitutionMap = true }
            guard let unboundType = node.firstChild, let nominalType = unboundType.firstChild,
                  let parentOrModule = nominalType.firstChild,
                  mangleGenericArgs(parentOrModule, separator: &separator, depth: depth + 1, fullSubstitutionMap: fullSubstitutionMap)
            else { return false }
            emit(separator); separator = 0x5F
            return node.children.count > 1 ? mangleChildNodes(node.children[1], depth: depth + 1) : true
        case .ConstrainedExistential:
            emit(separator); separator = 0x5F
            return node.children.count > 1 ? mangleChildNodes(node.children[1], depth: depth + 1) : true
        case .BoundGenericFunction:
            fullSubstitutionMap = true
            guard let unboundFunction = node.firstChild, let parentOrModule = unboundFunction.firstChild,
                  mangleGenericArgs(parentOrModule, separator: &separator, depth: depth + 1, fullSubstitutionMap: fullSubstitutionMap)
            else { return false }
            emit(separator); separator = 0x5F
            return node.children.count > 1 ? mangleChildNodes(node.children[1], depth: depth + 1) : true
        case .Extension:
            guard node.children.count > 1 else { return false }
            return mangleGenericArgs(node.children[1], separator: &separator, depth: depth + 1, fullSubstitutionMap: fullSubstitutionMap)
        default:
            return true
        }
    }

    /// Returns `(numMembers, dependentBase)` where numMembers is -1 for a
    /// substitution, 0 for a plain generic param, ≥1 for a member chain.
    func mangleConstrainedType(_ node0: SwiftSymbol, depth: Int) -> (Int, SwiftSymbol?)? {
        var node = node0.kind == .`Type` ? (node0.firstChild ?? node0) : node0
        if trySubstitution(node) { return (-1, nil) }
        var chain: [SwiftSymbol] = []
        while node.kind == .DependentMemberType {
            guard node.children.count > 1 else { return nil }
            chain.append(node.children[1])
            guard let base = node.firstChild, base.kind == .`Type`, let inner = base.firstChild else { return nil }
            node = inner
        }
        var resultNode: SwiftSymbol? = node
        if node.kind != .DependentGenericParamType, node.kind != .ConstrainedExistentialSelf {
            guard mangle(node, depth: depth + 1) else { return nil }
            if chain.isEmpty { return (-1, nil) }
            resultNode = nil
        }
        let listSeparator = chain.count > 1
        var first = true
        for depAssoc in chain.reversed() {
            guard mangle(depAssoc, depth: depth + 1) else { return nil }
            if listSeparator, first { emit(UInt8(0x5F)) }
            first = false
        }
        if !chain.isEmpty { addSubstitution(node0.kind == .`Type` ? (node0.firstChild ?? node0) : node0) }
        return (chain.count, resultNode)
    }

    func mangleDependentGenericParamIndex(_ node: SwiftSymbol, nonZeroPrefix: String = "", zeroOp: UInt8 = 0x7A) {
        if node.kind == .ConstrainedExistentialSelf { emit(UInt8(0x73)); return } // 's'
        guard node.children.count >= 2 else { emit(zeroOp); return }
        let paramDepth = node.children[0].index ?? 0
        let index = node.children[1].index ?? 0
        if paramDepth != 0 {
            emit(nonZeroPrefix); emit(UInt8(0x64)) // 'd'
            mangleIndex(paramDepth - 1); mangleIndex(index)
            return
        }
        if index != 0 {
            emit(nonZeroPrefix); mangleIndex(index - 1); return
        }
        emit(zeroOp)
    }

    func manglePureProtocol(_ proto0: SwiftSymbol, depth: Int) -> Bool {
        let proto = skipType(proto0)
        if mangleStandardSubstitution(proto) { return true }
        return mangleChildNodes(proto, depth: depth + 1)
    }

    func mangleAbstractStorage(_ node: SwiftSymbol, _ accessorCode: String, depth: Int) -> Bool {
        guard mangleChildNodes(node, depth: depth + 1) else { return false }
        switch node.kind {
        case .Subscript: emit(UInt8(0x69)) // 'i'
        case .Variable: emit(UInt8(0x76)) // 'v'
        default: return false
        }
        emit(accessorCode)
        return true
    }

    func mangleAnyConstructor(_ node: SwiftSymbol, _ kindOp: UInt8, depth: Int) -> Bool {
        guard mangleChildNodes(node, depth: depth + 1) else { return false }
        emit(UInt8(0x66)); emit(kindOp) // 'f' + kind
        return true
    }

    func isSpecialized(_ node: SwiftSymbol) -> Bool {
        switch node.kind {
        case .BoundGenericStructure, .BoundGenericEnum, .BoundGenericClass,
             .BoundGenericOtherNominalType, .BoundGenericTypeAlias, .BoundGenericProtocol,
             .BoundGenericFunction, .ConstrainedExistential:
            true
        case .Structure, .Enum, .Class, .TypeAlias, .OtherNominalType, .protocolNode, .Function,
             .Allocator, .Constructor, .Destructor, .Variable, .Subscript, .ExplicitClosure,
             .ImplicitClosure, .Initializer, .PropertyWrapperBackingInitializer,
             .PropertyWrappedFieldInitAccessor, .PropertyWrapperInitFromProjectedValue,
             .DefaultArgumentInitializer, .Getter, .Setter, .WillSet, .DidSet, .ReadAccessor,
             .ModifyAccessor, .UnsafeAddressor, .UnsafeMutableAddressor, .Static:
            !node.children.isEmpty && isSpecialized(node.children[0])
        case .Extension:
            node.children.count > 1 && isSpecialized(node.children[1])
        default:
            false
        }
    }

    func getUnspecialized(_ node: SwiftSymbol) -> SwiftSymbol? {
        var numToCopy = 2
        switch node.kind {
        case .Function, .Getter, .Setter, .WillSet, .DidSet, .ReadAccessor, .ModifyAccessor,
             .UnsafeAddressor, .UnsafeMutableAddressor, .Allocator, .Constructor, .Destructor,
             .Variable, .Subscript, .ExplicitClosure, .ImplicitClosure, .Initializer,
             .PropertyWrapperBackingInitializer, .PropertyWrappedFieldInitAccessor,
             .PropertyWrapperInitFromProjectedValue, .DefaultArgumentInitializer, .Static:
            numToCopy = node.children.count
            fallthrough
        case .Structure, .Enum, .Class, .TypeAlias, .OtherNominalType:
            guard !node.children.isEmpty else { return nil }
            var parentOrModule = node.children[0]
            if isSpecialized(parentOrModule) {
                guard let unspec = getUnspecialized(parentOrModule) else { return nil }
                parentOrModule = unspec
            }
            var result = SwiftSymbol(kind: node.kind, child: parentOrModule)
            for idx in 1 ..< min(numToCopy, node.children.count) {
                result.addChild(node.children[idx])
            }
            return result
        case .BoundGenericStructure, .BoundGenericEnum, .BoundGenericClass,
             .BoundGenericProtocol, .BoundGenericOtherNominalType, .BoundGenericTypeAlias:
            guard let unboundType = node.firstChild, unboundType.kind == .`Type`,
                  let nominalType = unboundType.firstChild else { return nil }
            return isSpecialized(nominalType) ? getUnspecialized(nominalType) : nominalType
        case .ConstrainedExistential:
            return node.firstChild
        case .BoundGenericFunction:
            guard let unboundFunction = node.firstChild else { return nil }
            return isSpecialized(unboundFunction) ? getUnspecialized(unboundFunction) : unboundFunction
        case .Extension:
            // A nominal nested in an extension of a specialized type: rebuild the
            // extension with its parent unspecialized (the missing case behind the
            // extension-generic remangle-nils).
            guard node.children.count >= 2 else { return nil }
            let parent = node.children[1]
            if !isSpecialized(parent) { return node }
            guard let unspec = getUnspecialized(parent), let first = node.firstChild else { return nil }
            var result = SwiftSymbol(kind: .Extension, children: [first, unspec])
            if node.children.count == 3 { result.addChild(node.children[2]) }
            return result
        default:
            return nil
        }
    }

    func mangleAnyProtocolConformanceList(_ node: SwiftSymbol, depth: Int) -> Bool {
        var first = true
        for child in node.children {
            guard mangle(child, depth: depth + 1) else { return false }
            mangleListSeparator(&first)
        }
        mangleEndOfList(first)
        return true
    }
}
