// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Module / declaration-path extraction from a demangling tree. Best-effort
// by design: where the tree carries no static name (symbolic references,
// signature-only thunks) the walk stops and reports what it has, never
// fabricating a component — the same "silent skip, never silent guess"
// invariant the engine holds.

/// The naming walk behind ``DemangledSymbol/module``,
/// ``DemangledSymbol/path`` and ``DemangledSymbol/name``.
enum SymbolNaming {
    struct Components {
        var module: String?
        var path: [String]

        static let none = Components(module: nil, path: [])
    }

    /// Naming components of a node: the defining module and the
    /// declaration-name path (module names never appear in `path`).
    static func components(of node: SwiftSymbol) -> Components {
        switch node.kind {
        case .Module:
            return Components(module: node.text, path: [])

        // Wrapper shells and named declarations walk their children with
        // assign-shapes: the parser guarantees the children (a shell always
        // wraps, `createWithChildren` fails otherwise), and the `.none`
        // seed keeps the walk total for constructed degenerates without a
        // dead unreachable arm.
        case .`Type`, .TypeMangling, .Static, .DeclContext:
            var result = Components.none
            if let inner = node.firstChild { result = components(of: inner) }
            return result

        // An extension's defining module wins over the extended type's;
        // the extended type contributes its non-module path components.
        case .Extension:
            var inner = Components.none
            if node.children.count >= 2 { inner = components(of: node.children[1]) }
            if let module = node.children.first?.text { inner.module = module }
            return inner

        // Named declarations: context chain, then the declaration name.
        case .Class, .Structure, .Enum, .protocolNode, .OtherNominalType, .TypeAlias,
             .Function, .Variable, .Macro, .GenericTypeParamDecl:
            var result = Components.none
            if let context = node.firstChild { result = components(of: context) }
            if node.children.count >= 2, let name = declarationName(node.children[1]) {
                result.path.append(name)
            }
            return result

        // Unnamed member declarations: the source-level spelling.
        case .Subscript:
            return appending("subscript", toContextOf: node)

        case .Allocator, .Constructor:
            return appending("init", toContextOf: node)

        case .Destructor, .Deallocator, .IsolatedDeallocator:
            return appending("deinit", toContextOf: node)

        case .IVarInitializer:
            return appending("__ivar_initializer", toContextOf: node)

        case .IVarDestroyer:
            return appending("__ivar_destroyer", toContextOf: node)

        // Wrappers that name whatever they contain.
        case .Getter, .Setter, .WillSet, .DidSet, .ReadAccessor, .YieldingBorrowAccessor,
             .ModifyAccessor, .YieldingMutateAccessor, .BorrowAccessor, .MutateAccessor,
             .UnsafeAddressor, .UnsafeMutableAddressor, .OwningAddressor,
             .OwningMutableAddressor, .NativeOwningAddressor, .NativeOwningMutableAddressor,
             .NativePinningAddressor, .NativePinningMutableAddressor, .InitAccessor,
             .GlobalGetter, .MaterializeForSet,
             .ExplicitClosure, .ImplicitClosure,
             .Initializer, .PropertyWrapperBackingInitializer,
             .PropertyWrapperInitFromProjectedValue, .PropertyWrappedFieldInitAccessor,
             .DefaultArgumentInitializer,
             .CurryThunk, .DispatchThunk, .SILThunkIdentity,
             .KeyPathGetterThunkHelper, .KeyPathSetterThunkHelper,
             .KeyPathUnappliedMethodThunkHelper, .KeyPathAppliedMethodThunkHelper,
             .KeyPathEqualsThunkHelper, .KeyPathHashThunkHelper,
             .BoundGenericClass, .BoundGenericStructure, .BoundGenericEnum,
             .BoundGenericProtocol, .BoundGenericOtherNominalType, .BoundGenericTypeAlias,
             .BoundGenericFunction,
             .OutlinedBridgedMethod, .AutoDiffFunction:
            var result = Components.none
            if let inner = node.firstChild { result = components(of: inner) }
            return result

        // Anonymous contexts sit between a parent context and members;
        // they contribute no printable name.
        case .AnonymousContext:
            var result = Components.none
            if node.children.count >= 2 { result = components(of: node.children[1]) }
            return result

        // An associated-type reference: [name, base protocol/type].
        case .DependentAssociatedTypeRef:
            guard node.children.count >= 2 else { return .none }
            var result = components(of: node.children[1])
            if let name = declarationName(node.children[0]) { result.path.append(name) }
            return result

        // The forwarder's entity is its last child (attributes precede it).
        case .PartialApplyForwarder, .PartialApplyObjCForwarder:
            var result = Components.none
            if let inner = node.children.last { result = components(of: inner) }
            return result

        // A witness names the conforming type plus the requirement, in the
        // module the conformance lives in.
        case .ProtocolWitness, .ProtocolSelfConformanceWitness:
            var result = Components.none
            if let conformance = node.firstChild { result = components(of: conformance) }
            if node.children.count >= 2 {
                let requirement = components(of: node.children[1])
                if let requirementName = requirement.path.last {
                    result.path.append(requirementName)
                }
            }
            return result

        // Conformance records name the conforming type; the module is the
        // conformance's own (child 2), falling back to the type's.
        case .ProtocolConformance:
            var result = Components.none
            if let conforming = node.firstChild { result = components(of: conforming) }
            if node.children.count >= 3, node.children[2].kind == .Module {
                result.module = node.children[2].text
            }
            return result

        // Global-variable once entities: [context, decl list].
        case .GlobalVariableOnceFunction, .GlobalVariableOnceToken:
            var result = Components.none
            if let context = node.firstChild { result = components(of: context) }
            if node.children.count >= 2 {
                for decl in node.children[1].children {
                    if let name = declarationName(decl) { result.path.append(name) }
                }
            }
            return result

        // Macro expansions: [context, attached decl names…, macro name,
        // discriminator]. Every named child joins the path, so the final
        // component is the macro name.
        case .FreestandingMacroExpansion, .AccessorAttachedMacroExpansion,
             .BodyAttachedMacroExpansion, .ConformanceAttachedMacroExpansion,
             .ExtensionAttachedMacroExpansion, .MemberAttachedMacroExpansion,
             .MemberAttributeAttachedMacroExpansion, .PeerAttachedMacroExpansion,
             .PreambleAttachedMacroExpansion, .MacroExpansionUniqueName, .MacroExpansionLoc:
            var result = Components.none
            if let context = node.firstChild { result = components(of: context) }
            for child in node.children.dropFirst() {
                if let name = declarationName(child) { result.path.append(name) }
            }
            return result

        // The described entity is the last child; a marker precedes it
        // (field offsets: [directness, variable]; value witnesses:
        // [witness index, type]).
        case .FieldOffset, .ValueWitness:
            var result = Components.none
            if let entity = node.children.last { result = components(of: entity) }
            return result

        // Metadata records name the type or entity they describe.
        case .TypeMetadata, .FullTypeMetadata, .Metaclass, .TypeMetadataAccessFunction,
             .TypeMetadataLazyCache, .TypeMetadataInstantiationCache,
             .TypeMetadataInstantiationFunction, .TypeMetadataSingletonInitializationCache,
             .TypeMetadataCompletionFunction, .TypeMetadataDemanglingCache,
             .TypeMetadataMangledNameRef, .GenericTypeMetadataPattern, .ClassMetadataBaseOffset,
             .ObjCMetadataUpdateFunction, .ObjCResilientClassStub, .FullObjCResilientClassStub,
             .CanonicalSpecializedGenericMetaclass,
             .CanonicalSpecializedGenericTypeMetadataAccessFunction, .MetadataInstantiationCache,
             .NoncanonicalSpecializedGenericTypeMetadata,
             .NoncanonicalSpecializedGenericTypeMetadataCache,
             .CanonicalPrespecializedGenericTypeCachingOnceToken,
             .MethodLookupFunction, .MethodDescriptor,
             .NominalTypeDescriptor, .NominalTypeDescriptorRecord, .ModuleDescriptor,
             .ExtensionDescriptor, .AnonymousDescriptor, .PropertyDescriptor,
             .OpaqueTypeDescriptor, .OpaqueTypeDescriptorRecord, .OpaqueTypeDescriptorAccessor,
             .OpaqueTypeDescriptorAccessorImpl, .OpaqueTypeDescriptorAccessorKey,
             .OpaqueTypeDescriptorAccessorVar, .OpaqueType,
             .ProtocolDescriptor, .ProtocolDescriptorRecord, .ProtocolRequirementsBaseDescriptor,
             .ProtocolConformanceDescriptor, .ProtocolConformanceDescriptorRecord,
             .ProtocolWitnessTable, .ProtocolWitnessTablePattern, .ProtocolWitnessTableAccessor,
             .LazyProtocolWitnessTableAccessor, .LazyProtocolWitnessTableCacheVariable,
             .GenericProtocolWitnessTable, .GenericProtocolWitnessTableInstantiationFunction,
             .ResilientProtocolWitnessTable, .ProtocolSelfConformanceDescriptor,
             .ProtocolSelfConformanceWitnessTable, .ValueWitnessTable,
             .AssociatedTypeMetadataAccessor, .AssociatedTypeWitnessTableAccessor,
             .BaseWitnessTableAccessor, .AssociatedTypeDescriptor,
             .AssociatedConformanceDescriptor, .BaseConformanceDescriptor,
             .DefaultAssociatedTypeMetadataAccessor, .DefaultAssociatedConformanceAccessor,
             .ExtendedExistentialTypeShape, .OpaqueReturnTypeOf, .EnumCase,
             .ReflectionMetadataBuiltinDescriptor, .ReflectionMetadataFieldDescriptor,
             .ReflectionMetadataAssocTypeDescriptor, .ReflectionMetadataSuperclassDescriptor,
             .DynamicallyReplaceableFunctionImpl, .DynamicallyReplaceableFunctionKey,
             .DynamicallyReplaceableFunctionVar,
             .OutlinedCopy, .OutlinedConsume, .OutlinedRetain, .OutlinedRelease,
             .OutlinedInitializeWithTake, .OutlinedInitializeWithCopy,
             .OutlinedAssignWithTake, .OutlinedAssignWithCopy, .OutlinedDestroy,
             .OutlinedInitializeWithTakeNoValueWitness,
             .OutlinedInitializeWithCopyNoValueWitness,
             .OutlinedAssignWithTakeNoValueWitness, .OutlinedAssignWithCopyNoValueWitness,
             .OutlinedDestroyNoValueWitness:
            var result = Components.none
            if let inner = node.firstChild { result = components(of: inner) }
            return result

        default:
            return .none
        }
    }

    /// The printable text of a declaration-name node, or `nil` when the
    /// name is not statically known (bare private discriminators, symbolic
    /// references). Private and local declaration names contribute their
    /// identifier; the discriminator stays out of the path (it remains in
    /// the printed forms and the identity key).
    static func declarationName(_ node: SwiftSymbol) -> String? {
        switch node.kind {
        case .Identifier, .InfixOperator, .PrefixOperator, .PostfixOperator:
            return node.text
        case .LocalDeclName, .PrivateDeclName, .RelatedEntityDeclName:
            guard node.children.count >= 2 else { return nil }
            return declarationName(node.children[1])
        default:
            return nil
        }
    }

    private static func appending(_ name: String, toContextOf node: SwiftSymbol) -> Components {
        var result = Components.none
        if let context = node.firstChild { result = components(of: context) }
        result.path.append(name)
        return result
    }
}
