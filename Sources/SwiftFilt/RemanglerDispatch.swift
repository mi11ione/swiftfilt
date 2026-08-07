// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The `Remangler` per-kind dispatch — the inverse of the demangler's operator
// switch, ported from `lib/Demangling/Remangler.cpp`. Each case emits its
// children then its operator (some reversed, some substitution-bearing).

extension Remangler {
    /// Per-kind re-mangle dispatch: emit each node's children then its operator
    /// (some reversed, some substitution-bearing). The deepest corpus symbols
    /// nest ~130 levels, which a caller must give adequate stack to remangle
    /// (deep-tree callers run this on a large-stack worker); there is no depth
    /// cap because the tree is finite (bounded by the mangled name's length).
    @_optimize(speed)
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func mangleNode(_ node: SwiftSymbol, depth: Int) -> Bool {
        let d = depth + 1
        switch node.kind {
        // Structural roots
        case .Global: return mangleGlobal(node, depth: depth)
        case .`Type`: return mangleSingleChildNode(node, depth: d)
        case .TypeMangling: return mangleChildNodes(node, depth: d) && emitOp("D")
        case .DeclContext: return mangleSingleChildNode(node, depth: d)
        case .Suffix: emitDynamic(node.text ?? ""); return true
        // Identifiers / modules / operators
        case .Identifier: mangleIdentifierImpl(node, isOperator: false); return true
        case .InfixOperator: mangleIdentifierImpl(node, isOperator: true); return emitOp("oi")
        case .PrefixOperator: mangleIdentifierImpl(node, isOperator: true); return emitOp("op")
        case .PostfixOperator: mangleIdentifierImpl(node, isOperator: true); return emitOp("oP")
        case .Module: return mangleModule(node, depth: d)
        case .PrivateDeclName:
            return mangleChildNodesReversed(node, depth: d) && emitOp(node.children.count == 1 ? "Ll" : "LL")
        case .LocalDeclName:
            return mangleChildNode(node, 1, depth: d) && emitOp("L") && mangleChildNode(node, 0, depth: d)
        case .RelatedEntityDeclName:
            guard mangleChildNode(node, 1, depth: d), let kindText = node.firstChild?.text, kindText.count == 1 else { return false }
            emit("L"); emitDynamic(kindText); return true
        // Nominal types
        case .Structure, .Class, .Enum, .protocolNode, .TypeAlias, .OtherNominalType:
            return mangleAnyNominalType(node, depth: d)
        case .BoundGenericClass, .BoundGenericStructure, .BoundGenericProtocol,
             .BoundGenericOtherNominalType, .BoundGenericTypeAlias:
            return mangleAnyNominalType(node, depth: d)
        case .BoundGenericEnum: return mangleBoundGenericEnum(node, depth: d)
        case .BoundGenericFunction: return mangleBoundGenericFunction(node, depth: d)
        // Entities
        case .Function: return mangleFunction(node, depth: d)
        case .Constructor: return mangleAnyConstructor(node, 0x63, depth: d) // 'c'
        case .Allocator: return mangleAnyConstructor(node, 0x43, depth: d) // 'C'
        case .Destructor: return mangleChildNodes(node, depth: d) && emitOp("fd")
        case .Deallocator: return mangleChildNodes(node, depth: d) && emitOp("fD")
        case .IsolatedDeallocator: return mangleChildNodes(node, depth: d) && emitOp("fZ")
        case .IVarInitializer: return mangleSingleChildNode(node, depth: d) && emitOp("fe")
        case .IVarDestroyer: return mangleSingleChildNode(node, depth: d) && emitOp("fE")
        case .DefaultArgumentInitializer:
            return mangleChildNode(node, 0, depth: d) && emitOp("fA") && mangleChildNode(node, 1, depth: d)
        case .Initializer: return mangleEntityOp(node, "fi", depth: d)
        case .PropertyWrapperBackingInitializer: return mangleEntityOp(node, "fP", depth: d)
        case .PropertyWrappedFieldInitAccessor: return mangleEntityOp(node, "fF", depth: d)
        case .PropertyWrapperInitFromProjectedValue: return mangleEntityOp(node, "fW", depth: d)
        case .Static: return mangleSingleChildNode(node, depth: d) && emitOp("Z")
        case .GenericTypeParamDecl: return mangleChildNodes(node, depth: d) && emitOp("fp")
        case .Macro: return mangleChildNodes(node, depth: d) && emitOp("fm")
        case .ExplicitClosure: return mangleClosure(node, "U", depth: d)
        case .ImplicitClosure: return mangleClosure(node, "u", depth: d)
        case .Variable: return mangleAbstractStorage(node, "p", depth: d)
        case .Subscript: return mangleAbstractStorage(node, "p", depth: d)
        // Accessors (wrap a Variable/Subscript)
        case .Getter: return accessor(node, "g", depth: d)
        case .Setter: return accessor(node, "s", depth: d)
        case .MaterializeForSet: return accessor(node, "m", depth: d)
        case .GlobalGetter: return accessor(node, "G", depth: d)
        case .WillSet: return accessor(node, "w", depth: d)
        case .DidSet: return accessor(node, "W", depth: d)
        case .ReadAccessor: return accessor(node, "r", depth: d)
        case .YieldingBorrowAccessor: return accessor(node, "y", depth: d)
        case .ModifyAccessor: return accessor(node, "M", depth: d)
        case .YieldingMutateAccessor: return accessor(node, "x", depth: d)
        case .InitAccessor: return accessor(node, "i", depth: d)
        case .BorrowAccessor: return accessor(node, "b", depth: d)
        case .MutateAccessor: return accessor(node, "z", depth: d)
        case .OwningMutableAddressor: return accessor(node, "aO", depth: d)
        case .NativeOwningMutableAddressor: return accessor(node, "ao", depth: d)
        case .NativePinningMutableAddressor: return accessor(node, "aP", depth: d)
        case .UnsafeMutableAddressor: return accessor(node, "au", depth: d)
        case .OwningAddressor: return accessor(node, "lO", depth: d)
        case .NativeOwningAddressor: return accessor(node, "lo", depth: d)
        case .NativePinningAddressor: return accessor(node, "lp", depth: d)
        case .UnsafeAddressor: return accessor(node, "lu", depth: d)
        // Extension / contexts
        case .Extension:
            guard mangleChildNode(node, 1, depth: d), mangleChildNode(node, 0, depth: d) else { return false }
            if node.children.count == 3, !mangleChildNode(node, 2, depth: d) { return false }
            return emitOp("E")
        case .AnonymousContext:
            guard mangleChildNode(node, 1, depth: d), mangleChildNode(node, 0, depth: d) else { return false }
            if node.children.count >= 3 { guard mangleNode(node.children[2], depth: d) else { return false } } else { emit("y") }
            return emitOp("XZ")
        // Function types
        case .FunctionType: return mangleFunctionSignature(node, depth: d) && emitOp("c")
        case .NoEscapeFunctionType: return mangleChildNodesReversed(node, depth: d) && emitOp("XE")
        case .AutoClosureType: return mangleChildNodesReversed(node, depth: d) && emitOp("XK")
        case .EscapingAutoClosureType: return mangleChildNodesReversed(node, depth: d) && emitOp("XA")
        case .ThinFunctionType: return mangleFunctionSignature(node, depth: d) && emitOp("Xf")
        case .UncurriedFunctionType: return mangleChildNodesReversed(node, depth: d) && emitOp("c")
        case .CFunctionPointer: return mangleCFunctionPointer(node, "XC", depth: d)
        case .ObjCBlock: return mangleCFunctionPointer(node, "XB", depth: d)
        case .EscapingObjCBlock: return mangleChildNodesReversed(node, depth: d) && emitOp("XL")
        // Function-signature pieces
        case .ArgumentTuple: return mangleArgumentTuple(node, depth: d)
        case .ReturnType: return mangleArgumentTuple(node, depth: d)
        case .Tuple: return mangleTypeList(node, depth: d) && emitOp("t")
        case .TupleElement: return mangleChildNodesReversed(node, depth: d)
        case .TupleElementName: mangleIdentifierImpl(node, isOperator: false); return true
        case .TypeList: return mangleTypeList(node, depth: d)
        case .LabelList:
            if node.children.isEmpty { emit("y"); return true }
            return mangleChildNodes(node, depth: d)
        case .EmptyList: emit("y"); return true
        case .FirstElementMarker: emit("_"); return true
        case .VariadicMarker: return emitOp("d")
        case .Number: mangleIndex(node.index ?? 0); return true
        case .Directness: emit(UInt8(node.index == 0 ? 0x64 : 0x69)); return true // 'd'/'i'
        // Annotations
        case .AsyncAnnotation: return emitOp("Ya")
        case .ThrowsAnnotation: return emitOp("K")
        case .TypedThrowsAnnotation: return mangleSingleChildNode(node, depth: d) && emitOp("YK")
        case .ConcurrentFunctionType: return emitOp("Yb")
        case .GlobalActorFunctionType: return mangleSingleChildNode(node, depth: d) && emitOp("Yc")
        case .IsolatedAnyFunctionType: return emitOp("YA")
        case .NonIsolatedCallerFunctionType: return emitOp("YC")
        case .SendingResultFunctionType: return emitOp("YT")
        case .DifferentiableFunctionType:
            emit("Yj"); emit(UInt8(node.index ?? 0)); return true
        // Modifiers (wrap a single Type child)
        case .InOut: return mangleSingleChildNode(node, depth: d) && emitOp("z")
        case .Shared: return mangleSingleChildNode(node, depth: d) && emitOp("h")
        case .Owned: return mangleSingleChildNode(node, depth: d) && emitOp("n")
        case .Isolated: return mangleSingleChildNode(node, depth: d) && emitOp("Yi")
        case .Sending: return mangleSingleChildNode(node, depth: d) && emitOp("Yu")
        case .NoDerivative: return mangleSingleChildNode(node, depth: d) && emitOp("Yk")
        case .CompileTimeLiteral: return mangleSingleChildNode(node, depth: d) && emitOp("Yt")
        case .ConstValue: return mangleSingleChildNode(node, depth: d) && emitOp("Yg")
        case .Weak: return mangleSingleChildNode(node, depth: d) && emitOp("Xw")
        case .Unowned: return mangleSingleChildNode(node, depth: d) && emitOp("Xo")
        case .Unmanaged: return mangleSingleChildNode(node, depth: d) && emitOp("Xu")
        // Metatypes / existentials
        case .Metatype: return mangleMetatype(node, depth: d)
        case .ExistentialMetatype: return mangleExistentialMetatype(node, depth: d)
        case .MetatypeRepresentation: return mangleMetatypeRepresentation(node)
        case .DynamicSelf: return mangleSingleChildNode(node, depth: d) && emitOp("XD")
        case .ProtocolList: return mangleProtocolList(node, superclass: nil, anyObject: false, depth: d)
        case .ProtocolListWithClass: return mangleProtocolListWithClass(node, depth: d)
        case .ProtocolListWithAnyObject: return mangleProtocolListWithAnyObject(node, depth: d)
        // Generics
        case .DependentGenericType: return mangleChildNodesReversed(node, depth: d) && emitOp("u")
        case .DependentGenericSignature: return mangleDependentGenericSignature(node, depth: d)
        case .DependentGenericParamType: return mangleDependentGenericParamType(node)
        case .DependentMemberType: return mangleDependentMemberType(node, depth: d)
        case .DependentAssociatedTypeRef: return mangleDependentAssociatedTypeRef(node, depth: d)
        case .AssociatedTypeRef:
            if trySubstitution(node) { return true }
            guard mangleChildNodes(node, depth: d) else { return false }
            emit("Qa"); addSubstitution(node); return true
        case .DependentGenericConformanceRequirement: return mangleConformanceRequirement(node, depth: d)
        case .DependentGenericSameTypeRequirement: return mangleSameTypeRequirement(node, "RS", "Rs", "Rt", "RT", depth: d)
        case .DependentGenericSameShapeRequirement: return mangleSameShapeRequirement(node, depth: d)
        case .DependentGenericLayoutRequirement: return mangleLayoutRequirement(node, depth: d)
        case .DependentGenericParamPackMarker:
            guard let t = node.firstChild, t.kind == .`Type`, let inner = t.firstChild else { return false }
            emit("Rv"); mangleDependentGenericParamIndex(inner); return true
        // Builtins
        case .BuiltinTypeName: return mangleBuiltinTypeName(node)
        case .BuiltinTupleType: return emitOp("BT")
        case .BuiltinFixedArray: return mangleChildNodes(node, depth: d) && emitOp("BV")
        case .BuiltinBorrow: return mangleChildNodes(node, depth: d) && emitOp("BW")
        // Sugared (debug) types
        case .SugaredOptional: return mangleSingleChildNode(node, depth: d) && emitOp("XSq")
        case .SugaredArray: return mangleSingleChildNode(node, depth: d) && emitOp("XSa")
        case .SugaredDictionary: return mangleChildNodes(node, depth: d) && emitOp("XSD")
        case .SugaredParen: return mangleSingleChildNode(node, depth: d) && emitOp("XSp")
        case .ErrorType: return emitOp("Xe")
        // Metadata accessors / descriptors
        case .TypeMetadata: return mangleSingleChildNode(node, depth: d) && emitOp("N")
        case .TypeMetadataAccessFunction: return mangleSingleChildNode(node, depth: d) && emitOp("Ma")
        case .NominalTypeDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("Mn")
        case .ProtocolDescriptor: return manglePureProtocol(node.firstChild ?? node, depth: d) && emitOp("Mp")
        case .FullTypeMetadata: return mangleSingleChildNode(node, depth: d) && emitOp("Mf")
        case .Metaclass: return mangleChildNodes(node, depth: d) && emitOp("Mm")
        case .ClassMetadataBaseOffset: return mangleSingleChildNode(node, depth: d) && emitOp("Mo")
        case .PropertyDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("MV")
        case .GenericTypeMetadataPattern: return mangleSingleChildNode(node, depth: d) && emitOp("MP")
        // Witnesses
        case .ValueWitness: return mangleValueWitness(node, depth: d)
        case .ValueWitnessTable: return mangleSingleChildNode(node, depth: d) && emitOp("WV")
        case .ProtocolWitnessTable: return mangleSingleChildNode(node, depth: d) && emitOp("WP")
        case .ProtocolWitnessTableAccessor: return mangleSingleChildNode(node, depth: d) && emitOp("Wa")
        case .ProtocolWitness:
            return mangleChildNodes(node, depth: d) && emitOp("TW")
        case .FieldOffset:
            return mangleChildNode(node, 1, depth: d) && emitOp("Wv") && mangleChildNode(node, 0, depth: d)
        case .EnumCase: return mangleSingleChildNode(node, depth: d) && emitOp("WC")
        case .GlobalVariableOnceToken: return mangleChildNodes(node, depth: d) && emitOp("Wz")
        case .GlobalVariableOnceFunction: return mangleChildNodes(node, depth: d) && emitOp("WZ")
        case .GlobalVariableOnceDeclList:
            for child in node.children {
                guard mangle(child, depth: d) else { return false }; emit("_")
            }
            return true
        // Conformances
        case .ProtocolConformance: return mangleProtocolConformance(node, depth: d)
        case .ProtocolConformanceRefInTypeModule: return manglePureProtocol(node.firstChild ?? node, depth: d) && emitOp("HP")
        case .ProtocolConformanceRefInProtocolModule: return manglePureProtocol(node.firstChild ?? node, depth: d) && emitOp("Hp")
        case .ProtocolConformanceRefInOtherModule:
            return manglePureProtocol(node.firstChild ?? node, depth: d) && mangleChildNode(node, 1, depth: d)
        case .RetroactiveConformance:
            guard node.children.count > 1, mangleAnyProtocolConformance(node.children[1], depth: d) else { return false }
            emit("g"); mangleIndex(node.children[0].index ?? 0); return true
        case .ConcreteProtocolConformance: return mangleConcreteProtocolConformance(node, depth: d)
        case .AnyProtocolConformanceList: return mangleAnyProtocolConformanceList(node, depth: d)
        // Metadata accessors / caches / descriptors (single Type/child + op)
        case .TypeMetadataDemanglingCache: return mangleSingleChildNode(node, depth: d) && emitOp("Md")
        case .TypeMetadataMangledNameRef: return mangleSingleChildNode(node, depth: d) && emitOp("MR")
        case .TypeMetadataInstantiationFunction: return mangleSingleChildNode(node, depth: d) && emitOp("Mi")
        case .TypeMetadataInstantiationCache: return mangleSingleChildNode(node, depth: d) && emitOp("MI")
        case .TypeMetadataSingletonInitializationCache: return mangleSingleChildNode(node, depth: d) && emitOp("Ml")
        case .TypeMetadataCompletionFunction: return mangleSingleChildNode(node, depth: d) && emitOp("Mr")
        case .TypeMetadataLazyCache: return mangleSingleChildNode(node, depth: d) && emitOp("ML")
        case .MetadataInstantiationCache: return mangleSingleChildNode(node, depth: d) && emitOp("MK")
        case .CanonicalSpecializedGenericTypeMetadataAccessFunction: return mangleSingleChildNode(node, depth: d) && emitOp("Mb")
        case .CanonicalSpecializedGenericMetaclass: return mangleSingleChildNode(node, depth: d) && emitOp("MM")
        case .NoncanonicalSpecializedGenericTypeMetadata: return mangleSingleChildNode(node, depth: d) && emitOp("MN")
        case .NoncanonicalSpecializedGenericTypeMetadataCache: return mangleSingleChildNode(node, depth: d) && emitOp("MJ")
        case .CanonicalPrespecializedGenericTypeCachingOnceToken: return mangleSingleChildNode(node, depth: d) && emitOp("Mz")
        case .ObjCMetadataUpdateFunction: return mangleSingleChildNode(node, depth: d) && emitOp("MU")
        case .ObjCResilientClassStub: return mangleSingleChildNode(node, depth: d) && emitOp("Ms")
        case .FullObjCResilientClassStub: return mangleSingleChildNode(node, depth: d) && emitOp("Mt")
        case .MethodLookupFunction: return mangleSingleChildNode(node, depth: d) && emitOp("Mu")
        case .NominalTypeDescriptorRecord: return mangleSingleChildNode(node, depth: d) && emitOp("Hn")
        case .OpaqueTypeDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("MQ")
        case .OpaqueTypeDescriptorRecord: return mangleSingleChildNode(node, depth: d) && emitOp("Ho")
        case .OpaqueTypeDescriptorAccessor: return mangleSingleChildNode(node, depth: d) && emitOp("Mg")
        case .OpaqueTypeDescriptorAccessorImpl: return mangleSingleChildNode(node, depth: d) && emitOp("Mh")
        case .OpaqueTypeDescriptorAccessorKey: return mangleSingleChildNode(node, depth: d) && emitOp("Mj")
        case .OpaqueTypeDescriptorAccessorVar: return mangleSingleChildNode(node, depth: d) && emitOp("Mk")
        case .ReflectionMetadataBuiltinDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("MB")
        case .ReflectionMetadataFieldDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("MF")
        case .ReflectionMetadataAssocTypeDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("MA")
        case .ReflectionMetadataSuperclassDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("MC")
        case .ProtocolConformanceDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("Mc")
        case .ProtocolConformanceDescriptorRecord: return mangleSingleChildNode(node, depth: d) && emitOp("Hc")
        case .ProtocolDescriptorRecord: return manglePureProtocol(node.firstChild ?? node, depth: d) && emitOp("Hr")
        case .ProtocolSelfConformanceDescriptor: return manglePureProtocol(node.firstChild ?? node, depth: d) && emitOp("MS")
        case .ProtocolRequirementsBaseDescriptor: return manglePureProtocol(node.firstChild ?? node, depth: d) && emitOp("TL")
        case .Uniquable: return mangleSingleChildNode(node, depth: d) && emitOp("Mq")
        case .AccessibleFunctionRecord: return emitOp("HF")
        // Witness tables
        case .ProtocolWitnessTablePattern: return mangleSingleChildNode(node, depth: d) && emitOp("Wp")
        case .GenericProtocolWitnessTable: return mangleSingleChildNode(node, depth: d) && emitOp("WG")
        case .GenericProtocolWitnessTableInstantiationFunction: return mangleSingleChildNode(node, depth: d) && emitOp("WI")
        case .ResilientProtocolWitnessTable: return mangleSingleChildNode(node, depth: d) && emitOp("Wr")
        case .LazyProtocolWitnessTableAccessor: return mangleChildNodes(node, depth: d) && emitOp("Wl")
        case .LazyProtocolWitnessTableCacheVariable: return mangleChildNodes(node, depth: d) && emitOp("WL")
        case .AssociatedTypeMetadataAccessor: return mangleChildNodes(node, depth: d) && emitOp("Wt")
        case .AssociatedTypeWitnessTableAccessor: return mangleChildNodes(node, depth: d) && emitOp("WT")
        case .BaseWitnessTableAccessor: return mangleChildNodes(node, depth: d) && emitOp("Wb")
        case .ProtocolSelfConformanceWitness: return mangleSingleChildNode(node, depth: d) && emitOp("TS")
        case .ProtocolSelfConformanceWitnessTable: return manglePureProtocol(node.firstChild ?? node, depth: d) && emitOp("WS")
        case .AssociatedTypeDescriptor: return mangleChildNodes(node, depth: d) && emitOp("Tl")
        // Opaque types
        case .OpaqueReturnTypeOf: return mangleSingleChildNode(node, depth: d) && emitOp("QO")
        case .OpaqueReturnType: return mangleOpaqueReturnType(node, depth: d)
        case .OpaqueReturnTypeIndex: mangleIndex(node.index ?? 0); return true
        case .OpaqueReturnTypeParent: return true
        case .OpaqueType: return mangleOpaqueType(node, depth: d)
        // Module / context descriptors
        case .ModuleDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("MXM")
        case .ExtensionDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("MXE")
        case .AnonymousDescriptor:
            return mangleChildNodes(node, depth: d) && emitOp(node.children.count == 1 ? "MXX" : "MXY")
        case .AssociatedTypeGenericParamRef: return mangleChildNodes(node, depth: d) && emitOp("MXA")
        // Packs / SIL packs / pack elements
        case .Pack: return mangleTypeList(node, depth: d) && emitOp("QP")
        case .SILPackDirect: return mangleTypeList(node, depth: d) && emitOp("QSd")
        case .SILPackIndirect: return mangleTypeList(node, depth: d) && emitOp("QSi")
        case .PackExpansion: return mangleChildNodes(node, depth: d) && emitOp("Qp")
        case .PackElement:
            return mangleChildNode(node, 0, depth: d) && emitOp("Qe") && mangleChildNode(node, 1, depth: d)
        case .PackElementLevel: mangleIndex(node.index ?? 0); return true
        // Constrained existentials / inverse requirements
        case .ConstrainedExistential:
            return mangleChildNode(node, 0, depth: d) && mangleChildNode(node, 1, depth: d) && emitOp("XP")
        case .ConstrainedExistentialRequirementList:
            var first = true
            for req in node.children {
                guard mangle(req, depth: d) else { return false }
                mangleListSeparator(&first)
            }
            mangleEndOfList(first)
            return true
        case .DependentGenericInverseConformanceRequirement: return mangleInverseRequirement(node, depth: d)
        // Reabstraction / keypath thunk helpers
        case .ReabstractionThunkHelperWithSelf: return mangleChildNodesReversed(node, depth: d) && emitOp("Ty")
        case .ReabstractionThunkHelperWithGlobalActor:
            return mangleChildNodes(node, depth: d) && emitOp("TU")
        // Thunks / specializations
        case .CurryThunk: return mangleSingleChildNode(node, depth: d) && emitOp("Tc")
        case .DispatchThunk: return mangleSingleChildNode(node, depth: d) && emitOp("Tj")
        case .MethodDescriptor: return mangleSingleChildNode(node, depth: d) && emitOp("Tq")
        case .ObjCAttribute: return emitOp("To")
        case .NonObjCAttribute: return emitOp("TO")
        case .DynamicAttribute: return emitOp("TD")
        case .DirectMethodReferenceAttribute: return emitOp("Td")
        case .MergedFunction: return emitOp("Tm")
        case .DistributedThunk: return emitOp("TE")
        case .DistributedAccessor: return emitOp("TF")
        case .DynamicallyReplaceableFunctionImpl: return emitOp("TI")
        case .DynamicallyReplaceableFunctionKey: return emitOp("Tx")
        case .DynamicallyReplaceableFunctionVar: return emitOp("TX")
        case .AsyncFunctionPointer: return emitOp("Tu")
        case .CoroFunctionPointer: return emitOp("Twc")
        case .DefaultOverride: return emitOp("Twd")
        case .BackDeploymentThunk: return emitOp("Twb")
        case .BackDeploymentFallback: return emitOp("TwB")
        case .HasSymbolQuery: return emitOp("TwS")
        case .PartialApplyForwarder: return mangleChildNodesReversed(node, depth: d) && emitOp("TA")
        case .PartialApplyObjCForwarder: return mangleChildNodesReversed(node, depth: d) && emitOp("Ta")
        case .ReabstractionThunk: return mangleChildNodesReversed(node, depth: d) && emitOp("Tr")
        case .ReabstractionThunkHelper: return mangleChildNodesReversed(node, depth: d) && emitOp("TR")
        case .FunctionSignatureSpecialization: return mangleFunctionSignatureSpecialization(node, depth: d)
        case .GenericSpecialization: return mangleGenericSpecializationNode(node, "g", depth: d)
        case .GenericSpecializationNotReAbstracted: return mangleGenericSpecializationNode(node, "G", depth: d)
        case .GenericSpecializationInResilienceDomain: return mangleGenericSpecializationNode(node, "B", depth: d)
        case .GenericSpecializationPrespecialized: return mangleGenericSpecializationNode(node, "s", depth: d)
        case .InlinedGenericFunction: return mangleGenericSpecializationNode(node, "i", depth: d)
        case .SpecializationPassID: emitDynamic(String(node.index ?? 0)); return true
        case .IsSerialized: return emitOp("q")
        case .AsyncRemoved: return emitOp("a")
        case .RepresentationChanged: return emitOp("r")
        // SIL impl-function types (the Impl* pieces are consumed by this helper)
        case .ImplFunctionType: return mangleImplFunctionType(node, depth: d)
        // Autodiff
        case .AutoDiffFunction: return mangleAutoDiffFunctionOrSimpleThunk(node, "TJ", depth: d)
        case .AutoDiffDerivativeVTableThunk: return mangleAutoDiffFunctionOrSimpleThunk(node, "TJV", depth: d)
        case .AutoDiffSubsetParametersThunk: return mangleAutoDiffSubsetParametersThunk(node, depth: d)
        case .AutoDiffSelfReorderingReabstractionThunk: return mangleAutoDiffSelfReorderingReabstractionThunk(node, depth: d)
        case .AutoDiffFunctionKind: emit(UInt8(node.index ?? 0)); return true
        case .DifferentiabilityWitness: return mangleDifferentiabilityWitness(node, depth: d)
        case .IndexSubset: emitDynamic(node.text ?? ""); return true
        // Key-path thunk helpers
        case .KeyPathGetterThunkHelper: return mangleKeyPathThunkHelper(node, "TK", depth: d)
        case .KeyPathSetterThunkHelper: return mangleKeyPathThunkHelper(node, "Tk", depth: d)
        case .KeyPathUnappliedMethodThunkHelper: return mangleKeyPathThunkHelper(node, "Tkmu", depth: d)
        case .KeyPathAppliedMethodThunkHelper: return mangleKeyPathThunkHelper(node, "TkMA", depth: d)
        case .KeyPathEqualsThunkHelper: return mangleKeyPathThunkHelper(node, "TH", depth: d)
        case .KeyPathHashThunkHelper: return mangleKeyPathThunkHelper(node, "Th", depth: d)
        // Macro expansions
        case .AccessorAttachedMacroExpansion: return mangleAttachedMacro(node, "a", depth: d)
        case .MemberAttributeAttachedMacroExpansion: return mangleAttachedMacro(node, "r", depth: d)
        case .MemberAttachedMacroExpansion: return mangleAttachedMacro(node, "m", depth: d)
        case .PeerAttachedMacroExpansion: return mangleAttachedMacro(node, "p", depth: d)
        case .ConformanceAttachedMacroExpansion: return mangleAttachedMacro(node, "c", depth: d)
        case .ExtensionAttachedMacroExpansion: return mangleAttachedMacro(node, "e", depth: d)
        case .BodyAttachedMacroExpansion: return mangleAttachedMacro(node, "b", depth: d)
        case .FreestandingMacroExpansion: return mangleFreestandingMacroExpansion(node, depth: d)
        case .MacroExpansionUniqueName: return mangleMacroExpansionUniqueName(node, depth: d)
        case .MacroExpansionLoc: return mangleMacroExpansionLoc(node, depth: d)
        // ObjC async completion handler impls / async resume partials
        case .ObjCAsyncCompletionHandlerImpl: return mangleObjCAsyncCompletionHandlerImpl(node, "Tz", depth: d)
        case .CheckedObjCAsyncCompletionHandlerImpl: return mangleObjCAsyncCompletionHandlerImpl(node, "TZ", depth: d)
        case .PredefinedObjCAsyncCompletionHandlerImpl: return mangleObjCAsyncCompletionHandlerImpl(node, "TZ", depth: d)
        case .AsyncAwaitResumePartialFunction: emit("TQ"); return mangleChildNode(node, 0, depth: d)
        case .AsyncSuspendResumePartialFunction: emit("TY"); return mangleChildNode(node, 0, depth: d)
        case .CoroutineContinuationPrototype: return mangleChildNodes(node, depth: d) && emitOp("TC")
        // Dependent protocol conformances
        case .DependentProtocolConformanceRoot: return mangleDependentProtocolConformanceRoot(node, depth: d)
        case .DependentProtocolConformanceInherited: return mangleDependentProtocolConformanceInherited(node, depth: d)
        case .DependentProtocolConformanceAssociated: return mangleDependentProtocolConformanceAssociated(node, depth: d)
        case .DependentProtocolConformanceOpaque: return mangleDependentProtocolConformanceOpaque(node, depth: d)
        case .DependentAssociatedConformance: return mangleDependentAssociatedConformance(node, depth: d)
        case .PackProtocolConformance: return manglePackProtocolConformance(node, depth: d)
        // Conformance descriptors / accessors
        case .AssociatedConformanceDescriptor: return mangleAssociatedConformanceDescriptor(node, depth: d)
        case .DefaultAssociatedConformanceAccessor: return mangleDefaultAssociatedConformanceAccessor(node, depth: d)
        case .BaseConformanceDescriptor: return mangleBaseConformanceDescriptor(node, depth: d)
        case .DefaultAssociatedTypeMetadataAccessor: return mangleChildNodes(node, depth: d) && emitOp("TM")
        case .AssocTypePath:
            var first = true
            for child in node.children {
                guard mangle(child, depth: d) else { return false }; mangleListSeparator(&first)
            }
            return true
        case .DependentGenericParamValueMarker:
            guard node.children.count >= 2, node.children[1].kind == .`Type`, mangle(node.children[1], depth: d),
                  let g = node.firstChild?.firstChild else { return false }
            emit("RV"); mangleDependentGenericParamIndex(g); return true
        // SIL box types / existential shapes / partial specializations
        case .SILBoxTypeWithLayout: return mangleSILBoxTypeWithLayout(node, depth: d)
        case .ExtendedExistentialTypeShape: return mangleExtendedExistentialTypeShape(node, depth: d)
        case .SymbolicExtendedExistentialType: return mangleSymbolicExtendedExistentialType(node, depth: d)
        case .GenericPartialSpecialization: return mangleGenericPartialSpecialization(node, "Tp", depth: d)
        case .GenericPartialSpecializationNotReAbstracted: return mangleGenericPartialSpecialization(node, "TP", depth: d)
        // Outlined value-witness family
        case .OutlinedCopy: return mangleChildNodes(node, depth: d) && emitOp("WOy")
        case .OutlinedConsume: return mangleChildNodes(node, depth: d) && emitOp("WOe")
        case .OutlinedRetain: return mangleChildNodes(node, depth: d) && emitOp("WOr")
        case .OutlinedRelease: return mangleChildNodes(node, depth: d) && emitOp("WOs")
        case .OutlinedInitializeWithTake: return mangleChildNodes(node, depth: d) && emitOp("WOb")
        case .OutlinedInitializeWithCopy: return mangleChildNodes(node, depth: d) && emitOp("WOc")
        case .OutlinedAssignWithTake: return mangleChildNodes(node, depth: d) && emitOp("WOd")
        case .OutlinedAssignWithCopy: return mangleChildNodes(node, depth: d) && emitOp("WOf")
        case .OutlinedDestroy: return mangleChildNodes(node, depth: d) && emitOp("WOh")
        case .OutlinedEnumGetTag: return mangleChildNodes(node, depth: d) && emitOp("WOg")
        case .OutlinedInitializeWithTakeNoValueWitness: return mangleChildNodes(node, depth: d) && emitOp("WOB")
        case .OutlinedInitializeWithCopyNoValueWitness: return mangleChildNodes(node, depth: d) && emitOp("WOC")
        case .OutlinedAssignWithTakeNoValueWitness: return mangleChildNodes(node, depth: d) && emitOp("WOD")
        case .OutlinedAssignWithCopyNoValueWitness: return mangleChildNodes(node, depth: d) && emitOp("WOF")
        case .OutlinedDestroyNoValueWitness: return mangleChildNodes(node, depth: d) && emitOp("WOH")
        case .OutlinedEnumTagStore: return mangleOutlinedEnum(node, "WOi", depth: d)
        case .OutlinedEnumProjectDataForLoad: return mangleOutlinedEnum(node, "WOj", depth: d)
        case .OutlinedVariable: emit("Tv"); mangleIndex(node.index ?? 0); return true
        case .OutlinedReadOnlyObject: emit("Tv"); mangleIndex(node.index ?? 0); emit("r"); return true
        case .OutlinedBridgedMethod: emit("Te"); emitDynamic(node.text ?? ""); emit("_"); return true
        // Misc
        case .SILThunkIdentity: return mangleSingleChildNode(node, depth: d) && emitOp("TTI")
        case .VTableThunk: return mangleChildNodes(node, depth: d) && emitOp("TV")
        case .Integer: emit("$"); mangleIndex(node.index ?? 0); return true
        case .NegativeInteger: emit("$n"); mangleIndex(UInt64(bitPattern: -Int64(bitPattern: node.index ?? 0))); return true
        case .SugaredInlineArray: return mangleChildNodes(node, depth: d) && emitOp("XSA")
        case .ConstrainedExistentialSelf: emit("s"); return true
        case .DroppedArgument:
            emit("t"); let n = node.index ?? 0; if n > 0 { emitDynamic(String(n - 1)) }; return true
        case .ClangType: return mangleClangType(node)
        case .GenericSpecializationParam, .FunctionSignatureSpecializationParamKind,
             .FunctionSignatureSpecializationParamPayload, .Index, .UnknownIndex,
             .DependentGenericParamCount:
            return false // handled inline by their parents
        default:
            return false
        }
    }

    // MARK: small helpers used by the dispatch

    @discardableResult @inline(__always) func emitOp(_ s: String) -> Bool {
        emitDynamic(s); return true
    }

    private func mangleEntityOp(_ node: SwiftSymbol, _ op: String, depth: Int) -> Bool {
        mangleChildNodes(node, depth: depth) && emitOp(op)
    }

    private func accessor(_ node: SwiftSymbol, _ code: String, depth: Int) -> Bool {
        guard let storage = node.firstChild else { return false }
        return mangleAbstractStorage(storage, code, depth: depth)
    }

    private func mangleClosure(_ node: SwiftSymbol, _ op: String, depth: Int) -> Bool {
        guard mangleChildNode(node, 0, depth: depth), mangleChildNode(node, 2, depth: depth) else { return false }
        emit("f"); emitDynamic(op)
        return mangleChildNode(node, 1, depth: depth) // index
    }

    private func mangleModule(_ node: SwiftSymbol, depth _: Int) -> Bool {
        switch node.text {
        case SwiftManglingConstants.stdlibName: emit("s")
        case SwiftManglingConstants.objCModule: emit("So")
        case SwiftManglingConstants.clangImporterModule: emit("SC")
        default: mangleIdentifierImpl(node, isOperator: false)
        }
        return true
    }

    private func mangleArgumentTuple(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard let child0 = node.firstChild else { return false }
        let child = skipType(child0)
        if child.kind == .Tuple, child.children.isEmpty { emit("y"); return true }
        return mangle(child, depth: depth)
    }

    private func mangleTypeList(_ node: SwiftSymbol, depth: Int) -> Bool {
        var first = true
        for child in node.children {
            guard mangle(child, depth: depth) else { return false }
            mangleListSeparator(&first)
        }
        mangleEndOfList(first)
        return true
    }

    private func mangleCFunctionPointer(_ node: SwiftSymbol, _ op: String, depth: Int) -> Bool {
        if let first = node.firstChild, first.kind == .ClangType {
            for idx in stride(from: node.children.count - 1, through: 1, by: -1) {
                guard mangleChildNode(node, idx, depth: depth) else { return false }
            }
            emit(op == "XC" ? "XzC" : "XzB")
            return mangleClangType(first)
        }
        return mangleChildNodesReversed(node, depth: depth) && emitOp(op)
    }

    func mangleClangType(_ node: SwiftSymbol) -> Bool {
        let text = Array((node.text ?? "").utf8)
        emitDynamic(String(text.count)); emit(text); return true
    }

    private func mangleBoundGenericEnum(_ node: SwiftSymbol, depth: Int) -> Bool {
        if let unbound = node.firstChild, let enumNode = unbound.firstChild, enumNode.kind == .Enum,
           let mod = enumNode.firstChild, mod.kind == .Module, mod.text == SwiftManglingConstants.stdlibName,
           enumNode.children.count > 1, enumNode.children[1].kind == .Identifier,
           enumNode.children[1].text == "Optional"
        {
            if trySubstitution(node) { return true }
            guard node.children.count > 1, mangleSingleChildNode(node.children[1], depth: depth) else { return false }
            emit("Sg"); addSubstitution(node); return true
        }
        return mangleAnyNominalType(node, depth: depth)
    }

    private func mangleBoundGenericFunction(_ node: SwiftSymbol, depth: Int) -> Bool {
        if trySubstitution(node) { return true }
        guard let unbound = getUnspecialized(node), mangleFunction(unbound, depth: depth) else { return false }
        var sep: UInt8 = 0x79 // 'y'
        guard mangleGenericArgs(node, separator: &sep, depth: depth) else { return false }
        emit("G"); addSubstitution(node); return true
    }

    private func mangleMetatype(_ node: SwiftSymbol, depth: Int) -> Bool {
        // Without representation: children = [Type] → 'm'; with: [Repr, Type] → 'XM'.
        if node.firstChild?.kind != .MetatypeRepresentation {
            return mangleSingleChildNode(node, depth: depth) && emitOp("m")
        }
        // With representation: `type 'XM' repr` — the representation follows the
        // `XM` operator, not precedes it.
        guard mangleChildNode(node, 1, depth: depth) else { return false }
        emit("XM")
        return mangleChildNode(node, 0, depth: depth)
    }

    private func mangleExistentialMetatype(_ node: SwiftSymbol, depth: Int) -> Bool {
        if node.firstChild?.kind != .MetatypeRepresentation {
            return mangleSingleChildNode(node, depth: depth) && emitOp("Xp")
        }
        guard mangleChildNode(node, 1, depth: depth) else { return false }
        emit("Xm")
        return mangleChildNode(node, 0, depth: depth)
    }

    private func mangleMetatypeRepresentation(_ node: SwiftSymbol) -> Bool {
        switch node.text {
        case "@thin": emit("t")
        case "@thick": emit("T")
        case "@objc_metatype": emit("o")
        default: return false
        }
        return true
    }

    private func mangleProtocolList(_ node: SwiftSymbol, superclass: SwiftSymbol?, anyObject: Bool, depth: Int) -> Bool {
        guard let typeList = node.firstChild else { return false }
        var first = true
        for proto in typeList.children {
            guard manglePureProtocol(proto, depth: depth) else { return false }
            mangleListSeparator(&first)
        }
        mangleEndOfList(first)
        if let superclass { guard mangle(superclass, depth: depth) else { return false }; emit("Xc"); return true }
        if anyObject { emit("Xl"); return true }
        emit("p"); return true
    }

    private func mangleProtocolListWithClass(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard node.children.count == 2 else { return false }
        return mangleProtocolList(node.children[0], superclass: node.children[1], anyObject: false, depth: depth)
    }

    private func mangleProtocolListWithAnyObject(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard let list = node.firstChild else { return false }
        return mangleProtocolList(list, superclass: nil, anyObject: true, depth: depth)
    }

    private func mangleOpaqueReturnType(_ node: SwiftSymbol, depth _: Int) -> Bool {
        // `Qr` (current decl) or `QR<index>` (subsequent). The OpaqueReturnTypeParent
        // child, when present, is AST-identity only and is not mangled.
        if let indexNode = node.children.first(where: { $0.kind == .OpaqueReturnTypeIndex }) {
            emit("QR"); mangleIndex(indexNode.index ?? 0); return true
        }
        return emitOp("Qr")
    }

    private func mangleOpaqueType(_ node: SwiftSymbol, depth: Int) -> Bool {
        // OpaqueType children: [Name, Index, TypeList(boundGenerics), retroactive?].
        // `OpaqueType` is a substitution candidate — omitting the registration
        // shifts every later back-reference index and corrupts round-trip.
        if trySubstitution(node) { return true }
        guard node.children.count >= 3 else { return false }
        guard mangle(node.children[0], depth: depth + 1) else { return false } // opaque-type-decl-name
        // bound-generic-args: `y` before the first nesting level, `_` between
        // levels, mangling the types *within* each level group.
        let boundGenerics = node.children[2]
        for (i, group) in boundGenerics.children.enumerated() {
            emit(i == 0 ? UInt8(0x79) : UInt8(0x5F)) // 'y' / '_'
            guard mangleChildNodes(group, depth: depth + 1) else { return false }
        }
        if node.children.count >= 4 {
            for child in node.children[3].children where !mangle(child, depth: depth + 1) {
                return false
            }
        }
        emit("Qo"); mangleIndex(node.children[1].index ?? 0)
        addSubstitution(node)
        return true
    }

    private func mangleValueWitness(_ node: SwiftSymbol, depth: Int) -> Bool {
        guard node.children.count == 2, let kindIdx = node.children[0].index,
              let code = ValueWitnessKinds.all[safe: Int(kindIdx)]?.code else { return false }
        guard mangle(node.children[1], depth: depth) else { return false }
        emit("w"); emitDynamic(code); return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
