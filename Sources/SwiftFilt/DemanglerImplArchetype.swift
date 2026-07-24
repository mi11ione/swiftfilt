// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// SIL impl-function types, metatypes, archetypes / associated types, and
// special types for the current-mangling `Demangler` — ported from
// `lib/Demangling/Demangler.cpp`.

extension Demangler {
    // MARK: Impl-function types

    mutating func demangleImplParamConvention(_ convKind: SwiftSymbol.Kind) -> B.Node? {
        let attr: String
        switch nextChar() {
        case 0x69: attr = "@in" // 'i'
        case 0x63: attr = "@in_constant" // 'c'
        case 0x6C: attr = "@inout" // 'l'
        case 0x62: attr = "@inout_aliasable" // 'b'
        case 0x6E: attr = "@in_guaranteed" // 'n'
        case 0x58: attr = "@in_cxx" // 'X'
        case 0x78: attr = "@owned" // 'x'
        case 0x67: attr = "@guaranteed" // 'g'
        case 0x65: attr = "@deallocating" // 'e'
        case 0x79: attr = "@unowned" // 'y'
        case 0x76: attr = "@pack_owned" // 'v'
        case 0x70: attr = "@pack_guaranteed" // 'p'
        case 0x6D: attr = "@pack_inout" // 'm'
        default:
            pushBack()
            return nil
        }
        return createWithChild(convKind, nb.make(kind: .ImplConvention, name: attr))
    }

    mutating func demangleImplResultConvention(_ convKind: SwiftSymbol.Kind) -> B.Node? {
        let attr: String
        switch nextChar() {
        case 0x72: attr = "@out" // 'r'
        case 0x6F: attr = "@owned" // 'o'
        case 0x64: attr = "@unowned" // 'd'
        case 0x75: attr = "@unowned_inner_pointer" // 'u'
        case 0x61: attr = "@autoreleased" // 'a'
        case 0x6B: attr = "@pack_out" // 'k'
        case 0x6C: attr = "@guaranteed_address" // 'l'
        case 0x67: attr = "@guaranteed" // 'g'
        case 0x6D: attr = "@inout" // 'm'
        default:
            pushBack()
            return nil
        }
        return createWithChild(convKind, nb.make(kind: .ImplConvention, name: attr))
    }

    mutating func demangleImplParameterSending() -> B.Node? {
        guard nextIf(0x54) else { return nil } // 'T'
        return nb.make(kind: .ImplParameterSending, name: "sending")
    }

    mutating func demangleImplParameterIsolated() -> B.Node? {
        guard nextIf(0x49) else { return nil } // 'I'
        return nb.make(kind: .ImplParameterIsolated, name: "isolated")
    }

    mutating func demangleImplParameterImplicitLeading() -> B.Node? {
        guard nextIf(0x4C) else { return nil } // 'L'
        return nb.make(kind: .ImplParameterImplicitLeading, name: "sil_implicit_leading_param")
    }

    mutating func demangleImplParameterResultDifferentiability() -> B.Node {
        let attr = nextIf(0x77) ? "@noDerivative" : "" // 'w'
        return nb.make(kind: .ImplParameterResultDifferentiability, name: attr)
    }

    mutating func demangleImplFunctionType() -> B.Node? {
        var type = nb.make(kind: .ImplFunctionType)

        if nextIf(0x73) { // 's' pattern substitutions
            guard let (subs, retro) = demangleBoundGenerics(), subs.count == 1,
                  let sig = popNode(.DependentGenericSignature)
            else { return nil }
            var subsNode = nb.make(kind: .ImplPatternSubstitutions, child: sig)
            nb.appendChild(to: &subsNode, subs[0])
            if let retro { nb.appendChild(to: &subsNode, retro) }
            nb.appendChild(to: &type, subsNode)
        }
        if nextIf(0x49) { // 'I' invocation substitutions
            guard let (subs, retro) = demangleBoundGenerics(), subs.count == 1 else { return nil }
            var subsNode = nb.make(kind: .ImplInvocationSubstitutions, child: subs[0])
            if let retro { nb.appendChild(to: &subsNode, retro) }
            nb.appendChild(to: &type, subsNode)
        }

        var genSig = popNode(.DependentGenericSignature)
        if genSig != nil, nextIf(0x50) { // 'P'
            genSig = genSig.map { nb.changingKind($0, to: .DependentPseudogenericSignature) }
        }
        if nextIf(0x65) { nb.appendChild(to: &type, nb.make(kind: .ImplEscaping)) } // 'e'
        if nextIf(0x41) { nb.appendChild(to: &type, nb.make(kind: .ImplErasedIsolation)) } // 'A'
        if nextIf(0x4E) { nb.appendChild(to: &type, nb.make(kind: .ImplNonisolatedNonsendingIsolation)) } // 'N'

        switch peekChar() {
        case 0x64, 0x6C, 0x66, 0x72: // 'd','l','f','r' differentiability
            nb.appendChild(to: &type, nb.make(kind: .ImplDifferentiabilityKind, index: UInt64(nextChar())))
        default: break
        }

        let calleeAttr: String
        switch nextChar() {
        case 0x79: calleeAttr = "@callee_unowned" // 'y'
        case 0x67: calleeAttr = "@callee_guaranteed" // 'g'
        case 0x78: calleeAttr = "@callee_owned" // 'x'
        case 0x74: calleeAttr = "@convention(thin)" // 't'
        default: return nil
        }
        nb.appendChild(to: &type, nb.make(kind: .ImplConvention, name: calleeAttr))

        var funcConv: String?
        var hasClangType = false
        switch nextChar() {
        case 0x42: funcConv = "block" // 'B'
        case 0x43: funcConv = "c" // 'C'
        case 0x7A: // 'z'
            switch nextChar() {
            case 0x42: hasClangType = true; funcConv = "block"
            case 0x43: hasClangType = true; funcConv = "c"
            default: pushBack(); pushBack()
            }
        case 0x4D: funcConv = "method" // 'M'
        case 0x4F: funcConv = "objc_method" // 'O'
        case 0x4B: funcConv = "closure" // 'K'
        case 0x57: funcConv = "witness_method" // 'W'
        default: pushBack()
        }
        if let funcConv {
            var fAttr = nb.make(kind: .ImplFunctionConvention,
                                child: nb.make(kind: .ImplFunctionConventionName, name: funcConv))
            if hasClangType, let ct = demangleClangType() { nb.appendChild(to: &fAttr, ct) }
            nb.appendChild(to: &type, fAttr)
        }

        var coroAttr: String?
        if nextIf(0x41) { coroAttr = "yield_once" } // 'A'
        else if nextIf(0x49) { coroAttr = "yield_once_2" } // 'I'
        else if nextIf(0x47) { coroAttr = "yield_many" } // 'G'
        if let coroAttr { nb.appendChild(to: &type, nb.make(kind: .ImplCoroutineKind, name: coroAttr)) }

        if nextIf(0x68) { nb.appendChild(to: &type, nb.make(kind: .ImplFunctionAttribute, name: "@Sendable")) } // 'h'
        if nextIf(0x48) { nb.appendChild(to: &type, nb.make(kind: .ImplFunctionAttribute, name: "@async")) } // 'H'
        if nextIf(0x54) { nb.appendChild(to: &type, nb.make(kind: .ImplSendingResult)) } // 'T'

        if let genSig { nb.appendChild(to: &type, genSig) }

        var numTypesToAdd = 0
        while var param = demangleImplParamConvention(.ImplParameter) {
            let diff = demangleImplParameterResultDifferentiability()
            nb.appendChild(to: &param, diff)
            if let sending = demangleImplParameterSending() { nb.appendChild(to: &param, sending) }
            if let isolated = demangleImplParameterIsolated() { nb.appendChild(to: &param, isolated) }
            if let leading = demangleImplParameterImplicitLeading() { nb.appendChild(to: &param, leading) }
            nb.appendChild(to: &type, param)
            numTypesToAdd += 1
        }
        while var result = demangleImplResultConvention(.ImplResult) {
            let diff = demangleImplParameterResultDifferentiability()
            nb.appendChild(to: &result, diff)
            nb.appendChild(to: &type, result)
            numTypesToAdd += 1
        }
        while nextIf(0x59) { // 'Y'
            guard let yield = demangleImplParamConvention(.ImplYield) else { return nil }
            nb.appendChild(to: &type, yield)
            numTypesToAdd += 1
        }
        if nextIf(0x7A) { // 'z'
            guard let errorResult = demangleImplResultConvention(.ImplErrorResult) else { return nil }
            nb.appendChild(to: &type, errorResult)
            numTypesToAdd += 1
        }
        guard nextIf(0x5F) else { return nil } // '_'

        for idx in 0 ..< numTypesToAdd {
            guard let convTy = popNode(.`Type`) else { return nil }
            let childIdx = nb.childCount(of: type) - idx - 1
            var conv = nb.child(of: type, at: childIdx)
            nb.appendChild(to: &conv, convTy)
            nb.setChild(of: &type, at: childIdx, to: conv)
        }
        return createType(type)
    }

    // MARK: Metatype / metadata

    mutating func demangleMetatype() -> B.Node? {
        switch nextChar() {
        case 0x61: return createWithPoppedType(.TypeMetadataAccessFunction) // 'a'
        case 0x41: return createWithChild(.ReflectionMetadataAssocTypeDescriptor, popProtocolConformance()) // 'A'
        case 0x62: return createWithPoppedType(.CanonicalSpecializedGenericTypeMetadataAccessFunction) // 'b'
        case 0x42: return createWithChild(.ReflectionMetadataBuiltinDescriptor, popNode(.`Type`)) // 'B'
        case 0x63: return createWithChild(.ProtocolConformanceDescriptor, popProtocolConformance()) // 'c'
        case 0x43: // 'C'
            guard let ty = popNode(.`Type`), let first = nb.firstChild(of: ty),
                  DemanglerPredicates.isAnyGeneric(nb.kind(of: first)) else { return nil }
            return createWithChild(.ReflectionMetadataSuperclassDescriptor, first)
        case 0x44: return createWithPoppedType(.TypeMetadataDemanglingCache) // 'D' (legacy alias)
        case 0x64: return createWithPoppedType(.TypeMetadataDemanglingCache) // 'd' (shipped canonical, swiftlang-6.2+)
        case 0x52: return createWithPoppedType(.TypeMetadataMangledNameRef) // 'R' (shipped, swiftlang-6.2+)
        case 0x66: return createWithPoppedType(.FullTypeMetadata) // 'f'
        case 0x46: return createWithChild(.ReflectionMetadataFieldDescriptor, popNode(.`Type`)) // 'F'
        case 0x67: return createWithChild(.OpaqueTypeDescriptorAccessor, popNode()) // 'g'
        case 0x68: return createWithChild(.OpaqueTypeDescriptorAccessorImpl, popNode()) // 'h'
        case 0x69: return createWithPoppedType(.TypeMetadataInstantiationFunction) // 'i'
        case 0x49: return createWithPoppedType(.TypeMetadataInstantiationCache) // 'I'
        case 0x6A: return createWithChild(.OpaqueTypeDescriptorAccessorKey, popNode()) // 'j'
        case 0x4A: return createWithChild(.NoncanonicalSpecializedGenericTypeMetadataCache, popNode()) // 'J'
        case 0x6B: return createWithChild(.OpaqueTypeDescriptorAccessorVar, popNode()) // 'k'
        case 0x4B: return createWithChild(.MetadataInstantiationCache, popNode()) // 'K'
        case 0x6C: return createWithPoppedType(.TypeMetadataSingletonInitializationCache) // 'l'
        case 0x4C: return createWithPoppedType(.TypeMetadataLazyCache) // 'L'
        case 0x6D: return createWithPoppedType(.Metaclass) // 'm'
        case 0x4D: return createWithPoppedType(.CanonicalSpecializedGenericMetaclass) // 'M'
        case 0x6E: return createWithPoppedType(.NominalTypeDescriptor) // 'n'
        case 0x4E: return createWithPoppedType(.NoncanonicalSpecializedGenericTypeMetadata) // 'N'
        case 0x6F: return createWithPoppedType(.ClassMetadataBaseOffset) // 'o'
        case 0x70: return createWithChild(.ProtocolDescriptor, popProtocol()) // 'p'
        case 0x50: return createWithPoppedType(.GenericTypeMetadataPattern) // 'P'
        case 0x71: return createWithChild(.Uniquable, popNode()) // 'q'
        case 0x51: return createWithChild(.OpaqueTypeDescriptor, popNode()) // 'Q'
        case 0x72: return createWithPoppedType(.TypeMetadataCompletionFunction) // 'r'
        case 0x73: return createWithPoppedType(.ObjCResilientClassStub) // 's'
        case 0x53: return createWithChild(.ProtocolSelfConformanceDescriptor, popProtocol()) // 'S'
        case 0x74: return createWithPoppedType(.FullObjCResilientClassStub) // 't'
        case 0x75: return createWithPoppedType(.MethodLookupFunction) // 'u'
        case 0x55: return createWithPoppedType(.ObjCMetadataUpdateFunction) // 'U'
        case 0x56: return createWithChild(.PropertyDescriptor, popNode(DemanglerPredicates.isEntity)) // 'V'
        case 0x58: return demanglePrivateContextDescriptor() // 'X'
        case 0x7A: return createWithPoppedType(.CanonicalPrespecializedGenericTypeCachingOnceToken) // 'z'
        default: return nil
        }
    }

    mutating func demanglePrivateContextDescriptor() -> B.Node? {
        switch nextChar() {
        case 0x45: return createWithChild(.ExtensionDescriptor, popContext()) // 'E'
        case 0x4D: return createWithChild(.ModuleDescriptor, popModule()) // 'M'
        case 0x59: // 'Y'
            guard let discriminator = popNode(), let context = popContext() else { return nil }
            return nb.make(kind: .AnonymousDescriptor, children: [context, discriminator])
        case 0x58: return createWithChild(.AnonymousDescriptor, popContext()) // 'X'
        case 0x41: // 'A'
            guard let path = popAssocTypePath(), let base = popNode(.`Type`) else { return nil }
            return createWithChildren(.AssociatedTypeGenericParamRef, base, path)
        default: return nil
        }
    }

    // MARK: Archetypes / associated types

    mutating func demangleArchetype() -> B.Node? {
        switch nextChar() {
        case 0x61: // 'a'
            let ident = popNode(.Identifier)
            let archeTy = popTypeAndGetChild()
            guard let assocTy = createType(createWithChildren(.AssociatedTypeRef, archeTy, ident)) else { return nil }
            addSubstitution(assocTy)
            return assocTy
        case 0x4F: // 'O'
            return createWithChild(.OpaqueReturnTypeOf, popContext())
        case 0x6F: // 'o'
            let index = demangleIndex()
            guard index >= 0, let (boundArgs, retro) = demangleBoundGenerics(), let name = popNode() else { return nil }
            var opaque = nb.make(kind: .OpaqueType, children: [name, nb.make(kind: .Index, index: UInt64(index))])
            var boundGenerics = nb.make(kind: .TypeList)
            for arg in boundArgs.reversed() {
                nb.appendChild(to: &boundGenerics, arg)
            }
            nb.appendChild(to: &opaque, boundGenerics)
            if let retro { nb.appendChild(to: &opaque, retro) }
            guard let opaqueTy = createType(opaque) else { return nil }
            addSubstitution(opaqueTy)
            return opaqueTy
        case 0x72: // 'r'
            createdOpaqueReturnType = true
            return createType(nb.make(kind: .OpaqueReturnType))
        case 0x52: // 'R'
            let ordinal = demangleIndex()
            if ordinal < 0 { return nil }
            createdOpaqueReturnType = true
            return createType(createWithChild(.OpaqueReturnType,
                                              nb.make(kind: .OpaqueReturnTypeIndex, index: UInt64(ordinal))))
        case 0x78: // 'x'
            guard let t = demangleAssociatedTypeSimple(nil) else { return nil }
            addSubstitution(t)
            return t
        case 0x58: // 'X'
            guard let t = demangleAssociatedTypeCompound(nil) else { return nil }
            addSubstitution(t)
            return t
        case 0x79: // 'y'
            guard let t = demangleAssociatedTypeSimple(demangleGenericParamIndex()) else { return nil }
            addSubstitution(t)
            return t
        case 0x59: // 'Y'
            guard let t = demangleAssociatedTypeCompound(demangleGenericParamIndex()) else { return nil }
            addSubstitution(t)
            return t
        case 0x7A: // 'z'
            guard let t = demangleAssociatedTypeSimple(getDependentGenericParamType(depth: 0, index: 0)) else { return nil }
            addSubstitution(t)
            return t
        case 0x5A: // 'Z'
            guard let t = demangleAssociatedTypeCompound(getDependentGenericParamType(depth: 0, index: 0)) else { return nil }
            addSubstitution(t)
            return t
        case 0x70: // 'p'
            let countTy = popTypeAndGetChild()
            let patternTy = popTypeAndGetChild()
            return createType(createWithChildren(.PackExpansion, patternTy, countTy))
        case 0x65: // 'e'
            let packTy = popTypeAndGetChild()
            let level = demangleIndex()
            if level < 0 { return nil }
            return createType(createWithChildren(.PackElement, packTy,
                                                 nb.make(kind: .PackElementLevel, index: UInt64(level))))
        case 0x50: return popPack() // 'P'
        case 0x53: return popSILPack() // 'S'
        default: return nil
        }
    }

    mutating func demangleAssociatedTypeSimple(_ base: B.Node?) -> B.Node? {
        let atName = popAssocTypeName()
        let baseTy: B.Node? = if let base { createType(base) } else { popNode(.`Type`) }
        return createType(createWithChildren(.DependentMemberType, baseTy, atName))
    }

    mutating func demangleAssociatedTypeCompound(_ base: B.Node?) -> B.Node? {
        var assocTyNames: [B.Node] = []
        var firstElem = false
        repeat {
            firstElem = popNode(.FirstElementMarker) != nil
            guard let assocTyName = popAssocTypeName() else { return nil }
            assocTyNames.append(assocTyName)
        } while !firstElem

        var baseTy: B.Node? = if let base {
            createType(base)
        } else { popNode(.`Type`) }
        while let assocTy = assocTyNames.popLast() {
            var depTy = nb.make(kind: .DependentMemberType)
            depTy = addChild(depTy, baseTy) ?? depTy
            guard let combined = addChild(depTy, assocTy) else { return nil }
            baseTy = createType(combined)
        }
        return baseTy
    }

    mutating func popAssocTypeName() -> B.Node? {
        var proto = popNode(.`Type`)
        if let p = proto, !DemanglerPredicates.isProtocolNode(p, nb) { return nil }
        if proto == nil { proto = popNode(.ProtocolSymbolicReference) }
        if proto == nil { proto = popNode(.ObjectiveCProtocolSymbolicReference) }
        let id = popNode(.Identifier)
        var assocTy = createWithChild(.DependentAssociatedTypeRef, id)
        if let proto { assocTy = addChild(assocTy, proto) }
        return assocTy
    }

    mutating func popAssocTypePath() -> B.Node? {
        var assocTypePath = nb.make(kind: .AssocTypePath)
        var firstElem = false
        repeat {
            firstElem = popNode(.FirstElementMarker) != nil
            guard let assocTy = popAssocTypeName() else { return nil }
            nb.appendChild(to: &assocTypePath, assocTy)
        } while !firstElem
        nb.reverseChildren(of: &assocTypePath)
        return assocTypePath
    }

    // MARK: Special types

    mutating func demangleSpecialType() -> B.Node? {
        let specialChar = nextChar()
        switch specialChar {
        case 0x45: return popFunctionType(.NoEscapeFunctionType) // 'E'
        case 0x41: return popFunctionType(.EscapingAutoClosureType) // 'A'
        case 0x66: return popFunctionType(.ThinFunctionType) // 'f'
        case 0x4B: return popFunctionType(.AutoClosureType) // 'K'
        case 0x55: return popFunctionType(.UncurriedFunctionType) // 'U'
        case 0x4C: return popFunctionType(.EscapingObjCBlock) // 'L'
        case 0x42: return popFunctionType(.ObjCBlock) // 'B'
        case 0x43: return popFunctionType(.CFunctionPointer) // 'C'
        case 0x67, 0x47: return demangleExtendedExistentialShape(specialChar) // 'g','G'
        case 0x6A: return demangleSymbolicExtendedExistentialType() // 'j'
        case 0x7A: // 'z'
            switch nextChar() {
            case 0x42: return popFunctionType(.ObjCBlock, hasClangType: true)
            case 0x43: return popFunctionType(.CFunctionPointer, hasClangType: true)
            default: return nil
            }
        case 0x6F: return createType(createWithChild(.Unowned, popNode(.`Type`))) // 'o'
        case 0x75: return createType(createWithChild(.Unmanaged, popNode(.`Type`))) // 'u'
        case 0x77: return createType(createWithChild(.Weak, popNode(.`Type`))) // 'w'
        case 0x62: return createType(createWithChild(.SILBoxType, popNode(.`Type`))) // 'b'
        case 0x44: return createType(createWithChild(.DynamicSelf, popNode(.`Type`))) // 'D'
        case 0x4D: // 'M'
            let mtr = demangleMetatypeRepresentation()
            let type = popNode(.`Type`)
            return createType(createWithChildren(.Metatype, mtr, type))
        case 0x6D: // 'm'
            let mtr = demangleMetatypeRepresentation()
            let type = popNode(.`Type`)
            return createType(createWithChildren(.ExistentialMetatype, mtr, type))
        case 0x50: // 'P'
            let reqs = demangleConstrainedExistentialRequirementList()
            let base = popNode(.`Type`)
            return createType(createWithChildren(.ConstrainedExistential, base, reqs))
        case 0x70: return createType(createWithChild(.ExistentialMetatype, popNode(.`Type`))) // 'p'
        case 0x63: // 'c'
            let superclass = popNode(.`Type`)
            let protocols = demangleProtocolList()
            return createType(createWithChildren(.ProtocolListWithClass, protocols, superclass))
        case 0x6C: // 'l'
            let protocols = demangleProtocolList()
            return createType(createWithChild(.ProtocolListWithAnyObject, protocols))
        case 0x58, 0x78: return demangleSILBoxType(specialChar) // 'X','x'
        case 0x59: return demangleAnyGenericType(.OtherNominalType) // 'Y'
        case 0x5A: // 'Z'
            let types = popTypeList()
            let name = popNode(.Identifier)
            let parent = popContext()
            // Faithful to apple/swift Demangler.cpp 'Z': `addChild` is
            // null-propagating (returns nil if either operand is nil) and the
            // case does NOT fall back to the partial node — a missing
            // name/parent/types makes the whole AnonymousContext nil, a clean
            // decline. The prior `?? anon` fallbacks resurrected the parent and
            // yielded an under-populated node that trapped NodePrinter's
            // `children[1]` read on malformed inputs like `$sXZ` (SIGTRAP;
            // apple declines the same input). Chaining preserves the
            // [name, parent, types] child order.
            let anon = nb.make(kind: .AnonymousContext)
            return addChild(addChild(addChild(anon, name), parent), types)
        case 0x65: return createType(nb.make(kind: .ErrorType)) // 'e'
        case 0x53: return demangleSugaredType() // 'S'
        default: return nil
        }
    }

    private mutating func demangleSILBoxType(_ specialChar: UInt8) -> B.Node? {
        var signature: B.Node?
        var genericArgs: B.Node?
        if specialChar == 0x58 { // 'X'
            signature = popNode(.DependentGenericSignature)
            if signature == nil { return nil }
            genericArgs = popTypeList()
            if genericArgs == nil { return nil }
        }
        guard let fieldTypes = popTypeList() else { return nil }
        var layout = nb.make(kind: .SILBoxLayout)
        for k in 0 ..< nb.childCount(of: fieldTypes) {
            var fieldType = nb.child(of: fieldTypes, at: k)
            guard nb.kind(of: fieldType) == .`Type` else { return nil }
            var isMutable = false
            if let first = nb.firstChild(of: fieldType), nb.kind(of: first) == .InOut {
                isMutable = true
                guard let inner = nb.firstChild(of: first) else { return nil }
                fieldType = createType(inner) ?? fieldType
            }
            var field = nb.make(kind: isMutable ? .SILBoxMutableField : .SILBoxImmutableField)
            nb.appendChild(to: &field, fieldType)
            nb.appendChild(to: &layout, field)
        }
        var boxTy = nb.make(kind: .SILBoxTypeWithLayout, child: layout)
        if let signature, let genericArgs {
            nb.appendChild(to: &boxTy, signature)
            nb.appendChild(to: &boxTy, genericArgs)
        }
        return createType(boxTy)
    }

    private mutating func demangleSugaredType() -> B.Node? {
        switch nextChar() {
        case 0x71: return createType(createWithChild(.SugaredOptional, popNode(.`Type`))) // 'q'
        case 0x61: return createType(createWithChild(.SugaredArray, popNode(.`Type`))) // 'a'
        case 0x41: // 'A'
            let element = popNode(.`Type`)
            let count = popNode(.`Type`)
            return createType(createWithChildren(.SugaredInlineArray, count, element))
        case 0x44: // 'D'
            let value = popNode(.`Type`)
            let key = popNode(.`Type`)
            return createType(createWithChildren(.SugaredDictionary, key, value))
        case 0x70: return createType(createWithChild(.SugaredParen, popNode(.`Type`))) // 'p'
        default: return nil
        }
    }
}
