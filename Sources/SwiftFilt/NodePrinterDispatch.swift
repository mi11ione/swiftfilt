// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The `NodePrinter` per-kind dispatch and entity/function/specialization
// rendering — ported from the `print` switch and helpers of
// `lib/Demangling/NodePrinter.cpp`.

extension NodePrinter {
    /// Print `node`. Returns the "postfix context" node an entity could not
    /// print in prefix form (the caller renders it as ` in <context>`), else nil.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @_optimize(speed)
    mutating func print(_ node: B.Node, depth: Int, asPrefixContext: Bool = false) -> B.Node? {
        if depth > SwiftManglingConstants.maxPrintDepth {
            // `NodePrinter::printNode`'s recursion ceiling, restored from the
            // reference: render the marker and stop descending, so a deep
            // subtree prints as the oracle prints it instead of overflowing.
            emit("<<too complex>>")
            return nil
        }
        let d = depth + 1
        let c0 = nb.firstChild(of: node)
        switch nb.kind(of: node) {
        case .Static: emit("static "); printc(c0, d); return nil
        case .AsyncRemoved: emit("async demotion of "); printc(c0, d); return nil
        case .RepresentationChanged: emit("representation changed of "); printc(c0, d); return nil
        case .CurryThunk: emit("curry thunk of "); printc(c0, d); return nil
        case .SILThunkIdentity: emit("identity thunk of "); printc(c0, d); return nil
        case .DispatchThunk: emit("dispatch thunk of "); printc(c0, d); return nil
        case .MethodDescriptor: emit("method descriptor for "); printc(c0, d); return nil
        case .MethodLookupFunction: emit("method lookup function for "); printc(c0, d); return nil
        case .ObjCMetadataUpdateFunction: emit("ObjC metadata update function for "); printc(c0, d); return nil
        case .ObjCResilientClassStub: emit("ObjC resilient class stub for "); printc(c0, d); return nil
        case .FullObjCResilientClassStub: emit("full ObjC resilient class stub for "); printc(c0, d); return nil
        case .OutlinedBridgedMethod: emit("outlined bridged method (\(nb.text(of: node) ?? "")) of "); return nil
        case .OutlinedCopy:
            emit("outlined copy of "); printc(c0, d); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .OutlinedConsume:
            emit("outlined consume of "); printc(c0, d); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .OutlinedRetain: emit("outlined retain of "); printc(c0, d); return nil
        case .OutlinedRelease: emit("outlined release of "); printc(c0, d); return nil
        case .OutlinedInitializeWithTake, .OutlinedInitializeWithTakeNoValueWitness:
            emit("outlined init with take of "); printc(c0, d); return nil
        case .OutlinedInitializeWithCopy, .OutlinedInitializeWithCopyNoValueWitness:
            emit("outlined init with copy of "); printc(c0, d); return nil
        case .OutlinedAssignWithTake, .OutlinedAssignWithTakeNoValueWitness:
            emit("outlined assign with take of "); printc(c0, d); return nil
        case .OutlinedAssignWithCopy, .OutlinedAssignWithCopyNoValueWitness:
            emit("outlined assign with copy of "); printc(c0, d); return nil
        case .OutlinedDestroy, .OutlinedDestroyNoValueWitness:
            emit("outlined destroy of "); printc(c0, d); return nil
        case .OutlinedEnumProjectDataForLoad: emit("outlined enum project data for load of "); printc(c0, d); return nil
        case .OutlinedEnumTagStore: emit("outlined enum tag store of "); printc(c0, d); return nil
        case .OutlinedEnumGetTag: emit("outlined enum get tag of "); printc(c0, d); return nil
        case .OutlinedVariable: emit("outlined variable #"); emit(nb.index(of: node) ?? 0); emit(" of "); return nil
        case .OutlinedReadOnlyObject: emit("outlined read-only object #"); emit(nb.index(of: node) ?? 0); emit(" of "); return nil
        case .Directness: emit(nb.index(of: node) == 0 ? "direct " : "indirect "); return nil
        case .AnonymousContext:
            if options.qualifyEntities, options.displayExtensionContexts {
                _ = print(nb.child(of: node, at: 1), depth: d)
                emit(".(unknown context at "); printc(c0, d); emit(")")
                if nb.childCount(of: node) >= 3, nb.childCount(of: nb.child(of: node, at: 2)) != 0 {
                    emit("<"); _ = print(nb.child(of: node, at: 2), depth: d); emit(">")
                }
            }
            return nil
        case .Extension:
            if options.qualifyEntities, options.displayExtensionContexts {
                emit("(extension in ")
                _ = print(nb.child(of: node, at: 0), depth: d, asPrefixContext: true)
                emit("):")
            }
            _ = print(nb.child(of: node, at: 1), depth: d)
            if nb.childCount(of: node) == 3, !options.printForTypeName { _ = print(nb.child(of: node, at: 2), depth: d) }
            return nil
        case .Variable:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .withColon, hasName: true)
        case .Function, .BoundGenericFunction:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .functionStyle, hasName: true)
        case .Subscript:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .functionStyle,
                               hasName: false, extraName: "", extraIndex: -1, overwriteName: "subscript")
        case .Macro:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext,
                               type: nb.childCount(of: node) == 3 ? .withColon : .functionStyle, hasName: true)
        case .AccessorAttachedMacroExpansion, .MemberAttributeAttachedMacroExpansion,
             .MemberAttachedMacroExpansion, .PeerAttachedMacroExpansion, .ConformanceAttachedMacroExpansion,
             .ExtensionAttachedMacroExpansion, .BodyAttachedMacroExpansion, .PreambleAttachedMacroExpansion:
            let desc = macroRoleDescription(nb.kind(of: node))
            let name = nb.childCount(of: node) > 2 ? subPrint(nb.child(of: node, at: 2)) : ""
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: true,
                               extraName: "\(desc) macro @\(name) expansion #",
                               extraIndex: Int(child(node, 3).flatMap { nb.index(of: $0) } ?? 0) + 1)
        case .FreestandingMacroExpansion:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: true,
                               extraName: "freestanding macro expansion #",
                               extraIndex: Int(child(node, 2).flatMap { nb.index(of: $0) } ?? 0) + 1)
        case .MacroExpansionLoc:
            if nb.childCount(of: node) > 0 { emit("module "); printc(c0, d) }
            if nb.childCount(of: node) > 1 { emit(" file "); _ = print(nb.child(of: node, at: 1), depth: d) }
            if nb.childCount(of: node) > 2 { emit(" line "); _ = print(nb.child(of: node, at: 2), depth: d) }
            if nb.childCount(of: node) > 3 { emit(" column "); _ = print(nb.child(of: node, at: 3), depth: d) }
            return nil
        case .MacroExpansionUniqueName:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: true,
                               extraName: "unique name #", extraIndex: Int(child(node, 2).flatMap { nb.index(of: $0) } ?? 0) + 1)
        case .GenericTypeParamDecl:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: true)
        case .ExplicitClosure:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext,
                               type: options.showFunctionArgumentTypes ? .functionStyle : .noType,
                               hasName: false, extraName: "closure #", extraIndex: Int(child(node, 1).flatMap { nb.index(of: $0) } ?? 0) + 1)
        case .ImplicitClosure:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext,
                               type: options.showFunctionArgumentTypes ? .functionStyle : .noType,
                               hasName: false, extraName: "implicit closure #", extraIndex: Int(child(node, 1).flatMap { nb.index(of: $0) } ?? 0) + 1)
        case .Global: printChildren(node, depth: depth); return nil
        case .Suffix:
            if options.displayUnmangledSuffix { emit(" with unmangled suffix " + quoted(nb.text(of: node) ?? "")) }
            return nil
        case .Initializer:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false,
                               extraName: "variable initialization expression")
        case .PropertyWrapperBackingInitializer:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false,
                               extraName: "property wrapper backing initializer")
        case .PropertyWrappedFieldInitAccessor:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false,
                               extraName: "property wrapped field init accessor")
        case .PropertyWrapperInitFromProjectedValue:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false,
                               extraName: "property wrapper init from projected value")
        case .DefaultArgumentInitializer:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false,
                               extraName: "default argument ", extraIndex: Int(child(node, 1).flatMap { nb.index(of: $0) } ?? 0))
        case .DeclContext: printc(c0, d); return nil
        case .`Type`: printc(c0, d); return nil
        case .TypeMangling:
            if let c0, nb.kind(of: c0) == .LabelList, let c1 = child(node, 1), let inner = nb.firstChild(of: c1) {
                printFunctionType(labelList: c0, inner, depth: depth)
            } else { printc(c0, d) }
            return nil
        case .Class, .Structure, .Enum, .protocolNode, .TypeAlias, .OtherNominalType:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: true)
        case .LocalDeclName:
            if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            if options.displayLocalNameContexts { emit(" #"); emit((c0.flatMap { nb.index(of: $0) } ?? 0) + 1) }
            return nil
        case .PrivateDeclName:
            if nb.childCount(of: node) > 1 {
                if options.showPrivateDiscriminators { emit("(") }
                _ = print(nb.child(of: node, at: 1), depth: d)
                if options.showPrivateDiscriminators { emit(" in "); if let c = c0 { emitText(of: c) }; emit(")") }
            } else if options.showPrivateDiscriminators {
                emit("(in "); if let c = c0 { emitText(of: c) }; emit(")")
            }
            return nil
        case .RelatedEntityDeclName:
            emit("related decl '"); if let c = c0 { emitText(of: c) }; emit("' for "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .Module: if options.displayModuleNames { emitText(of: node) }; return nil
        case .Identifier: emitText(of: node); return nil
        case .Index: emit(nb.index(of: node) ?? 0); return nil
        case .UnknownIndex: emit("unknown index"); return nil
        case .FunctionType, .UncurriedFunctionType, .NoEscapeFunctionType, .AutoClosureType,
             .EscapingAutoClosureType, .ThinFunctionType, .CFunctionPointer, .ObjCBlock, .EscapingObjCBlock:
            printFunctionType(labelList: nil, node, depth: depth); return nil
        case .ClangType: emitText(of: node); return nil
        case .ArgumentTuple: printFunctionParameters(labelList: nil, node, depth: depth, showTypes: options.showFunctionArgumentTypes); return nil
        case .Tuple: emit("("); printChildren(node, depth: depth, separator: ", "); emit(")"); return nil
        case .TupleElement:
            if let label = childIf(node, .TupleElementName) { emitText(of: label); emit(": ") }
            if let type = childIf(node, .`Type`) { _ = print(type, depth: d) }
            if childIf(node, .VariadicMarker) != nil { emit("...") }
            return nil
        case .TupleElementName: emitText(of: node); emit(": "); return nil
        case .Pack: emit("Pack{"); printChildren(node, depth: depth, separator: ", "); emit("}"); return nil
        case .SILPackDirect, .SILPackIndirect:
            emit(nb.kind(of: node) == .SILPackDirect ? "@direct" : "@indirect")
            emit(" Pack{"); printChildren(node, depth: depth, separator: ", "); emit("}"); return nil
        case .PackExpansion: emit("repeat "); printc(c0, d); return nil
        case .PackElement:
            emit("/* level: "); emit(child(node, 1).flatMap { nb.index(of: $0) } ?? 0); emit(" */ "); emit("each "); printc(c0, d); return nil
        case .ReturnType:
            if nb.childCount(of: node) == 0 { emitText(of: node) } else { printChildren(node, depth: depth) }
            return nil
        case .RetroactiveConformance:
            if nb.childCount(of: node) != 2 { return nil }
            emit("retroactive @ "); printc(c0, d); _ = print(nb.child(of: node, at: 1), depth: d); return nil
        case .Weak: emit("weak "); printc(c0, d); return nil
        case .Unowned: emit("unowned "); printc(c0, d); return nil
        case .Unmanaged: emit("unowned(unsafe) "); printc(c0, d); return nil
        case .InOut: emit("inout "); printc(c0, d); return nil
        case .Isolated: emit("isolated "); printc(c0, d); return nil
        case .Sending: emit("sending "); printc(c0, d); return nil
        case .CompileTimeLiteral: emit("_const "); printc(c0, d); return nil
        case .ConstValue: emit("@const "); printc(c0, d); return nil
        case .Shared: emit("__shared "); printc(c0, d); return nil
        case .Owned: emit("__owned "); printc(c0, d); return nil
        case .NoDerivative: emit("@noDerivative "); printc(c0, d); return nil
        case .NonObjCAttribute: emit("@nonobjc "); return nil
        case .ObjCAttribute: emit("@objc "); return nil
        case .DirectMethodReferenceAttribute: emit("super "); return nil
        case .DynamicAttribute: emit("dynamic "); return nil
        case .VTableAttribute: emit("override "); return nil
        case .FunctionSignatureSpecialization: printSpecializationPrefix(node, "function signature specialization", depth: depth); return nil
        case .GenericPartialSpecialization: printSpecializationPrefix(node, "generic partial specialization", depth: depth, paramPrefix: "Signature = "); return nil
        case .GenericPartialSpecializationNotReAbstracted: printSpecializationPrefix(node, "generic not-reabstracted partial specialization", depth: depth, paramPrefix: "Signature = "); return nil
        case .GenericSpecialization, .GenericSpecializationInResilienceDomain: printSpecializationPrefix(node, "generic specialization", depth: depth); return nil
        case .GenericSpecializationPrespecialized: printSpecializationPrefix(node, "generic pre-specialization", depth: depth); return nil
        case .GenericSpecializationNotReAbstracted: printSpecializationPrefix(node, "generic not re-abstracted specialization", depth: depth); return nil
        case .InlinedGenericFunction: printSpecializationPrefix(node, "inlined generic function", depth: depth); return nil
        case .IsSerialized: emit("serialized"); return nil
        case .DroppedArgument: emit("param"); emit(nb.index(of: node) ?? 0); emit("-removed"); return nil
        case .GenericSpecializationParam:
            printc(c0, d)
            for i in 1 ..< nb.childCount(of: node) {
                emit(i == 1 ? " with " : " and "); _ = print(nb.child(of: node, at: i), depth: d)
            }
            return nil
        case .FunctionSignatureSpecializationParamPayload:
            if let t = nb.text(of: node) {
                let demangled = demangleSymbolAsString(t)
                emit(demangled.isEmpty ? t : demangled)
            } else if let i = nb.index(of: node) { emit(i) }
            return nil
        case .FunctionSignatureSpecializationParamKind:
            printFunctionSigSpecializationParamKind(node); return nil
        case .SpecializationPassID: emit(nb.index(of: node) ?? 0); return nil
        case .BuiltinTypeName: emitText(of: node); return nil
        case .BuiltinTupleType: emit("Builtin.TheTupleType"); return nil
        case .BuiltinFixedArray:
            emit("Builtin.FixedArray<"); printc(c0, d); emit(", "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; emit(">"); return nil
        case .BuiltinBorrow: emit("Builtin.Borrow<"); printc(c0, d); emit(">"); return nil
        case .Number: emit(nb.index(of: node) ?? 0); return nil
        case .InfixOperator: emitText(of: node); emit(" infix"); return nil
        case .PrefixOperator: emitText(of: node); emit(" prefix"); return nil
        case .PostfixOperator: emitText(of: node); emit(" postfix"); return nil
        case .LazyProtocolWitnessTableAccessor:
            emit("lazy protocol witness table accessor for type "); printc(c0, d)
            emit(" and conformance "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .LazyProtocolWitnessTableCacheVariable:
            emit("lazy protocol witness table cache variable for type "); printc(c0, d)
            emit(" and conformance "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .ProtocolSelfConformanceWitnessTable: emit("protocol self-conformance witness table for "); printc(c0, d); return nil
        case .ProtocolWitnessTableAccessor: emit("protocol witness table accessor for "); printc(c0, d); return nil
        case .ProtocolWitnessTable: emit("protocol witness table for "); printc(c0, d); return nil
        case .ProtocolWitnessTablePattern: emit("protocol witness table pattern for "); printc(c0, d); return nil
        case .GenericProtocolWitnessTable: emit("generic protocol witness table for "); printc(c0, d); return nil
        case .GenericProtocolWitnessTableInstantiationFunction:
            emit("instantiation function for generic protocol witness table for "); printc(c0, d); return nil
        case .ResilientProtocolWitnessTable: emit("resilient protocol witness table for "); printc(c0, d); return nil
        case .VTableThunk:
            emit("vtable thunk for "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            emit(" dispatching to "); printc(c0, d); return nil
        case .ProtocolSelfConformanceWitness: emit("protocol self-conformance witness for "); printc(c0, d); return nil
        case .ProtocolWitness:
            emit("protocol witness for "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            emit(" in conformance "); printc(c0, d); return nil
        case .PartialApplyForwarder:
            emit(options.shortenPartialApply ? "partial apply" : "partial apply forwarder")
            if nb.childCount(of: node) != 0 { emit(" for "); printChildren(node, depth: depth) }
            return nil
        case .PartialApplyObjCForwarder:
            emit(options.shortenPartialApply ? "partial apply" : "partial apply ObjC forwarder")
            if nb.childCount(of: node) != 0 { emit(" for "); printChildren(node, depth: depth) }
            return nil
        case .KeyPathGetterThunkHelper, .KeyPathSetterThunkHelper,
             .KeyPathUnappliedMethodThunkHelper, .KeyPathAppliedMethodThunkHelper:
            switch nb.kind(of: node) {
            case .KeyPathGetterThunkHelper: emit("key path getter for ")
            case .KeyPathSetterThunkHelper: emit("key path setter for ")
            case .KeyPathUnappliedMethodThunkHelper: emit("key path unapplied method ")
            default: emit("key path applied method ")
            }
            printc(c0, d); emit(" : ")
            for i in 1 ..< nb.childCount(of: node) {
                if nb.kind(of: nb.child(of: node, at: i)) == .IsSerialized { emit(", ") }
                _ = print(nb.child(of: node, at: i), depth: d)
            }
            return nil
        case .KeyPathEqualsThunkHelper, .KeyPathHashThunkHelper:
            emit("key path index \(nb.kind(of: node) == .KeyPathEqualsThunkHelper ? "equality" : "hash") operator for ")
            var lastIndex = nb.childCount(of: node)
            var last = nb.child(of: node, at: lastIndex - 1)
            if nb.kind(of: last) == .IsSerialized { lastIndex -= 1; last = nb.child(of: node, at: lastIndex - 1) }
            if nb.kind(of: last) == .DependentGenericSignature { _ = print(last, depth: d); lastIndex -= 1 }
            emit("(")
            for i in 0 ..< lastIndex {
                if i != 0 { emit(", ") }; _ = print(nb.child(of: node, at: i), depth: d)
            }
            emit(")")
            return nil
        case .FieldOffset:
            printc(c0, d); emit("field offset for ")
            if let c1 = child(node, 1) { _ = print(c1, depth: d, asPrefixContext: false) }
            return nil
        case .EnumCase: emit("enum case for "); if let c = c0 { _ = print(c, depth: d, asPrefixContext: false) }; return nil
        case .ReabstractionThunk, .ReabstractionThunkHelper:
            if options.shortenThunk {
                emit("thunk for "); _ = print(nb.child(of: node, at: nb.childCount(of: node) - 1), depth: d); return nil
            }
            emit("reabstraction thunk ")
            if nb.kind(of: node) == .ReabstractionThunkHelper { emit("helper ") }
            var idx = 0
            if nb.childCount(of: node) == 3 { _ = print(nb.child(of: node, at: 0), depth: d); emit(" "); idx = 1 }
            emit("from "); _ = print(nb.child(of: node, at: idx + 1), depth: d)
            emit(" to "); _ = print(nb.child(of: node, at: idx), depth: d)
            return nil
        case .ReabstractionThunkHelperWithGlobalActor:
            printc(c0, d); emit(" with global actor constraint "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .ReabstractionThunkHelperWithSelf:
            emit("reabstraction thunk ")
            var idx = 0
            if nb.childCount(of: node) == 4 { _ = print(nb.child(of: node, at: 0), depth: d); emit(" "); idx = 1 }
            emit("from "); _ = print(nb.child(of: node, at: idx + 2), depth: d)
            emit(" to "); _ = print(nb.child(of: node, at: idx + 1), depth: d)
            emit(" self "); _ = print(nb.child(of: node, at: idx), depth: d)
            return nil
        case .AutoDiffFunction, .AutoDiffDerivativeVTableThunk:
            printAutoDiffFunction(node, depth: depth); return nil
        case .AutoDiffSelfReorderingReabstractionThunk:
            printAutoDiffSelfReordering(node, depth: depth); return nil
        case .AutoDiffSubsetParametersThunk:
            printAutoDiffSubsetParameters(node, depth: depth); return nil
        case .AutoDiffFunctionKind:
            switch nb.index(of: node).map({ UnicodeScalar(UInt8($0)) }) {
            case "f": emit("forward-mode derivative")
            case "r": emit("reverse-mode derivative")
            case "d": emit("differential")
            case "p": emit("pullback")
            default: break
            }
            return nil
        case .DifferentiabilityWitness: printDifferentiabilityWitness(node, depth: depth); return nil
        case .IndexSubset:
            emit("{")
            let chars = Array(nb.text(of: node) ?? "")
            var printedAny = false
            for (i, ch) in chars.enumerated() where ch == "S" {
                if printedAny { emit(", ") }
                emit(UInt64(i)); printedAny = true
            }
            emit("}")
            return nil
        case .MergedFunction: if !options.shortenThunk { emit("merged ") }; return nil
        case .TypeSymbolicReference: emit("type symbolic reference 0x"); emitHex(nb.index(of: node) ?? 0); return nil
        case .OpaqueTypeDescriptorSymbolicReference: emit("opaque type symbolic reference 0x"); emitHex(nb.index(of: node) ?? 0); return nil
        case .DistributedThunk: if !options.shortenThunk { emit("distributed thunk ") }; return nil
        case .DistributedAccessor: if !options.shortenThunk { emit("distributed accessor for ") }; return nil
        case .AccessibleFunctionRecord: if !options.shortenThunk { emit("accessible function runtime record for ") }; return nil
        case .DynamicallyReplaceableFunctionKey: if !options.shortenThunk { emit("dynamically replaceable key for ") }; return nil
        case .DynamicallyReplaceableFunctionImpl: if !options.shortenThunk { emit("dynamically replaceable thunk for ") }; return nil
        case .DynamicallyReplaceableFunctionVar: if !options.shortenThunk { emit("dynamically replaceable variable for ") }; return nil
        case .BackDeploymentThunk: if !options.shortenThunk { emit("back deployment thunk for ") }; return nil
        case .BackDeploymentFallback: emit("back deployment fallback for "); return nil
        case .ProtocolSymbolicReference: emit("protocol symbolic reference 0x"); emitHex(nb.index(of: node) ?? 0); return nil
        case .GenericTypeMetadataPattern: emit("generic type metadata pattern for "); printc(c0, d); return nil
        case .Metaclass: emit("metaclass for "); printc(c0, d); return nil
        case .ProtocolSelfConformanceDescriptor: emit("protocol self-conformance descriptor for "); printc(c0, d); return nil
        case .ProtocolConformanceDescriptor: emit("protocol conformance descriptor for "); printc(c0, d); return nil
        case .ProtocolConformanceDescriptorRecord: emit("protocol conformance descriptor runtime record for "); printc(c0, d); return nil
        case .ProtocolDescriptor: emit("protocol descriptor for "); printc(c0, d); return nil
        case .ProtocolDescriptorRecord: emit("protocol descriptor runtime record for "); printc(c0, d); return nil
        case .ProtocolRequirementsBaseDescriptor: emit("protocol requirements base descriptor for "); printc(c0, d); return nil
        case .FullTypeMetadata: emit("full type metadata for "); printc(c0, d); return nil
        case .TypeMetadata: emit("type metadata for "); printc(c0, d); return nil
        case .TypeMetadataAccessFunction: emit("type metadata accessor for "); printc(c0, d); return nil
        case .TypeMetadataInstantiationCache: emit("type metadata instantiation cache for "); printc(c0, d); return nil
        case .TypeMetadataInstantiationFunction: emit("type metadata instantiation function for "); printc(c0, d); return nil
        case .TypeMetadataSingletonInitializationCache: emit("type metadata singleton initialization cache for "); printc(c0, d); return nil
        case .TypeMetadataCompletionFunction: emit("type metadata completion function for "); printc(c0, d); return nil
        case .TypeMetadataDemanglingCache: emit("demangling cache variable for type metadata for "); printc(c0, d); return nil
        case .TypeMetadataMangledNameRef: emit("mangled name ref for type metadata for "); printc(c0, d); return nil
        case .TypeMetadataLazyCache: emit("lazy cache variable for type metadata for "); printc(c0, d); return nil
        case .AssociatedConformanceDescriptor:
            emit("associated conformance descriptor for "); printc(c0, d); emit(".")
            if let c1 = child(node, 1) { _ = print(c1, depth: d) }; emit(": ")
            if let c2 = child(node, 2) { _ = print(c2, depth: d) }; return nil
        case .DefaultAssociatedConformanceAccessor:
            emit("default associated conformance accessor for "); printc(c0, d); emit(".")
            if let c1 = child(node, 1) { _ = print(c1, depth: d) }; emit(": ")
            if let c2 = child(node, 2) { _ = print(c2, depth: d) }; return nil
        case .AssociatedTypeDescriptor: emit("associated type descriptor for "); printc(c0, d); return nil
        case .AssociatedTypeMetadataAccessor:
            emit("associated type metadata accessor for "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            emit(" in "); printc(c0, d); return nil
        case .BaseConformanceDescriptor:
            emit("base conformance descriptor for "); printc(c0, d); emit(": "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .DefaultAssociatedTypeMetadataAccessor: emit("default associated type metadata accessor for "); printc(c0, d); return nil
        case .AssociatedTypeWitnessTableAccessor:
            emit("associated type witness table accessor for "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            emit(" : "); if let c2 = child(node, 2) { _ = print(c2, depth: d) }; emit(" in "); printc(c0, d); return nil
        case .BaseWitnessTableAccessor:
            emit("base witness table accessor for "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            emit(" in "); printc(c0, d); return nil
        case .ClassMetadataBaseOffset: emit("class metadata base offset for "); printc(c0, d); return nil
        case .PropertyDescriptor: emit("property descriptor for "); printc(c0, d); return nil
        case .NominalTypeDescriptor: emit("nominal type descriptor for "); printc(c0, d); return nil
        case .NominalTypeDescriptorRecord: emit("nominal type descriptor runtime record for "); printc(c0, d); return nil
        case .OpaqueTypeDescriptor: emit("opaque type descriptor for "); printc(c0, d); return nil
        case .OpaqueTypeDescriptorRecord: emit("opaque type descriptor runtime record for "); printc(c0, d); return nil
        case .OpaqueTypeDescriptorAccessor: emit("opaque type descriptor accessor for "); printc(c0, d); return nil
        case .OpaqueTypeDescriptorAccessorImpl: emit("opaque type descriptor accessor impl for "); printc(c0, d); return nil
        case .OpaqueTypeDescriptorAccessorKey: emit("opaque type descriptor accessor key for "); printc(c0, d); return nil
        case .OpaqueTypeDescriptorAccessorVar: emit("opaque type descriptor accessor var for "); printc(c0, d); return nil
        case .CoroutineContinuationPrototype: emit("coroutine continuation prototype for "); printc(c0, d); return nil
        case .ValueWitness:
            emit(ValueWitnessKinds.name(forIndex: Int(c0.flatMap { nb.index(of: $0) } ?? 0)) ?? "")
            emit(options.shortenValueWitness ? " for " : " value witness for ")
            if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .ValueWitnessTable: emit("value witness table for "); printc(c0, d); return nil
        case .BoundGenericClass, .BoundGenericStructure, .BoundGenericEnum, .BoundGenericProtocol,
             .BoundGenericOtherNominalType, .BoundGenericTypeAlias:
            printBoundGeneric(node, depth: depth); return nil
        case .DynamicSelf: emit("Self"); return nil
        case .SILBoxType: emit("@box "); printc(c0, d); return nil
        case .Metatype:
            var idx = 0
            if nb.childCount(of: node) == 2 { _ = print(nb.child(of: node, at: 0), depth: d); emit(" "); idx = 1 }
            if let type = child(node, idx).flatMap({ nb.firstChild(of: $0) }) {
                printWithParens(type, depth: depth)
                emit(isExistentialType(type) ? ".Protocol" : ".Type")
            }
            return nil
        case .ConstrainedExistential:
            emit("any "); printc(c0, d); emit("<"); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; emit(">"); return nil
        case .ConstrainedExistentialRequirementList: printChildren(node, depth: depth, separator: ", "); return nil
        case .ExistentialMetatype:
            var idx = 0
            if nb.childCount(of: node) == 2 { _ = print(nb.child(of: node, at: 0), depth: d); emit(" "); idx = 1 }
            if let type = child(node, idx) { _ = print(type, depth: d) }
            emit(".Type"); return nil
        case .ConstrainedExistentialSelf: emit("Self"); return nil
        case .MetatypeRepresentation: emitText(of: node); return nil
        case .AssociatedTypeRef:
            printc(c0, d); emit("."); if let c1 = child(node, 1) { emitText(of: c1) }; return nil
        case .ProtocolList:
            guard let list = c0 else { return nil }
            if nb.childCount(of: list) == 0 { emit("Any") } else { printChildren(list, depth: depth, separator: " & ") }
            return nil
        case .ProtocolListWithClass:
            guard nb.childCount(of: node) >= 2 else { return nil }
            _ = print(nb.child(of: node, at: 1), depth: d); emit(" & ")
            guard let list = nb.firstChild(of: nb.child(of: node, at: 0)) else { return nil }
            printChildren(list, depth: depth, separator: " & "); return nil
        case .ProtocolListWithAnyObject:
            guard let protos = c0, let list = nb.firstChild(of: protos) else { return nil }
            if nb.childCount(of: list) != 0 { printChildren(list, depth: depth, separator: " & "); emit(" & ") }
            if options.qualifyEntities, options.displayStdlibModule { emit(SwiftManglingConstants.stdlibName); emit(".") }
            emit("AnyObject"); return nil
        case .AssociatedType: return nil
        case .OwningAddressor: return printAccessor(node, "owningAddressor", depth, asPrefixContext)
        case .OwningMutableAddressor: return printAccessor(node, "owningMutableAddressor", depth, asPrefixContext)
        case .NativeOwningAddressor: return printAccessor(node, "nativeOwningAddressor", depth, asPrefixContext)
        case .NativeOwningMutableAddressor: return printAccessor(node, "nativeOwningMutableAddressor", depth, asPrefixContext)
        case .NativePinningAddressor: return printAccessor(node, "nativePinningAddressor", depth, asPrefixContext)
        case .NativePinningMutableAddressor: return printAccessor(node, "nativePinningMutableAddressor", depth, asPrefixContext)
        case .UnsafeAddressor: return printAccessor(node, "unsafeAddressor", depth, asPrefixContext)
        case .UnsafeMutableAddressor: return printAccessor(node, "unsafeMutableAddressor", depth, asPrefixContext)
        case .GlobalGetter: return printAccessor(node, "getter", depth, asPrefixContext)
        case .Getter: return printAccessor(node, "getter", depth, asPrefixContext)
        case .Setter: return printAccessor(node, "setter", depth, asPrefixContext)
        case .MaterializeForSet: return printAccessor(node, "materializeForSet", depth, asPrefixContext)
        case .WillSet: return printAccessor(node, "willset", depth, asPrefixContext)
        case .DidSet: return printAccessor(node, "didset", depth, asPrefixContext)
        case .ReadAccessor: return printAccessor(node, "read", depth, asPrefixContext)
        case .YieldingBorrowAccessor: return printAccessor(node, "yielding_borrow", depth, asPrefixContext)
        case .ModifyAccessor: return printAccessor(node, "modify", depth, asPrefixContext)
        case .YieldingMutateAccessor: return printAccessor(node, "yielding_mutate", depth, asPrefixContext)
        case .InitAccessor: return printAccessor(node, "init", depth, asPrefixContext)
        case .BorrowAccessor: return printAccessor(node, "borrow", depth, asPrefixContext)
        case .MutateAccessor: return printAccessor(node, "mutate", depth, asPrefixContext)
        case .Allocator:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .functionStyle, hasName: false,
                               extraName: (c0.map { isClassType($0) } ?? false) ? "__allocating_init" : "init")
        case .Constructor:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .functionStyle,
                               hasName: nb.childCount(of: node) > 2, extraName: "init")
        case .Destructor:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false, extraName: "deinit")
        case .Deallocator:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false,
                               extraName: (c0.map { isClassType($0) } ?? false) ? "__deallocating_deinit" : "deinit")
        case .IsolatedDeallocator:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false,
                               extraName: (c0.map { isClassType($0) } ?? false) ? "__isolated_deallocating_deinit" : "deinit")
        case .IVarInitializer:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false, extraName: "__ivar_initializer")
        case .IVarDestroyer:
            return printEntity(node, depth: depth, asPrefixContext: asPrefixContext, type: .noType, hasName: false, extraName: "__ivar_destroyer")
        case .ProtocolConformance: printProtocolConformance(node, depth: depth); return nil
        case .TypeList: printChildren(node, depth: depth); return nil
        case .LabelList: return nil
        case .ImplDifferentiabilityKind:
            emit("@differentiable")
            switch nb.index(of: node).map({ UnicodeScalar(UInt8($0)) }) {
            case "l": emit("(_linear)"); case "f": emit("(_forward)"); case "r": emit("(reverse)"); default: break
            }
            return nil
        case .ImplEscaping: emit("@escaping"); return nil
        case .ImplNonisolatedNonsendingIsolation: emit("@caller_isolated"); return nil
        case .ImplErasedIsolation: emit("@isolated(any)"); return nil
        case .ImplCoroutineKind:
            if let t = nb.text(of: node), !t.isEmpty { emit("@"); emit(t) }; return nil
        case .ImplSendingResult: emit("sending"); return nil
        case .ImplConvention: emitText(of: node); return nil
        case .ImplParameterResultDifferentiability, .ImplParameterSending, .ImplParameterIsolated, .ImplParameterImplicitLeading:
            if let t = nb.text(of: node), !t.isEmpty { emit(t); emit(" ") }; return nil
        case .ImplFunctionAttribute: emitText(of: node); return nil
        case .ImplFunctionConvention:
            emit("@convention(")
            if nb.childCount(of: node) == 1 { if let c = c0 { emitText(of: c) } }
            else if nb.childCount(of: node) == 2 { if let c = c0 { emitText(of: c) }; emit(", mangledCType: \""); _ = print(nb.child(of: node, at: 1), depth: d); emit("\"") }
            emit(")"); return nil
        case .ImplFunctionConventionName: return nil
        case .ImplErrorResult: emit("@error "); printChildren(node, depth: depth, separator: " "); return nil
        case .ImplYield: emit("@yields "); printChildren(node, depth: depth, separator: " "); return nil
        case .ImplParameter, .ImplResult:
            printc(c0, d); emit(" ")
            if nb.childCount(of: node) == 3 { if let c1 = child(node, 1) { _ = print(c1, depth: d) } }
            if nb.childCount(of: node) == 4 { if let c1 = child(node, 1) { _ = print(c1, depth: d) }; if let c2 = child(node, 2) { _ = print(c2, depth: d) } }
            if let last = nb.lastChild(of: node) { _ = print(last, depth: d) }
            return nil
        case .ImplFunctionType: printImplFunctionType(node, depth: depth); return nil
        case .ImplInvocationSubstitutions:
            emit("for <"); if let c = c0 { printChildren(c, depth: depth, separator: ", ") }; emit(">"); return nil
        case .ImplPatternSubstitutions:
            emit("@substituted "); printc(c0, d); emit(" for <")
            if let c1 = child(node, 1) { printChildren(c1, depth: depth, separator: ", ") }; emit(">"); return nil
        case .ErrorType: emit("<ERROR TYPE>"); return nil
        case .DependentPseudogenericSignature, .DependentGenericSignature: printGenericSignature(node, depth: depth); return nil
        case .DependentGenericConformanceRequirement:
            printc(c0, d); emit(": "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .DependentGenericInverseConformanceRequirement:
            printc(c0, d); emit(": ~")
            switch child(node, 1).flatMap({ nb.index(of: $0) }) {
            case 0: emit("Swift.Copyable"); case 1: emit("Swift.Escapable")
            default: emit("Swift.<bit \(child(node, 1).flatMap { nb.index(of: $0) } ?? 0)>")
            }
            return nil
        case .DependentGenericLayoutRequirement: printLayoutRequirement(node, depth: depth); return nil
        case .DependentGenericSameTypeRequirement:
            printc(c0, d); emit(" == "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .DependentGenericSameShapeRequirement:
            printc(c0, d); emit(".shape == "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; emit(".shape"); return nil
        case .DependentGenericParamType:
            emit(options.genericParameterName(depth: c0.flatMap { nb.index(of: $0) } ?? 0, index: child(node, 1).flatMap { nb.index(of: $0) } ?? 0)); return nil
        case .DependentGenericType:
            printc(c0, d)
            if let depTy = child(node, 1) { if needSpaceBeforeType(depTy) { emit(" ") }; _ = print(depTy, depth: d) }
            return nil
        case .DependentMemberType:
            printc(c0, d); emit("."); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .DependentAssociatedTypeRef:
            if nb.childCount(of: node) > 1 { _ = print(nb.child(of: node, at: 1), depth: d); emit(".") }
            printc(c0, d); return nil
        case .ReflectionMetadataBuiltinDescriptor: emit("reflection metadata builtin descriptor "); printc(c0, d); return nil
        case .ReflectionMetadataFieldDescriptor: emit("reflection metadata field descriptor "); printc(c0, d); return nil
        case .ReflectionMetadataAssocTypeDescriptor: emit("reflection metadata associated type descriptor "); printc(c0, d); return nil
        case .ReflectionMetadataSuperclassDescriptor: emit("reflection metadata superclass descriptor "); printc(c0, d); return nil
        case .ConcurrentFunctionType: emit("@Sendable "); return nil
        case .DifferentiableFunctionType:
            emit("@differentiable")
            switch nb.index(of: node).map({ UnicodeScalar(UInt8($0)) }) {
            case "f": emit("(_forward)"); case "r": emit("(reverse)"); case "l": emit("(_linear)"); default: break
            }
            emit(" "); return nil
        case .GlobalActorFunctionType:
            if let c = c0 { emit("@"); _ = print(c, depth: d); emit(" ") }; return nil
        case .IsolatedAnyFunctionType: emit("@isolated(any) "); return nil
        case .NonIsolatedCallerFunctionType: emit("nonisolated(nonsending) "); return nil
        case .SendingResultFunctionType: emit("sending "); return nil
        case .AsyncAnnotation: emit(" async"); return nil
        case .ThrowsAnnotation: emit(" throws"); return nil
        case .TypedThrowsAnnotation:
            emit(" throws("); if nb.childCount(of: node) == 1 { printc(c0, d) }; emit(")"); return nil
        case .EmptyList: emit(" empty-list "); return nil
        case .FirstElementMarker: emit(" first-element-marker "); return nil
        case .VariadicMarker: emit(" variadic-marker "); return nil
        case .SILBoxTypeWithLayout: printSILBoxTypeWithLayout(node, depth: depth); return nil
        case .SILBoxLayout:
            emit("{")
            for i in 0 ..< nb.childCount(of: node) {
                if i > 0 { emit(",") }; emit(" "); _ = print(nb.child(of: node, at: i), depth: d)
            }
            emit(" }"); return nil
        case .SILBoxImmutableField, .SILBoxMutableField:
            emit(nb.kind(of: node) == .SILBoxImmutableField ? "let " : "var "); printc(c0, d); return nil
        case .AssocTypePath: printChildren(node, depth: depth, separator: "."); return nil
        case .ModuleDescriptor: emit("module descriptor "); printc(c0, d); return nil
        case .AnonymousDescriptor: emit("anonymous descriptor "); printc(c0, d); return nil
        case .ExtensionDescriptor: emit("extension descriptor "); printc(c0, d); return nil
        case .AssociatedTypeGenericParamRef: emit("generic parameter reference for associated type "); printChildren(node, depth: depth); return nil
        case .AnyProtocolConformanceList:
            if nb.childCount(of: node) != 0 {
                emit("(")
                for i in 0 ..< nb.childCount(of: node) {
                    if i > 0 { emit(", ") }; _ = print(nb.child(of: node, at: i), depth: d)
                }
                emit(")")
            }
            return nil
        case .ConcreteProtocolConformance:
            emit("concrete protocol conformance ")
            if let i = nb.index(of: node) { emit("#\(i) ") }
            printc(c0, d); emit(" to "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            if nb.childCount(of: node) > 2, nb.childCount(of: nb.child(of: node, at: 2)) != 0 {
                emit(" with conditional requirements: "); _ = print(nb.child(of: node, at: 2), depth: d)
            }
            return nil
        case .PackProtocolConformance: emit("pack protocol conformance "); printChildren(node, depth: depth); return nil
        case .DependentAssociatedConformance: emit("dependent associated conformance "); printChildren(node, depth: depth); return nil
        case .DependentProtocolConformanceAssociated:
            emit("dependent associated protocol conformance "); if let c2 = child(node, 2) { printOptionalIndex(c2) }
            printc(c0, d); emit(" to "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .DependentProtocolConformanceInherited:
            emit("dependent inherited protocol conformance "); if let c2 = child(node, 2) { printOptionalIndex(c2) }
            printc(c0, d); emit(" to "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .DependentProtocolConformanceRoot:
            emit("dependent root protocol conformance "); if let c2 = child(node, 2) { printOptionalIndex(c2) }
            printc(c0, d); emit(" to "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .DependentProtocolConformanceOpaque:
            emit("opaque result conformance "); printc(c0, d); emit(" of "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .ProtocolConformanceRefInTypeModule: emit("protocol conformance ref (type's module) "); printChildren(node, depth: depth); return nil
        case .ProtocolConformanceRefInProtocolModule: emit("protocol conformance ref (protocol's module) "); printChildren(node, depth: depth); return nil
        case .ProtocolConformanceRefInOtherModule: emit("protocol conformance ref (retroactive) "); printChildren(node, depth: depth); return nil
        case .SugaredOptional: printWithParens(c0 ?? node, depth: depth); emit("?"); return nil
        case .SugaredArray: emit("["); printc(c0, d); emit("]"); return nil
        case .SugaredInlineArray:
            emit("["); printc(c0, d); emit(" of "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; emit("]"); return nil
        case .SugaredDictionary:
            emit("["); printc(c0, d); emit(" : "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; emit("]"); return nil
        case .SugaredParen: emit("("); printc(c0, d); emit(")"); return nil
        case .OpaqueReturnType: emit("some"); return nil
        case .OpaqueReturnTypeOf: emit("<<opaque return type of "); printChildren(node, depth: depth); emit(">>"); return nil
        case .OpaqueType:
            printc(c0, d); emit("."); if let c1 = child(node, 1) { _ = print(c1, depth: d) }; return nil
        case .AccessorFunctionReference: emit("accessor function at \(nb.index(of: node) ?? 0)"); return nil
        case .CanonicalSpecializedGenericMetaclass: emit("specialized generic metaclass for "); printc(c0, d); return nil
        case .CanonicalSpecializedGenericTypeMetadataAccessFunction: emit("canonical specialized generic type metadata accessor for "); printc(c0, d); return nil
        case .MetadataInstantiationCache: emit("metadata instantiation cache for "); printc(c0, d); return nil
        case .NoncanonicalSpecializedGenericTypeMetadata: emit("noncanonical specialized generic type metadata for "); printc(c0, d); return nil
        case .NoncanonicalSpecializedGenericTypeMetadataCache: emit("cache variable for noncanonical specialized generic type metadata for "); printc(c0, d); return nil
        case .GlobalVariableOnceToken, .GlobalVariableOnceFunction:
            emit(nb.kind(of: node) == .GlobalVariableOnceToken ? "one-time initialization token for " : "one-time initialization function for ")
            if let c = c0 { _ = printContext(c) }
            if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            return nil
        case .GlobalVariableOnceDeclList:
            if nb.childCount(of: node) == 1 { printc(c0, d) }
            else {
                emit("(")
                for i in 0 ..< nb.childCount(of: node) {
                    if i != 0 { emit(", ") }; _ = print(nb.child(of: node, at: i), depth: d)
                }
                emit(")")
            }
            return nil
        case .CheckedObjCAsyncCompletionHandlerImpl, .PredefinedObjCAsyncCompletionHandlerImpl, .ObjCAsyncCompletionHandlerImpl:
            if nb.kind(of: node) == .CheckedObjCAsyncCompletionHandlerImpl { emit("checked ") }
            if nb.kind(of: node) == .PredefinedObjCAsyncCompletionHandlerImpl { emit("predefined ") }
            emit("@objc completion handler block implementation for ")
            if nb.childCount(of: node) >= 4 { _ = print(nb.child(of: node, at: 3), depth: d) }
            printc(c0, d); emit(" with result type "); if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            switch child(node, 2).flatMap({ nb.index(of: $0) }) {
            case 0: break
            case 1: emit(" nonzero on error")
            case 2: emit(" zero on error")
            default: emit(" <invalid error flag>")
            }
            return nil
        case .CanonicalPrespecializedGenericTypeCachingOnceToken:
            emit("flag for loading of canonical specialized generic type metadata for "); printc(c0, d); return nil
        case .AsyncFunctionPointer: emit("async function pointer to "); return nil
        case .AsyncAwaitResumePartialFunction:
            if options.showAsyncResumePartial { emit("("); printc(c0, d); emit(")"); emit(" await resume partial function for ") }; return nil
        case .AsyncSuspendResumePartialFunction:
            if options.showAsyncResumePartial { emit("("); printc(c0, d); emit(")"); emit(" suspend resume partial function for ") }; return nil
        case .Uniquable: emit("uniquable "); printc(c0, d); return nil
        case .ExtendedExistentialTypeShape: printExtendedExistentialTypeShape(node, depth: depth); return nil
        case .UniqueExtendedExistentialTypeShapeSymbolicReference: emit("unique existential shape symbolic reference 0x"); emitHex(nb.index(of: node) ?? 0); return nil
        case .NonUniqueExtendedExistentialTypeShapeSymbolicReference: emit("non-unique existential shape symbolic reference 0x"); emitHex(nb.index(of: node) ?? 0); return nil
        case .ObjectiveCProtocolSymbolicReference: emit("objective-c protocol symbolic reference 0x"); emitHex(nb.index(of: node) ?? 0); return nil
        case .SymbolicExtendedExistentialType:
            let isUnique = c0.map { nb.kind(of: $0) } == .UniqueExtendedExistentialTypeShapeSymbolicReference
            emit("symbolic existential type (\(isUnique ? "" : "non-")unique) 0x"); emitHex(c0.flatMap { nb.index(of: $0) } ?? 0)
            emit(" <"); if let c1 = child(node, 1) { _ = print(c1, depth: d) }
            if nb.childCount(of: node) > 2 { emit(", "); _ = print(nb.child(of: node, at: 2), depth: d) }
            emit(">"); return nil
        case .HasSymbolQuery: emit("#_hasSymbol query for "); return nil
        case .OpaqueReturnTypeIndex, .OpaqueReturnTypeParent: return nil
        case .Integer: emit(nb.index(of: node) ?? 0); return nil
        case .NegativeInteger: emit(String(Int(bitPattern: UInt(nb.index(of: node) ?? 0)))); return nil
        case .CoroFunctionPointer: emit("coro function pointer to "); return nil
        case .DefaultOverride: emit("default override of "); return nil
        default:
            return nil
        }
    }

    // MARK: small dispatch helpers

    @inline(__always) private mutating func printc(_ node: B.Node?, _ depth: Int) {
        if let node { _ = print(node, depth: depth) }
    }

    private mutating func emitHex(_ n: UInt64) {
        emit(String(n, radix: 16, uppercase: true))
    }

    private mutating func printAccessor(_ node: B.Node, _ extraName: String, _ depth: Int, _ asPrefixContext: Bool) -> B.Node? {
        guard let storage = nb.firstChild(of: node) else { return nil }
        return printAbstractStorage(storage, depth: depth, asPrefixContext: asPrefixContext, extraName: extraName)
    }

    private mutating func macroRoleDescription(_ kind: SwiftSymbol.Kind) -> String {
        switch kind {
        case .AccessorAttachedMacroExpansion: "accessor"
        case .MemberAttributeAttachedMacroExpansion: "memberAttribute"
        case .MemberAttachedMacroExpansion: "member"
        case .PeerAttachedMacroExpansion: "peer"
        case .ConformanceAttachedMacroExpansion: "conformance"
        case .ExtensionAttachedMacroExpansion: "extension"
        case .BodyAttachedMacroExpansion: "body"
        case .PreambleAttachedMacroExpansion: "preamble"
        default: ""
        }
    }
}
