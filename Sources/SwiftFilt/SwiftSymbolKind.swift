// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

public extension SwiftSymbol {
    /// The structural kind of a demangling-tree node, mirroring apple/swift's
    /// `swift::Demangle::Node::Kind` one-for-one (every enumerator of
    /// `include/swift/Demangling/DemangleNodes.def`, in source order, plus the
    /// three `ReferenceStorage.def` entries).
    ///
    /// Cases keep the canonical ABI spelling (PascalCase) rather than Swift's
    /// usual lowerCamel: the demangler, remangler, and printer are faithful
    /// ports of the apple/swift C++ whose `switch`es dispatch on these exact
    /// identifiers, so a 1:1 mapping makes the port verifiable and keeps the
    /// `String` `rawValue` byte-identical to `getNodeKindString`, which is
    /// diffed against `swift-demangle -tree-only`. The one exception
    /// is ``protocolNode``: bare cases named `Type` or `Protocol` clash with
    /// the `T.Type` / `T.Protocol` metatype expressions, so both need escaping.
    /// Backtick-escaped `Type` survives the source formatter, but the formatter
    /// strips the backticks off `Protocol` and breaks the build, so `Protocol`
    /// is renamed to ``protocolNode`` with an explicit `rawValue = "Protocol"`,
    /// keeping the canonical name in the dump.
    @frozen
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case Allocator
        case AnonymousContext
        case AnyProtocolConformanceList
        case ArgumentTuple
        case AssociatedType
        case AssociatedTypeRef
        case AssociatedTypeMetadataAccessor
        case DefaultAssociatedTypeMetadataAccessor
        case AccessorAttachedMacroExpansion
        case AssociatedTypeWitnessTableAccessor
        case BaseWitnessTableAccessor
        case AutoClosureType
        case BodyAttachedMacroExpansion
        case BoundGenericClass
        case BoundGenericEnum
        case BoundGenericStructure
        case BoundGenericProtocol
        case BoundGenericOtherNominalType
        case BoundGenericTypeAlias
        case BoundGenericFunction
        case BuiltinTypeName
        case BuiltinTupleType
        case BuiltinFixedArray
        case BuiltinBorrow
        case CFunctionPointer
        case ClangType
        case Class
        case ClassMetadataBaseOffset
        case ConcreteProtocolConformance
        case PackProtocolConformance
        case ConformanceAttachedMacroExpansion
        case Constructor
        case CoroutineContinuationPrototype
        case Deallocator
        case DeclContext
        case DefaultArgumentInitializer
        case DependentAssociatedConformance
        case DependentAssociatedTypeRef
        case DependentGenericConformanceRequirement
        case DependentGenericParamCount
        case DependentGenericParamType
        case DependentGenericSameTypeRequirement
        case DependentGenericSameShapeRequirement
        case DependentGenericLayoutRequirement
        case DependentGenericParamPackMarker
        case DependentGenericSignature
        case DependentGenericType
        case DependentMemberType
        case DependentPseudogenericSignature
        case DependentProtocolConformanceRoot
        case DependentProtocolConformanceInherited
        case DependentProtocolConformanceAssociated
        case DependentProtocolConformanceOpaque
        case Destructor
        case DidSet
        case Directness
        case DistributedThunk
        case DistributedAccessor
        case DynamicAttribute
        case DirectMethodReferenceAttribute
        case DynamicSelf
        case DynamicallyReplaceableFunctionImpl
        case DynamicallyReplaceableFunctionKey
        case DynamicallyReplaceableFunctionVar
        case Enum
        case EnumCase
        case ErrorType
        case EscapingAutoClosureType
        case NoEscapeFunctionType
        case ConcurrentFunctionType
        case GlobalActorFunctionType
        case DifferentiableFunctionType
        case ExistentialMetatype
        case ExplicitClosure
        case Extension
        case ExtensionAttachedMacroExpansion
        case FieldOffset
        case FreestandingMacroExpansion
        case FullTypeMetadata
        case Function
        case FunctionSignatureSpecialization
        case FunctionSignatureSpecializationParam
        case FunctionSignatureSpecializationReturn
        case FunctionSignatureSpecializationParamKind
        case FunctionSignatureSpecializationParamPayload
        case FunctionType
        case ConstrainedExistential
        case ConstrainedExistentialRequirementList
        case ConstrainedExistentialSelf
        case GenericPartialSpecialization
        case GenericPartialSpecializationNotReAbstracted
        case GenericProtocolWitnessTable
        case GenericProtocolWitnessTableInstantiationFunction
        case ResilientProtocolWitnessTable
        case GenericSpecialization
        case GenericSpecializationNotReAbstracted
        case GenericSpecializationInResilienceDomain
        case GenericSpecializationParam
        case GenericSpecializationPrespecialized
        case InlinedGenericFunction
        case GenericTypeMetadataPattern
        case Getter
        case Global
        case GlobalGetter
        case Identifier
        case Index
        case IVarInitializer
        case IVarDestroyer
        case ImplEscaping
        case ImplConvention
        case ImplDifferentiabilityKind
        case ImplNonisolatedNonsendingIsolation
        case ImplErasedIsolation
        case ImplSendingResult
        case ImplParameterResultDifferentiability
        case ImplParameterSending
        case ImplParameterIsolated
        case ImplParameterImplicitLeading
        case ImplFunctionAttribute
        case ImplFunctionConvention
        case ImplFunctionConventionName
        case ImplFunctionType
        case ImplCoroutineKind
        case ImplInvocationSubstitutions
        case ImplicitClosure
        case ImplParameter
        case ImplPatternSubstitutions
        case ImplResult
        case ImplYield
        case ImplErrorResult
        case InOut
        case InfixOperator
        case Initializer
        case InitAccessor
        case Isolated
        case IsolatedDeallocator
        case Sending
        case IsolatedAnyFunctionType
        case NonIsolatedCallerFunctionType
        case SendingResultFunctionType
        case KeyPathGetterThunkHelper
        case KeyPathSetterThunkHelper
        case KeyPathUnappliedMethodThunkHelper
        case KeyPathAppliedMethodThunkHelper
        case KeyPathEqualsThunkHelper
        case KeyPathHashThunkHelper
        case LazyProtocolWitnessTableAccessor
        case LazyProtocolWitnessTableCacheVariable
        case LocalDeclName
        case Macro
        case MacroExpansionLoc
        case MacroExpansionUniqueName
        case MaterializeForSet
        case MemberAttachedMacroExpansion
        case MemberAttributeAttachedMacroExpansion
        case MergedFunction
        case Metatype
        case MetatypeRepresentation
        case Metaclass
        case MethodLookupFunction
        case ObjCMetadataUpdateFunction
        case ObjCResilientClassStub
        case FullObjCResilientClassStub
        case ModifyAccessor
        case YieldingMutateAccessor
        case Module
        case NativeOwningAddressor
        case NativeOwningMutableAddressor
        case NativePinningAddressor
        case NativePinningMutableAddressor
        case NominalTypeDescriptor
        case NominalTypeDescriptorRecord
        case NonObjCAttribute
        case Number
        case ObjCAsyncCompletionHandlerImpl
        case CheckedObjCAsyncCompletionHandlerImpl
        case PredefinedObjCAsyncCompletionHandlerImpl
        case ObjCAttribute
        case ObjCBlock
        case EscapingObjCBlock
        case OtherNominalType
        case OwningAddressor
        case OwningMutableAddressor
        case PartialApplyForwarder
        case PartialApplyObjCForwarder
        case PeerAttachedMacroExpansion
        case PostfixOperator
        case PreambleAttachedMacroExpansion
        case PrefixOperator
        case PrivateDeclName
        case PropertyDescriptor
        case PropertyWrapperBackingInitializer
        case PropertyWrappedFieldInitAccessor
        case PropertyWrapperInitFromProjectedValue
        case protocolNode = "Protocol" // renamed: `Protocol` is not a legal enum-case identifier
        case ProtocolSymbolicReference
        case ProtocolConformance
        case ProtocolConformanceRefInTypeModule
        case ProtocolConformanceRefInProtocolModule
        case ProtocolConformanceRefInOtherModule
        case ProtocolDescriptor
        case ProtocolDescriptorRecord
        case ProtocolConformanceDescriptor
        case ProtocolConformanceDescriptorRecord
        case ProtocolList
        case ProtocolListWithClass
        case ProtocolListWithAnyObject
        case ProtocolSelfConformanceDescriptor
        case ProtocolSelfConformanceWitness
        case ProtocolSelfConformanceWitnessTable
        case ProtocolWitness
        case ProtocolWitnessTable
        case ProtocolWitnessTableAccessor
        case ProtocolWitnessTablePattern
        case ReabstractionThunk
        case ReabstractionThunkHelper
        case ReabstractionThunkHelperWithSelf
        case ReabstractionThunkHelperWithGlobalActor
        case ReadAccessor
        case YieldingBorrowAccessor
        case RelatedEntityDeclName
        case RetroactiveConformance
        case ReturnType
        case Shared
        case Owned
        case SILBoxType
        case SILBoxTypeWithLayout
        case SILBoxLayout
        case SILBoxMutableField
        case SILBoxImmutableField
        case Setter
        case SpecializationPassID
        case IsSerialized
        case Static
        case Structure
        case Subscript
        case Suffix
        case ThinFunctionType
        case Tuple
        case TupleElement
        case TupleElementName
        case Pack
        case SILPackDirect
        case SILPackIndirect
        case PackExpansion
        case PackElement
        case PackElementLevel
        case `Type`
        case TypeSymbolicReference
        case TypeAlias
        case TypeList
        case TypeMangling
        case TypeMetadata
        case TypeMetadataAccessFunction
        case TypeMetadataCompletionFunction
        case TypeMetadataInstantiationCache
        case TypeMetadataInstantiationFunction
        case TypeMetadataSingletonInitializationCache
        case TypeMetadataDemanglingCache
        case TypeMetadataMangledNameRef
        case TypeMetadataLazyCache
        case UncurriedFunctionType
        case UnknownIndex
        case Weak
        case Unowned
        case Unmanaged
        case UnsafeAddressor
        case UnsafeMutableAddressor
        case ValueWitness
        case ValueWitnessTable
        case Variable
        case VTableThunk
        case VTableAttribute
        case WillSet
        case ReflectionMetadataBuiltinDescriptor
        case ReflectionMetadataFieldDescriptor
        case ReflectionMetadataAssocTypeDescriptor
        case ReflectionMetadataSuperclassDescriptor
        case GenericTypeParamDecl
        case CurryThunk
        case SILThunkIdentity
        case DispatchThunk
        case MethodDescriptor
        case ProtocolRequirementsBaseDescriptor
        case AssociatedConformanceDescriptor
        case DefaultAssociatedConformanceAccessor
        case BaseConformanceDescriptor
        case AssociatedTypeDescriptor
        case AsyncAnnotation
        case ThrowsAnnotation
        case TypedThrowsAnnotation
        case EmptyList
        case FirstElementMarker
        case VariadicMarker
        case OutlinedBridgedMethod
        case OutlinedCopy
        case OutlinedConsume
        case OutlinedRetain
        case OutlinedRelease
        case OutlinedInitializeWithTake
        case OutlinedInitializeWithCopy
        case OutlinedAssignWithTake
        case OutlinedAssignWithCopy
        case OutlinedDestroy
        case OutlinedVariable
        case OutlinedReadOnlyObject
        case AssocTypePath
        case LabelList
        case ModuleDescriptor
        case ExtensionDescriptor
        case AnonymousDescriptor
        case AssociatedTypeGenericParamRef
        case SugaredOptional
        case SugaredArray
        case SugaredDictionary
        case SugaredInlineArray
        case SugaredParen
        // Added in Swift 5.1
        case AccessorFunctionReference
        case OpaqueType
        case OpaqueTypeDescriptorSymbolicReference
        case OpaqueTypeDescriptor
        case OpaqueTypeDescriptorRecord
        case OpaqueTypeDescriptorAccessor
        case OpaqueTypeDescriptorAccessorImpl
        case OpaqueTypeDescriptorAccessorKey
        case OpaqueTypeDescriptorAccessorVar
        case OpaqueReturnType
        case OpaqueReturnTypeOf
        // Added in Swift 5.4
        case CanonicalSpecializedGenericMetaclass
        case CanonicalSpecializedGenericTypeMetadataAccessFunction
        case MetadataInstantiationCache
        case NoncanonicalSpecializedGenericTypeMetadata
        case NoncanonicalSpecializedGenericTypeMetadataCache
        case GlobalVariableOnceFunction
        case GlobalVariableOnceToken
        case GlobalVariableOnceDeclList
        case CanonicalPrespecializedGenericTypeCachingOnceToken
        // Added in Swift 5.5
        case AsyncFunctionPointer
        case AutoDiffFunction
        case AutoDiffFunctionKind
        case AutoDiffSelfReorderingReabstractionThunk
        case AutoDiffSubsetParametersThunk
        case AutoDiffDerivativeVTableThunk
        case DifferentiabilityWitness
        case NoDerivative
        case IndexSubset
        case AsyncAwaitResumePartialFunction
        case AsyncSuspendResumePartialFunction
        // Added in Swift 5.6
        case AccessibleFunctionRecord
        case CompileTimeLiteral
        // Added in Swift 5.7
        case BackDeploymentThunk
        case BackDeploymentFallback
        case ExtendedExistentialTypeShape
        case Uniquable
        case UniqueExtendedExistentialTypeShapeSymbolicReference
        case NonUniqueExtendedExistentialTypeShapeSymbolicReference
        case SymbolicExtendedExistentialType
        // Added in Swift 5.8
        case DroppedArgument
        case HasSymbolQuery
        case OpaqueReturnTypeIndex
        case OpaqueReturnTypeParent
        // Addedn in Swift 6.0
        case OutlinedEnumTagStore
        case OutlinedEnumProjectDataForLoad
        case OutlinedEnumGetTag
        /// Added in Swift 5.9 + 1
        case AsyncRemoved
        /// Added in Swift 6.3 + 1
        case RepresentationChanged
        // Added in Swift 5.TBD
        case ObjectiveCProtocolSymbolicReference
        case OutlinedInitializeWithTakeNoValueWitness
        case OutlinedInitializeWithCopyNoValueWitness
        case OutlinedAssignWithTakeNoValueWitness
        case OutlinedAssignWithCopyNoValueWitness
        case OutlinedDestroyNoValueWitness
        case DependentGenericInverseConformanceRequirement
        // Added in Swift 6.2
        case Integer
        case NegativeInteger
        case DependentGenericParamValueMarker
        case CoroFunctionPointer
        case DefaultOverride
        case ConstValue
        // Added in Swift 6.TBD
        case BorrowAccessor
        case MutateAccessor
    }
}

public extension SwiftSymbol.Kind {
    /// The canonical node-kind name, identical to apple/swift's
    /// `getNodeKindString` (e.g. `"BoundGenericStructure"`). The tree-dump
    /// diff target.
    @inlinable
    var name: String {
        rawValue
    }
}

extension SwiftSymbol.Kind: CustomStringConvertible {
    /// The grammar spelling (the case's `rawValue`) — apple/swift's
    /// `getNodeKindString` name, exactly what `swiftfilt --tree` and
    /// `swift-demangle -tree-only` print. Interpolating a kind therefore
    /// matches the tree output even for the two spellings whose case
    /// names differ (`protocolNode` prints `Protocol`; the backticked
    /// `Type` case prints `Type`).
    public var description: String {
        rawValue
    }
}
