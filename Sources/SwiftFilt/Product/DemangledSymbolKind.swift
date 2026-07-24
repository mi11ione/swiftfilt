// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The curated kind taxonomy over the demangling tree: what a symbol IS,
// without node-tree spelunking. Buckets are chosen for the two consumers
// that need them — crash-frame grouping and symbol/binary-size analytics —
// not for grammar completeness; the full grammar stays available on
// ``SwiftSymbol``.

public extension DemangledSymbol {
    /// What a demangled symbol is, in the vocabulary users of symbols think
    /// in (a method, a getter, a witness, a metadata record, …) rather than
    /// the raw grammar vocabulary of ``SwiftSymbol/Kind``.
    ///
    /// The classification looks at the symbol's *primary* node — the entity
    /// under the mangling's global root, after global attributes such as
    /// specialization markers are set aside (those surface as
    /// ``DemangledSymbol/isSpecialized`` and ``DemangledSymbol/isThunk``,
    /// not as kinds). A specialized `@objc` method therefore still
    /// classifies as ``function``.
    ///
    /// New cases can appear as the Swift grammar grows (the same policy as
    /// ``SwiftSymbol/Kind``): switch with a `default:` unless you intend to
    /// opt into a source break on library updates.
    enum Kind: Sendable, Hashable {
        /// A function or method, including operators — the mangling's
        /// `Function` entity.
        case function
        /// An initializer: the allocating entry (`__allocating_init`), the
        /// initializing entry (`init`), or an Objective-C `__ivar_initializer`.
        case initializer
        /// A deinitializer: `deinit`, the deallocating entry
        /// (`__deallocating_deinit`), an isolated deinit, or an Objective-C
        /// `__ivar_destroyer`.
        case deinitializer
        /// A property or subscript accessor; the payload says which one.
        case accessor(AccessorKind)
        /// A variable reference itself (global-variable storage, a property
        /// mentioned by a descriptor, …) — not one of its accessors.
        case variable
        /// A subscript declaration reference — not one of its accessors.
        case subscriptDeclaration
        /// An explicit (`{ … }`) or implicit (compiler-generated) closure;
        /// ``DemangledSymbol/path`` names the declaration it is nested in.
        case closure
        /// Code (or its once-token) that computes a stored declaration's
        /// initial value: a variable initialization expression, a property
        /// wrapper's backing/projected-value initializer, or a global
        /// variable's one-time initialization function/token.
        case variableInitializer
        /// A default-argument generator (`default argument N of f`).
        case defaultArgument
        /// The symbol denotes a type — nominal, bound generic, tuple,
        /// function type, existential, sugared, builtin, or any other type
        /// mangling — rather than code or a runtime record. The `_Tt…`
        /// type names Objective-C metadata carries classify here.
        case type
        /// An enum case record (`WC`) — the per-case tag record the runtime
        /// uses for one case of one enum.
        case enumCase
        /// The symbol denotes a protocol.
        case protocolDeclaration
        /// A protocol witness: the per-conformance entry the runtime
        /// dispatches to for one requirement of one conformance.
        case protocolWitness
        /// A compiler-generated forwarding function; the payload says which
        /// flavor. (Global thunk *attributes* — `@objc` bridging, distributed,
        /// back-deployment — keep their entity's kind and surface through
        /// ``DemangledSymbol/isThunk`` instead.)
        case thunk(ThunkKind)
        /// Compiler-outlined helper code or data (outlined copy/destroy/…
        /// value-witness calls, outlined read-only objects).
        case outlined
        /// A macro declaration or a macro-expansion artifact
        /// (`@__swiftmacro_…` unique names and expansion contexts).
        case macro
        /// A runtime metadata record; the payload says which family.
        case metadata(MetadataKind)
        /// Anything the curated taxonomy does not bucket (rare grammar
        /// corners, degenerate-but-parseable names). The full
        /// ``DemangledSymbol/symbol`` tree remains available.
        case other
    }

    /// Which accessor a ``Kind/accessor(_:)`` symbol is. Cases map one to
    /// one onto the mangling grammar's accessor entities, current and
    /// legacy.
    enum AccessorKind: Sendable, Hashable, CaseIterable {
        /// `get`.
        case getter
        /// `set`.
        case setter
        /// `willSet` observer.
        case willSet
        /// `didSet` observer.
        case didSet
        /// `_read` coroutine accessor.
        case read
        /// `read` yield-once-2 coroutine accessor.
        case yieldingBorrow
        /// `_modify` coroutine accessor.
        case modify
        /// `modify` yield-once-2 coroutine accessor.
        case yieldingMutate
        /// `borrow` accessor.
        case borrow
        /// `mutate` accessor.
        case mutate
        /// `unsafeAddress` addressor.
        case unsafeAddressor
        /// `unsafeMutableAddress` addressor.
        case unsafeMutableAddressor
        /// Legacy owning addressor.
        case owningAddressor
        /// Legacy owning mutable addressor.
        case owningMutableAddressor
        /// Legacy native-owning addressor.
        case nativeOwningAddressor
        /// Legacy native-owning mutable addressor.
        case nativeOwningMutableAddressor
        /// Legacy native-pinning addressor.
        case nativePinningAddressor
        /// Legacy native-pinning mutable addressor.
        case nativePinningMutableAddressor
        /// `init` accessor (init-from-initializer properties).
        case initAccessor
        /// Legacy global getter.
        case globalGetter
        /// Legacy `materializeForSet` (Swift ≤4 writeback).
        case materializeForSet
    }

    /// Which forwarding-function flavor a ``Kind/thunk(_:)`` symbol is.
    enum ThunkKind: Sendable, Hashable {
        /// Reabstraction thunk (`TR`/`Tr` and helper variants): converts
        /// between abstraction patterns of one function type. Its target is
        /// not recoverable from the mangling — only the signatures are.
        case reabstraction
        /// Curry thunk (partially-applied method reference).
        case curry
        /// Dispatch thunk (`Tj`): the resilient entry point that performs
        /// virtual/witness dispatch to a declaration.
        case dispatch
        /// Key-path getter/setter/equals/hash/method thunk helpers.
        case keyPath
        /// Partial-apply forwarder (`TA`/`Ta`): forwards a context capture
        /// to its target, typically a closure.
        case partialApply
        /// Vtable thunk: dispatches a base-class vtable slot to a derived
        /// implementation.
        case vtable
        /// Objective-C async completion-handler implementation shims.
        case objCAsyncCompletion
        /// SIL identity thunk.
        case identity
        /// Differentiation (autodiff) thunks.
        case autoDiff
    }

    /// Which runtime-record family a ``Kind/metadata(_:)`` symbol belongs
    /// to — the buckets binary-size and metadata analytics group by.
    enum MetadataKind: Sendable, Hashable {
        /// Type metadata and its machinery: metadata records, full
        /// metadata, metaclasses, access functions, caches, instantiation /
        /// completion functions, generic metadata patterns, class stubs and
        /// base offsets, field offsets, method lookup functions,
        /// extended-existential shapes.
        case typeMetadata
        /// Context descriptors for types and their members: nominal type /
        /// module / extension / anonymous descriptors, method and property
        /// descriptors, opaque-type descriptors and their accessors.
        case typeDescriptor
        /// Protocol-side descriptors: protocol descriptors, requirements
        /// base descriptors, associated-type and associated-conformance
        /// descriptors and their default accessors.
        case protocolDescriptor
        /// Conformance machinery: protocol conformance descriptors, witness
        /// tables and their patterns/accessors/caches, associated-type
        /// witness accessors, self-conformance records.
        case conformance
        /// Value witnesses and value witness tables.
        case valueWitness
        /// Reflection metadata descriptors (field, builtin, associated
        /// type, superclass).
        case reflection
    }
}

// MARK: - Canonical spellings

public extension DemangledSymbol.Kind {
    /// The stable base name — the `kind` field of `swiftfilt --json`
    /// records (`"function"`, `"accessor"`, `"metadata"`, …). Payload
    /// detail is not included; ``description`` carries the qualified form.
    var name: String {
        switch self {
        case .function: "function"
        case .initializer: "initializer"
        case .deinitializer: "deinitializer"
        case .accessor: "accessor"
        case .variable: "variable"
        case .subscriptDeclaration: "subscriptDeclaration"
        case .closure: "closure"
        case .variableInitializer: "variableInitializer"
        case .defaultArgument: "defaultArgument"
        case .type: "type"
        case .enumCase: "enumCase"
        case .protocolDeclaration: "protocolDeclaration"
        case .protocolWitness: "protocolWitness"
        case .thunk: "thunk"
        case .outlined: "outlined"
        case .macro: "macro"
        case .metadata: "metadata"
        case .other: "other"
        }
    }
}

extension DemangledSymbol.Kind: CustomStringConvertible {
    /// The qualified table spelling `swiftfilt census` groups by:
    /// payload kinds qualify (`accessor.getter`, `thunk.curry`,
    /// `metadata.typeMetadata`), the rest are their ``name`` — so
    /// interpolating a kind into a report prints the census vocabulary,
    /// not the enum's structural form.
    public var description: String {
        switch self {
        case let .accessor(accessor): "accessor." + accessor.name
        case let .thunk(thunk): "thunk." + thunk.name
        case let .metadata(metadata): "metadata." + metadata.name
        default: name
        }
    }
}

public extension DemangledSymbol.AccessorKind {
    /// The stable spelling — the `accessor` field of `swiftfilt --json`
    /// records (the case name).
    var name: String {
        switch self {
        case .getter: "getter"
        case .setter: "setter"
        case .willSet: "willSet"
        case .didSet: "didSet"
        case .read: "read"
        case .yieldingBorrow: "yieldingBorrow"
        case .modify: "modify"
        case .yieldingMutate: "yieldingMutate"
        case .borrow: "borrow"
        case .mutate: "mutate"
        case .unsafeAddressor: "unsafeAddressor"
        case .unsafeMutableAddressor: "unsafeMutableAddressor"
        case .owningAddressor: "owningAddressor"
        case .owningMutableAddressor: "owningMutableAddressor"
        case .nativeOwningAddressor: "nativeOwningAddressor"
        case .nativeOwningMutableAddressor: "nativeOwningMutableAddressor"
        case .nativePinningAddressor: "nativePinningAddressor"
        case .nativePinningMutableAddressor: "nativePinningMutableAddressor"
        case .initAccessor: "initAccessor"
        case .globalGetter: "globalGetter"
        case .materializeForSet: "materializeForSet"
        }
    }
}

extension DemangledSymbol.AccessorKind: CustomStringConvertible {
    public var description: String {
        name
    }
}

public extension DemangledSymbol.ThunkKind {
    /// The stable spelling — the `thunk` field of `swiftfilt --json`
    /// records (the case name).
    var name: String {
        switch self {
        case .reabstraction: "reabstraction"
        case .curry: "curry"
        case .dispatch: "dispatch"
        case .keyPath: "keyPath"
        case .partialApply: "partialApply"
        case .vtable: "vtable"
        case .objCAsyncCompletion: "objCAsyncCompletion"
        case .identity: "identity"
        case .autoDiff: "autoDiff"
        }
    }
}

extension DemangledSymbol.ThunkKind: CustomStringConvertible {
    public var description: String {
        name
    }
}

public extension DemangledSymbol.MetadataKind {
    /// The stable spelling — the `metadata` field of `swiftfilt --json`
    /// records (the case name).
    var name: String {
        switch self {
        case .typeMetadata: "typeMetadata"
        case .typeDescriptor: "typeDescriptor"
        case .protocolDescriptor: "protocolDescriptor"
        case .conformance: "conformance"
        case .valueWitness: "valueWitness"
        case .reflection: "reflection"
        }
    }
}

extension DemangledSymbol.MetadataKind: CustomStringConvertible {
    public var description: String {
        name
    }
}

/// Tree-walking classification shared by ``DemangledSymbol``'s curated
/// fields. Internal: the public surface is the fields themselves.
enum SymbolClassification {
    /// The primary node of a `Global`-rooted tree: the last non-`Suffix`
    /// child — the demangler appends global function attributes first, the
    /// entity (or its partial-apply forwarder parent) after them, and an
    /// optional suffix last. Total by construction: `demangle(symbol:)`
    /// yields only `Global` roots with at least one non-`Suffix` child
    /// (both grammars fail the parse otherwise), so the walk always finds
    /// one; the root seed answers for any out-of-domain tree, and every
    /// walker classifies it to its documented fallback.
    static func primary(of root: SwiftSymbol) -> SwiftSymbol {
        var last = root
        for child in root.children where child.kind != .Suffix {
            last = child
        }
        return last
    }

    /// The `Global`-level attribute nodes (specialization markers, `@objc`
    /// bridging markers, merged/outlined/async-partial markers, …) —
    /// every function-attribute child except the primary node itself.
    static func globalAttributes(of root: SwiftSymbol) -> [SwiftSymbol] {
        guard root.kind == .Global, root.children.count > 1 else { return [] }
        let primaryNode = primary(of: root)
        return root.children.dropLast(root.children.last?.kind == .Suffix ? 1 : 0)
            .filter { DemanglerPredicates.isFunctionAttr($0.kind) && $0 != primaryNode }
    }

    /// The specialization attribute kinds — a symbol carrying one is a
    /// compiler-generated instantiation of a generic origin.
    static let specializationKinds: Set<SwiftSymbol.Kind> = [
        .GenericSpecialization, .GenericSpecializationNotReAbstracted,
        .GenericSpecializationInResilienceDomain, .GenericSpecializationPrespecialized,
        .GenericPartialSpecialization, .GenericPartialSpecializationNotReAbstracted,
        .InlinedGenericFunction, .FunctionSignatureSpecialization,
    ]

    /// The curated kind for a primary node. The `Static` wrapper recurses
    /// (staticness is a separate field); a `Type`/`TypeMangling` shell
    /// recurses and falls back to ``DemangledSymbol/Kind/type`` — whatever
    /// sits inside a type mangling denotes a type.
    static func kind(of node: SwiftSymbol) -> DemangledSymbol.Kind {
        switch node.kind {
        case .Static:
            // Wrappers always carry their wrapped node (`createWithChild`
            // fails the parse otherwise); the assign-shape stays total for
            // constructed degenerates without a dead unreachable arm.
            var inner = DemangledSymbol.Kind.other
            if let wrapped = node.firstChild { inner = kind(of: wrapped) }
            return inner
        case .`Type`, .TypeMangling:
            var innerKind = DemangledSymbol.Kind.other
            if let wrapped = node.firstChild { innerKind = kind(of: wrapped) }
            return innerKind == .other ? .type : innerKind
        case .Function, .AutoDiffFunction:
            return .function
        case .Allocator, .Constructor, .IVarInitializer:
            return .initializer
        case .Destructor, .Deallocator, .IsolatedDeallocator, .IVarDestroyer:
            return .deinitializer
        case .Variable:
            return .variable
        case .Subscript:
            return .subscriptDeclaration
        case .ExplicitClosure, .ImplicitClosure:
            return .closure
        case .Initializer, .PropertyWrapperBackingInitializer,
             .PropertyWrapperInitFromProjectedValue, .PropertyWrappedFieldInitAccessor,
             .GlobalVariableOnceFunction, .GlobalVariableOnceToken:
            return .variableInitializer
        case .DefaultArgumentInitializer:
            return .defaultArgument
        case .Getter: return .accessor(.getter)
        case .Setter: return .accessor(.setter)
        case .WillSet: return .accessor(.willSet)
        case .DidSet: return .accessor(.didSet)
        case .ReadAccessor: return .accessor(.read)
        case .YieldingBorrowAccessor: return .accessor(.yieldingBorrow)
        case .ModifyAccessor: return .accessor(.modify)
        case .YieldingMutateAccessor: return .accessor(.yieldingMutate)
        case .BorrowAccessor: return .accessor(.borrow)
        case .MutateAccessor: return .accessor(.mutate)
        case .UnsafeAddressor: return .accessor(.unsafeAddressor)
        case .UnsafeMutableAddressor: return .accessor(.unsafeMutableAddressor)
        case .OwningAddressor: return .accessor(.owningAddressor)
        case .OwningMutableAddressor: return .accessor(.owningMutableAddressor)
        case .NativeOwningAddressor: return .accessor(.nativeOwningAddressor)
        case .NativeOwningMutableAddressor: return .accessor(.nativeOwningMutableAddressor)
        case .NativePinningAddressor: return .accessor(.nativePinningAddressor)
        case .NativePinningMutableAddressor: return .accessor(.nativePinningMutableAddressor)
        case .InitAccessor: return .accessor(.initAccessor)
        case .GlobalGetter: return .accessor(.globalGetter)
        case .MaterializeForSet: return .accessor(.materializeForSet)
        case .Class, .Structure, .Enum, .TypeAlias, .OtherNominalType, .BuiltinTypeName,
             .BoundGenericClass, .BoundGenericStructure, .BoundGenericEnum,
             .BoundGenericOtherNominalType, .BoundGenericTypeAlias, .BoundGenericFunction,
             .TypeSymbolicReference, .DynamicSelf, .Metatype, .ExistentialMetatype,
             .MetatypeRepresentation, .FunctionType, .UncurriedFunctionType,
             .NoEscapeFunctionType, .AutoClosureType, .EscapingAutoClosureType,
             .ThinFunctionType, .CFunctionPointer, .ObjCBlock, .EscapingObjCBlock,
             .ImplFunctionType, .Tuple, .SugaredOptional, .SugaredArray, .SugaredInlineArray,
             .SugaredDictionary, .SugaredParen, .BuiltinTupleType, .BuiltinFixedArray,
             .BuiltinBorrow, .Weak, .Unowned, .Unmanaged, .Shared, .Owned, .InOut, .Isolated,
             .Sending, .NoDerivative, .SILBoxType, .SILBoxTypeWithLayout, .ProtocolList,
             .ProtocolListWithClass, .ProtocolListWithAnyObject, .ConstrainedExistential,
             .SymbolicExtendedExistentialType, .DependentGenericType, .DependentMemberType,
             .DependentGenericParamType, .Pack, .SILPackDirect, .SILPackIndirect,
             .PackExpansion, .PackElement, .OpaqueType, .OpaqueReturnType, .ErrorType:
            return .type
        case .EnumCase:
            return .enumCase
        case .protocolNode, .ProtocolSymbolicReference, .ObjectiveCProtocolSymbolicReference,
             .BoundGenericProtocol:
            return .protocolDeclaration
        case .ProtocolWitness, .ProtocolSelfConformanceWitness:
            return .protocolWitness
        case .ReabstractionThunk, .ReabstractionThunkHelper,
             .ReabstractionThunkHelperWithSelf, .ReabstractionThunkHelperWithGlobalActor:
            return .thunk(.reabstraction)
        case .CurryThunk: return .thunk(.curry)
        case .DispatchThunk: return .thunk(.dispatch)
        case .KeyPathGetterThunkHelper, .KeyPathSetterThunkHelper,
             .KeyPathUnappliedMethodThunkHelper, .KeyPathAppliedMethodThunkHelper,
             .KeyPathEqualsThunkHelper, .KeyPathHashThunkHelper:
            return .thunk(.keyPath)
        case .PartialApplyForwarder, .PartialApplyObjCForwarder:
            return .thunk(.partialApply)
        case .VTableThunk: return .thunk(.vtable)
        case .ObjCAsyncCompletionHandlerImpl, .CheckedObjCAsyncCompletionHandlerImpl,
             .PredefinedObjCAsyncCompletionHandlerImpl:
            return .thunk(.objCAsyncCompletion)
        case .SILThunkIdentity: return .thunk(.identity)
        case .AutoDiffSelfReorderingReabstractionThunk, .AutoDiffSubsetParametersThunk,
             .AutoDiffDerivativeVTableThunk:
            return .thunk(.autoDiff)
        case .OutlinedCopy, .OutlinedConsume, .OutlinedRetain, .OutlinedRelease,
             .OutlinedInitializeWithTake, .OutlinedInitializeWithCopy,
             .OutlinedAssignWithTake, .OutlinedAssignWithCopy, .OutlinedDestroy,
             .OutlinedInitializeWithTakeNoValueWitness, .OutlinedInitializeWithCopyNoValueWitness,
             .OutlinedAssignWithTakeNoValueWitness, .OutlinedAssignWithCopyNoValueWitness,
             .OutlinedDestroyNoValueWitness, .OutlinedEnumTagStore, .OutlinedEnumGetTag,
             .OutlinedEnumProjectDataForLoad, .OutlinedVariable, .OutlinedReadOnlyObject,
             .OutlinedBridgedMethod:
            return .outlined
        case .Macro, .FreestandingMacroExpansion, .AccessorAttachedMacroExpansion,
             .BodyAttachedMacroExpansion, .ConformanceAttachedMacroExpansion,
             .ExtensionAttachedMacroExpansion, .MemberAttachedMacroExpansion,
             .MemberAttributeAttachedMacroExpansion, .PeerAttachedMacroExpansion,
             .PreambleAttachedMacroExpansion, .MacroExpansionUniqueName, .MacroExpansionLoc:
            return .macro
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
             .CanonicalPrespecializedGenericTypeCachingOnceToken, .FieldOffset,
             .MethodLookupFunction, .ExtendedExistentialTypeShape:
            return .metadata(.typeMetadata)
        case .NominalTypeDescriptor, .NominalTypeDescriptorRecord, .ModuleDescriptor,
             .ExtensionDescriptor, .AnonymousDescriptor, .MethodDescriptor, .PropertyDescriptor,
             .OpaqueTypeDescriptor, .OpaqueTypeDescriptorRecord, .OpaqueTypeDescriptorAccessor,
             .OpaqueTypeDescriptorAccessorImpl, .OpaqueTypeDescriptorAccessorKey,
             .OpaqueTypeDescriptorAccessorVar:
            return .metadata(.typeDescriptor)
        case .ProtocolDescriptor, .ProtocolDescriptorRecord, .ProtocolRequirementsBaseDescriptor,
             .AssociatedTypeDescriptor, .AssociatedConformanceDescriptor,
             .BaseConformanceDescriptor, .DefaultAssociatedTypeMetadataAccessor,
             .DefaultAssociatedConformanceAccessor:
            return .metadata(.protocolDescriptor)
        case .ProtocolConformance, .ProtocolConformanceDescriptor,
             .ProtocolConformanceDescriptorRecord, .ProtocolWitnessTable,
             .ProtocolWitnessTablePattern, .ProtocolWitnessTableAccessor,
             .LazyProtocolWitnessTableAccessor, .LazyProtocolWitnessTableCacheVariable,
             .GenericProtocolWitnessTable, .GenericProtocolWitnessTableInstantiationFunction,
             .ResilientProtocolWitnessTable, .AssociatedTypeMetadataAccessor,
             .AssociatedTypeWitnessTableAccessor, .BaseWitnessTableAccessor,
             .ProtocolSelfConformanceDescriptor, .ProtocolSelfConformanceWitnessTable:
            return .metadata(.conformance)
        case .ValueWitness, .ValueWitnessTable:
            return .metadata(.valueWitness)
        case .ReflectionMetadataBuiltinDescriptor, .ReflectionMetadataFieldDescriptor,
             .ReflectionMetadataAssocTypeDescriptor, .ReflectionMetadataSuperclassDescriptor:
            return .metadata(.reflection)
        default:
            return .other
        }
    }

    /// Whether the primary node is wrapped in `Static` (at any of the
    /// wrapper layers the classifier itself unwraps).
    static func isStatic(_ node: SwiftSymbol) -> Bool {
        if node.kind == .Static { return true }
        if node.kind == .`Type` || node.kind == .TypeMangling,
           let inner = node.firstChild { return isStatic(inner) }
        return false
    }
}
