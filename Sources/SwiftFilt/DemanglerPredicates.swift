// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// Node-kind classification predicates, ported from the anonymous-namespace
/// helpers and `isContext` / `isFunctionAttr` in apple/swift's `Demangler.cpp`.
enum DemanglerPredicates {
    /// The context-capable kinds (`CONTEXT_NODE` in `DemangleNodes.def`) plus
    /// `BuiltinTupleType` — apple/swift's `isContext`.
    static let contextKinds: Set<SwiftSymbol.Kind> = [
        .Allocator,
        .AnonymousContext,
        .Class,
        .Constructor,
        .Deallocator,
        .DefaultArgumentInitializer,
        .Destructor,
        .DidSet,
        .Enum,
        .ExplicitClosure,
        .Extension,
        .Function,
        .Getter,
        .GlobalGetter,
        .IVarInitializer,
        .IVarDestroyer,
        .ImplicitClosure,
        .Initializer,
        .InitAccessor,
        .IsolatedDeallocator,
        .MaterializeForSet,
        .ModifyAccessor,
        .YieldingMutateAccessor,
        .Module,
        .NativeOwningAddressor,
        .NativeOwningMutableAddressor,
        .NativePinningAddressor,
        .NativePinningMutableAddressor,
        .OtherNominalType,
        .OwningAddressor,
        .OwningMutableAddressor,
        .PropertyWrapperBackingInitializer,
        .PropertyWrappedFieldInitAccessor,
        .PropertyWrapperInitFromProjectedValue,
        .protocolNode,
        .ProtocolSymbolicReference,
        .ReadAccessor,
        .YieldingBorrowAccessor,
        .Setter,
        .Static,
        .Structure,
        .Subscript,
        .TypeSymbolicReference,
        .TypeAlias,
        .UnsafeAddressor,
        .UnsafeMutableAddressor,
        .Variable,
        .WillSet,
        .OpaqueReturnTypeOf,
        .AutoDiffFunction,
        .BorrowAccessor,
        .MutateAccessor,
        .BuiltinTupleType,
    ]

    @inline(__always)
    static func isContext(_ kind: SwiftSymbol.Kind) -> Bool {
        contextKinds.contains(kind)
    }

    /// The macro-expansion context kinds (`isMacroExpansionNodeKind` in
    /// apple/swift's `Demangler.cpp`).
    @inline(__always)
    static func isMacroExpansionNodeKind(_ kind: SwiftSymbol.Kind) -> Bool {
        switch kind {
        case .AccessorAttachedMacroExpansion, .MemberAttributeAttachedMacroExpansion,
             .FreestandingMacroExpansion, .MemberAttachedMacroExpansion,
             .PeerAttachedMacroExpansion, .ConformanceAttachedMacroExpansion,
             .ExtensionAttachedMacroExpansion, .MacroExpansionLoc:
            true
        default:
            false
        }
    }

    static func isDeclName(_ kind: SwiftSymbol.Kind) -> Bool {
        switch kind {
        case .Identifier, .LocalDeclName, .PrivateDeclName, .RelatedEntityDeclName,
             .PrefixOperator, .PostfixOperator, .InfixOperator,
             .TypeSymbolicReference, .ProtocolSymbolicReference,
             .ObjectiveCProtocolSymbolicReference:
            true
        default:
            false
        }
    }

    @inline(__always)
    static func isAnyGeneric(_ kind: SwiftSymbol.Kind) -> Bool {
        switch kind {
        case .Structure, .Class, .Enum, .protocolNode, .ProtocolSymbolicReference,
             .ObjectiveCProtocolSymbolicReference, .OtherNominalType, .TypeAlias,
             .TypeSymbolicReference, .BuiltinTupleType:
            true
        default:
            false
        }
    }

    @inline(__always)
    static func isEntity(_ kind: SwiftSymbol.Kind) -> Bool {
        kind == .`Type` || isContext(kind)
    }

    @inline(__always)
    static func isRequirement(_ kind: SwiftSymbol.Kind) -> Bool {
        switch kind {
        case .DependentGenericParamPackMarker, .DependentGenericParamValueMarker,
             .DependentGenericSameTypeRequirement, .DependentGenericSameShapeRequirement,
             .DependentGenericLayoutRequirement, .DependentGenericConformanceRequirement,
             .DependentGenericInverseConformanceRequirement:
            true
        default:
            false
        }
    }

    @inline(__always)
    static func isFunctionAttr(_ kind: SwiftSymbol.Kind) -> Bool {
        switch kind {
        case .FunctionSignatureSpecialization, .GenericSpecialization,
             .GenericSpecializationPrespecialized, .InlinedGenericFunction,
             .GenericSpecializationNotReAbstracted, .GenericPartialSpecialization,
             .GenericPartialSpecializationNotReAbstracted,
             .GenericSpecializationInResilienceDomain, .ObjCAttribute, .NonObjCAttribute,
             .DynamicAttribute, .DirectMethodReferenceAttribute, .VTableAttribute,
             .PartialApplyForwarder, .PartialApplyObjCForwarder, .OutlinedVariable,
             .OutlinedReadOnlyObject, .OutlinedBridgedMethod, .MergedFunction,
             .DistributedThunk, .DistributedAccessor,
             .DynamicallyReplaceableFunctionImpl, .DynamicallyReplaceableFunctionKey,
             .DynamicallyReplaceableFunctionVar, .AsyncFunctionPointer,
             .AsyncAwaitResumePartialFunction, .AsyncSuspendResumePartialFunction,
             .AccessibleFunctionRecord, .BackDeploymentThunk, .BackDeploymentFallback,
             .HasSymbolQuery, .CoroFunctionPointer, .DefaultOverride:
            true
        default:
            false
        }
    }

    /// apple/swift's `nodeConsumesGenericArgs`.
    @inline(__always)
    static func nodeConsumesGenericArgs(_ kind: SwiftSymbol.Kind) -> Bool {
        switch kind {
        case .Variable, .Subscript, .ImplicitClosure, .ExplicitClosure,
             .DefaultArgumentInitializer, .Initializer,
             .PropertyWrapperBackingInitializer, .PropertyWrappedFieldInitAccessor,
             .PropertyWrapperInitFromProjectedValue, .Static:
            false
        default:
            true
        }
    }

    /// Whether a node (possibly wrapped in `Type`) is a protocol — apple/swift's
    /// `isProtocolNode`. Generic over the builder because it reads a node handle;
    /// kind-keyed predicates above need no such parameter.
    static func isProtocolNode<B: NodeBuilder>(_ node: B.Node, _ nb: B) -> Bool {
        switch nb.kind(of: node) {
        case .`Type`:
            guard let first = nb.firstChild(of: node) else { return false }
            return isProtocolNode(first, nb)
        case .protocolNode, .ProtocolSymbolicReference, .ObjectiveCProtocolSymbolicReference:
            return true
        default:
            return false
        }
    }

    /// Whether a node (possibly wrapped in `Type`) is a dependent generic param.
    static func isGenericParamType<B: NodeBuilder>(_ node: B.Node, _ nb: B) -> Bool {
        switch nb.kind(of: node) {
        case .`Type`:
            guard let first = nb.firstChild(of: node) else { return false }
            return isGenericParamType(first, nb)
        case .DependentGenericParamType:
            return true
        default:
            return false
        }
    }
}
