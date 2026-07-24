// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Entities, accessors, protocol lists, generic signatures / requirements,
// value witnesses, and macro expansions for the current-mangling `Demangler`
// — ported from `lib/Demangling/Demangler.cpp`.

// The `Demangler` methods below are generic (over the node builder), and Swift
// forbids a type nested inside a generic function; these locals live at file
// scope instead. They are decode-shape enums with no node dependency.
private enum FunctionEntityArgsKind { case none, typeAndMaybePrivateName, typeAndIndex, index }
private enum GenericRequirementTyKind { case generic, assoc, compoundAssoc, substitution }
private enum GenericRequirementConstraintKind { case proto, baseClass, sameType, sameShape, layout, packMarker, inverse, valueMarker }

extension Demangler {
    mutating func demangleAccessor(_ childNode: B.Node?) -> B.Node? {
        let kind: SwiftSymbol.Kind
        switch nextChar() {
        case 0x6D: kind = .MaterializeForSet // 'm'
        case 0x73: kind = .Setter // 's'
        case 0x67: kind = .Getter // 'g'
        case 0x47: kind = .GlobalGetter // 'G'
        case 0x77: kind = .WillSet // 'w'
        case 0x57: kind = .DidSet // 'W'
        case 0x72: kind = .ReadAccessor // 'r'
        case 0x79: kind = .YieldingBorrowAccessor // 'y'
        case 0x4D: kind = .ModifyAccessor // 'M'
        case 0x78: kind = .YieldingMutateAccessor // 'x'
        case 0x69: kind = .InitAccessor // 'i'
        case 0x62: kind = .BorrowAccessor // 'b'
        case 0x7A: kind = .MutateAccessor // 'z'
        case 0x61: // 'a' mutable addressor
            switch nextChar() {
            case 0x4F: kind = .OwningMutableAddressor // 'O'
            case 0x6F: kind = .NativeOwningMutableAddressor // 'o'
            case 0x50: kind = .NativePinningMutableAddressor // 'P'
            case 0x75: kind = .UnsafeMutableAddressor // 'u'
            default: return nil
            }
        case 0x6C: // 'l' non-mutable addressor
            switch nextChar() {
            case 0x4F: kind = .OwningAddressor // 'O'
            case 0x6F: kind = .NativeOwningAddressor // 'o'
            case 0x70: kind = .NativePinningAddressor // 'p'
            case 0x75: kind = .UnsafeAddressor // 'u'
            default: return nil
            }
        case 0x70: return childNode // 'p' pseudo-accessor
        default: return nil
        }
        return createWithChild(kind, childNode)
    }

    mutating func demangleFunctionEntity() -> B.Node? {
        typealias ArgsKind = FunctionEntityArgsKind
        let args: ArgsKind
        let kind: SwiftSymbol.Kind
        switch nextChar() {
        case 0x44: args = .none; kind = .Deallocator // 'D'
        case 0x64: args = .none; kind = .Destructor // 'd'
        case 0x5A: args = .none; kind = .IsolatedDeallocator // 'Z'
        case 0x45: args = .none; kind = .IVarDestroyer // 'E'
        case 0x65: args = .none; kind = .IVarInitializer // 'e'
        case 0x69: args = .none; kind = .Initializer // 'i'
        case 0x43: args = .typeAndMaybePrivateName; kind = .Allocator // 'C'
        case 0x63: args = .typeAndMaybePrivateName; kind = .Constructor // 'c'
        case 0x55: args = .typeAndIndex; kind = .ExplicitClosure // 'U'
        case 0x75: args = .typeAndIndex; kind = .ImplicitClosure // 'u'
        case 0x41: args = .index; kind = .DefaultArgumentInitializer // 'A'
        case 0x6D: return demangleEntity(.Macro) // 'm'
        case 0x4D: return demangleMacroExpansion() // 'M'
        case 0x70: return demangleEntity(.GenericTypeParamDecl) // 'p'
        case 0x50: args = .none; kind = .PropertyWrapperBackingInitializer // 'P'
        case 0x46: args = .none; kind = .PropertyWrappedFieldInitAccessor // 'F'
        case 0x57: args = .none; kind = .PropertyWrapperInitFromProjectedValue // 'W'
        default: return nil
        }

        var nameOrIndex: B.Node?
        var paramType: B.Node?
        var labelList: B.Node?
        switch args {
        case .none: break
        case .typeAndMaybePrivateName:
            nameOrIndex = popNode(.PrivateDeclName)
            paramType = popNode(.`Type`)
            labelList = popFunctionParamLabels(paramType)
        case .typeAndIndex:
            nameOrIndex = demangleIndexAsNode()
            paramType = popNode(.`Type`)
        case .index:
            nameOrIndex = demangleIndexAsNode()
        }
        var entity = createWithChild(kind, popContext())
        switch args {
        case .none: break
        case .index:
            entity = addChild(entity, nameOrIndex)
        case .typeAndMaybePrivateName:
            if let labelList { entity = addChild(entity, labelList) }
            entity = addChild(entity, paramType)
            if let nameOrIndex { entity = addChild(entity, nameOrIndex) }
        case .typeAndIndex:
            entity = addChild(entity, nameOrIndex)
            entity = addChild(entity, paramType)
        }
        return entity
    }

    mutating func demangleEntity(_ kind: SwiftSymbol.Kind) -> B.Node? {
        let type = popNode(.`Type`)
        let labelList = popFunctionParamLabels(type)
        let name = popNode(DemanglerPredicates.isDeclName)
        let context = popContext()
        let result = labelList != nil
            ? createWithChildren(kind, context, name, labelList, type)
            : createWithChildren(kind, context, name, type)
        return setParentForOpaqueReturnTypeNodes(result: result, type: type)
    }

    mutating func demangleVariable() -> B.Node? {
        let variable = demangleEntity(.Variable)
        return demangleAccessor(variable)
    }

    mutating func demangleSubscript() -> B.Node? {
        let privateName = popNode(.PrivateDeclName)
        let type = popNode(.`Type`)
        let labelList = popFunctionParamLabels(type)
        let context = popContext()
        guard type != nil else { return nil }
        var subscriptNode = createWithChild(.Subscript, context)
        if let labelList { subscriptNode = addChild(subscriptNode, labelList) }
        subscriptNode = addChild(subscriptNode, type)
        if let privateName { subscriptNode = addChild(subscriptNode, privateName) }
        subscriptNode = setParentForOpaqueReturnTypeNodes(result: subscriptNode, type: type)
        return demangleAccessor(subscriptNode)
    }

    // MARK: Protocol lists

    mutating func demangleProtocolList() -> B.Node? {
        var typeList = nb.make(kind: .TypeList)
        if popNode(.EmptyList) == nil {
            var firstElem = false
            repeat {
                firstElem = popNode(.FirstElementMarker) != nil
                guard let proto = popProtocol() else { return nil }
                nb.appendChild(to: &typeList, proto)
            } while !firstElem
            nb.reverseChildren(of: &typeList)
        }
        return nb.make(kind: .ProtocolList, child: typeList)
    }

    mutating func demangleProtocolListType() -> B.Node? {
        createType(demangleProtocolList())
    }

    mutating func demangleConstrainedExistentialRequirementList() -> B.Node? {
        var reqList = nb.make(kind: .ConstrainedExistentialRequirementList)
        var firstElem = false
        repeat {
            firstElem = popNode(.FirstElementMarker) != nil
            guard let req = popNode(DemanglerPredicates.isRequirement) else { return nil }
            nb.appendChild(to: &reqList, req)
        } while !firstElem
        nb.reverseChildren(of: &reqList)
        return reqList
    }

    // MARK: Generic signatures / requirements

    mutating func demangleGenericSignature(hasParamCounts: Bool) -> B.Node? {
        var sig = nb.make(kind: .DependentGenericSignature)
        if hasParamCounts {
            while !nextIf(0x6C) { // 'l'
                var count = 0
                if !nextIf(0x7A) { count = demangleIndex() + 1 } // 'z'
                if count < 0 { return nil }
                nb.appendChild(to: &sig, nb.make(kind: .DependentGenericParamCount, index: UInt64(count)))
            }
        } else {
            nb.appendChild(to: &sig, nb.make(kind: .DependentGenericParamCount, index: 1))
        }
        let numCounts = nb.childCount(of: sig)
        while let req = popNode(DemanglerPredicates.isRequirement) {
            nb.appendChild(to: &sig, req)
        }
        if nb.childCount(of: sig) > numCounts {
            nb.reverseChildrenSuffix(of: &sig, from: numCounts)
        }
        return sig
    }

    mutating func demangleGenericRequirement() -> B.Node? {
        typealias TyKind = GenericRequirementTyKind
        typealias ConstraintKind = GenericRequirementConstraintKind

        let typeKind: TyKind
        let constraintKind: ConstraintKind
        var inverseKind: B.Node?

        switch nextChar() {
        case 0x56: constraintKind = .valueMarker; typeKind = .generic // 'V'
        case 0x76: constraintKind = .packMarker; typeKind = .generic // 'v'
        case 0x63: constraintKind = .baseClass; typeKind = .assoc // 'c'
        case 0x43: constraintKind = .baseClass; typeKind = .compoundAssoc // 'C'
        case 0x62: constraintKind = .baseClass; typeKind = .generic // 'b'
        case 0x42: constraintKind = .baseClass; typeKind = .substitution // 'B'
        case 0x74: constraintKind = .sameType; typeKind = .assoc // 't'
        case 0x54: constraintKind = .sameType; typeKind = .compoundAssoc // 'T'
        case 0x73: constraintKind = .sameType; typeKind = .generic // 's'
        case 0x53: constraintKind = .sameType; typeKind = .substitution // 'S'
        case 0x6D: constraintKind = .layout; typeKind = .assoc // 'm'
        case 0x4D: constraintKind = .layout; typeKind = .compoundAssoc // 'M'
        case 0x6C: constraintKind = .layout; typeKind = .generic // 'l'
        case 0x4C: constraintKind = .layout; typeKind = .substitution // 'L'
        case 0x70: constraintKind = .proto; typeKind = .assoc // 'p'
        case 0x50: constraintKind = .proto; typeKind = .compoundAssoc // 'P'
        case 0x51: constraintKind = .proto; typeKind = .substitution // 'Q'
        case 0x68: constraintKind = .sameShape; typeKind = .generic // 'h'
        case 0x69: constraintKind = .inverse; typeKind = .generic; inverseKind = demangleIndexAsNode(); if inverseKind == nil { return nil } // 'i'
        case 0x49: constraintKind = .inverse; typeKind = .substitution; inverseKind = demangleIndexAsNode(); if inverseKind == nil { return nil } // 'I'
        case 0x6A: constraintKind = .inverse; typeKind = .assoc; inverseKind = demangleIndexAsNode(); if inverseKind == nil { return nil } // 'j'
        case 0x4A: constraintKind = .inverse; typeKind = .compoundAssoc; inverseKind = demangleIndexAsNode(); if inverseKind == nil { return nil } // 'J'
        default: constraintKind = .proto; typeKind = .generic; pushBack()
        }

        var constrTy: B.Node?
        switch typeKind {
        case .generic:
            constrTy = createType(demangleGenericParamIndex())
        case .assoc:
            constrTy = demangleAssociatedTypeSimple(demangleGenericParamIndex())
            addSubstitution(constrTy)
        case .compoundAssoc:
            constrTy = demangleAssociatedTypeCompound(demangleGenericParamIndex())
            addSubstitution(constrTy)
        case .substitution:
            constrTy = popNode(.`Type`)
        }

        switch constraintKind {
        case .valueMarker:
            return createWithChildren(.DependentGenericParamValueMarker, constrTy, popNode(.`Type`))
        case .packMarker:
            return createWithChild(.DependentGenericParamPackMarker, constrTy)
        case .proto:
            return createWithChildren(.DependentGenericConformanceRequirement, constrTy, popProtocol())
        case .inverse:
            return createWithChildren(.DependentGenericInverseConformanceRequirement, constrTy, inverseKind)
        case .baseClass:
            return createWithChildren(.DependentGenericConformanceRequirement, constrTy, popNode(.`Type`))
        case .sameType:
            return createWithChildren(.DependentGenericSameTypeRequirement, constrTy, popNode(.`Type`))
        case .sameShape:
            return createWithChildren(.DependentGenericSameShapeRequirement, constrTy, popNode(.`Type`))
        case .layout:
            return demangleLayoutRequirement(constrTy)
        }
    }

    private mutating func demangleLayoutRequirement(_ constrTy: B.Node?) -> B.Node? {
        let c = nextChar()
        var size: B.Node?
        var alignment: B.Node?
        let name: String
        switch c {
        case 0x55: name = "U" // 'U'
        case 0x52: name = "R" // 'R'
        case 0x4E: name = "N" // 'N'
        case 0x43: name = "C" // 'C'
        case 0x44: name = "D" // 'D'
        case 0x54: name = "T" // 'T'
        case 0x42: name = "B" // 'B'
        case 0x45: // 'E'
            size = demangleIndexAsNode(); if size == nil { return nil }
            alignment = demangleIndexAsNode(); name = "E"
        case 0x65: // 'e'
            size = demangleIndexAsNode(); if size == nil { return nil }
            name = "e"
        case 0x4D: // 'M'
            size = demangleIndexAsNode(); if size == nil { return nil }
            alignment = demangleIndexAsNode(); name = "M"
        case 0x6D: // 'm'
            size = demangleIndexAsNode(); if size == nil { return nil }
            name = "m"
        case 0x53: // 'S'
            size = demangleIndexAsNode(); if size == nil { return nil }
            name = "S"
        default: return nil
        }
        let nameNode = nb.make(kind: .Identifier, name: name)
        var layout = createWithChildren(.DependentGenericLayoutRequirement, constrTy, nameNode)
        if let size { layout = addChild(layout, size) }
        if let alignment { layout = addChild(layout, alignment) }
        return layout
    }

    mutating func demangleGenericType() -> B.Node? {
        let genSig = popNode(.DependentGenericSignature)
        let ty = popNode(.`Type`)
        return createType(createWithChildren(.DependentGenericType, genSig, ty))
    }

    // MARK: Value witness

    mutating func demangleValueWitness() -> B.Node? {
        let code = String(UnicodeScalar(nextChar())) + String(UnicodeScalar(nextChar()))
        guard let kind = ValueWitnessKinds.index(forCode: code) else { return nil }
        var vw = nb.make(kind: .ValueWitness)
        nb.appendChild(to: &vw, nb.make(kind: .Index, index: UInt64(kind)))
        guard let type = popNode(.`Type`) else { return nil }
        nb.appendChild(to: &vw, type)
        return vw
    }

    // MARK: Macro expansion

    mutating func demangleMacroExpansion() -> B.Node? {
        let kind: SwiftSymbol.Kind
        var isAttached = false
        var isFreestanding = false
        switch nextChar() {
        case 0x61: kind = .AccessorAttachedMacroExpansion; isAttached = true // 'a'
        case 0x72: kind = .MemberAttributeAttachedMacroExpansion; isAttached = true // 'r'
        case 0x6D: kind = .MemberAttachedMacroExpansion; isAttached = true // 'm'
        case 0x70: kind = .PeerAttachedMacroExpansion; isAttached = true // 'p'
        case 0x63: kind = .ConformanceAttachedMacroExpansion; isAttached = true // 'c'
        case 0x65: kind = .ExtensionAttachedMacroExpansion; isAttached = true // 'e'
        case 0x62: kind = .BodyAttachedMacroExpansion; isAttached = true // 'b'
        case 0x66: kind = .FreestandingMacroExpansion; isFreestanding = true // 'f'
        case 0x75: kind = .MacroExpansionUniqueName // 'u'
        case 0x58: // 'X'
            let line = demangleIndex()
            let col = demangleIndex()
            guard line >= 0, col >= 0 else { return nil }
            let lineNode = nb.make(kind: .Index, index: UInt64(line))
            let colNode = nb.make(kind: .Index, index: UInt64(col))
            let buffer = popNode(.Identifier)
            let module = popNode(.Identifier)
            return createWithChildren(.MacroExpansionLoc, module, buffer, lineNode, colNode)
        default: return nil
        }
        let macroName = popNode(.Identifier)
        var privateDiscriminator: B.Node?
        if isFreestanding { privateDiscriminator = popNode(.PrivateDeclName) }
        var attachedName: B.Node?
        if isAttached { attachedName = popNode(DemanglerPredicates.isDeclName) }
        var context = popNode(DemanglerPredicates.isMacroExpansionNodeKind)
        if context == nil { context = popContext() }
        let discriminator = demangleIndexAsNode()
        var result: B.Node? = if isAttached, let attachedName {
            createWithChildren(kind, context, attachedName, macroName, discriminator)
        } else {
            createWithChildren(kind, context, macroName, discriminator)
        }
        if let privateDiscriminator { result = addChild(result, privateDiscriminator) }
        return result
    }
}
