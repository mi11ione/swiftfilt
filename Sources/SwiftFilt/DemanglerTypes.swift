// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Type, conformance, and bound-generic demangling for the current-mangling
// `Demangler` — ported from `lib/Demangling/Demangler.cpp`.

private enum BuiltinTypeName {
    static let prefix = "Builtin."
    static let int = "Builtin.Int"
    static let float = "Builtin.FPIEEE"
    static let vec = "Builtin.Vec"
    static let implicitActor = "Builtin.ImplicitActor"
    static let bridgeObject = "Builtin.BridgeObject"
    static let unsafeValueBuffer = "Builtin.UnsafeValueBuffer"
    static let executor = "Builtin.Executor"
    static let intLiteral = "Builtin.IntLiteral"
    static let unknownObject = "Builtin.UnknownObject"
    static let nativeObject = "Builtin.NativeObject"
    static let rawPointer = "Builtin.RawPointer"
    static let job = "Builtin.Job"
    static let defaultActorStorage = "Builtin.DefaultActorStorage"
    static let nonDefaultDistributedActorStorage = "Builtin.NonDefaultDistributedActorStorage"
    static let rawUnsafeContinuation = "Builtin.RawUnsafeContinuation"
    static let silToken = "Builtin.SILToken"
    static let word = "Builtin.Word"
    static let packIndex = "Builtin.PackIndex"
}

extension Demangler {
    mutating func demangleBuiltinType() -> B.Node? {
        let maxTypeSize = 4096
        var ty: B.Node?
        switch nextChar() {
        case 0x41: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.implicitActor) // 'A'
        case 0x62: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.bridgeObject) // 'b'
        case 0x42: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.unsafeValueBuffer) // 'B'
        case 0x65: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.executor) // 'e'
        case 0x66: // 'f' Float<n>
            let size = demangleIndex() - 1
            if size <= 0 || size > maxTypeSize { return nil }
            ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.float + String(size))
        case 0x69: // 'i' Int<n>
            let size = demangleIndex() - 1
            if size <= 0 || size > maxTypeSize { return nil }
            ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.int + String(size))
        case 0x49: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.intLiteral) // 'I'
        case 0x76: // 'v' Vec<n>x<type>
            let elts = demangleIndex() - 1
            if elts <= 0 || elts > maxTypeSize { return nil }
            guard let eltType = popTypeAndGetChild(), nb.kind(of: eltType) == .BuiltinTypeName,
                  let eltName = nb.text(of: eltType), eltName.hasPrefix(BuiltinTypeName.prefix)
            else { return nil }
            let suffix = String(eltName.dropFirst(BuiltinTypeName.prefix.count))
            ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.vec + String(elts) + "x" + suffix)
        case 0x56: // 'V' FixedArray
            guard let element = popNode(.`Type`), let size = popNode(.`Type`) else { return nil }
            ty = nb.make(kind: .BuiltinFixedArray, children: [size, element])
        case 0x57: // 'W' Borrow
            guard let referent = popNode(.`Type`) else { return nil }
            ty = nb.make(kind: .BuiltinBorrow, child: referent)
        case 0x4F: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.unknownObject) // 'O'
        case 0x6F: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.nativeObject) // 'o'
        case 0x70: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.rawPointer) // 'p'
        case 0x6A: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.job) // 'j'
        case 0x44: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.defaultActorStorage) // 'D'
        case 0x64: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.nonDefaultDistributedActorStorage) // 'd'
        case 0x63: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.rawUnsafeContinuation) // 'c'
        case 0x74: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.silToken) // 't'
        case 0x77: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.word) // 'w'
        case 0x50: ty = nb.make(kind: .BuiltinTypeName, name: BuiltinTypeName.packIndex) // 'P'
        case 0x54: ty = nb.make(kind: .BuiltinTupleType) // 'T'
        default: return nil
        }
        return createType(ty)
    }

    mutating func demangleAnyGenericType(_ kind: SwiftSymbol.Kind) -> B.Node? {
        let name = popNode(DemanglerPredicates.isDeclName)
        let context = popContext()
        guard let nominal = createType(createWithChildren(kind, context, name)) else { return nil }
        addSubstitution(nominal)
        return nominal
    }

    mutating func demangleExtensionContext() -> B.Node? {
        let genSig = popNode(.DependentGenericSignature)
        let module = popModule()
        let type = popTypeAndGetAnyGeneric()
        var ext = createWithChildren(.Extension, module, type)
        if let genSig { ext = addChild(ext, genSig) }
        return ext
    }

    mutating func demanglePlainFunction() -> B.Node? {
        let genSig = popNode(.DependentGenericSignature)
        var type = popFunctionType(.FunctionType)
        let labelList = popFunctionParamLabels(type)
        if let genSig {
            type = createType(createWithChildren(.DependentGenericType, genSig, type))
        }
        let name = popNode(DemanglerPredicates.isDeclName)
        let context = popContext()
        let result = labelList != nil
            ? createWithChildren(.Function, context, name, labelList, type)
            : createWithChildren(.Function, context, name, type)
        return setParentForOpaqueReturnTypeNodes(result: result, type: type)
    }

    // MARK: Opaque-return-type parenting

    mutating func setParentForOpaqueReturnTypeNodes(result rNode: B.Node?, type tNode: B.Node?) -> B.Node? {
        // `createdOpaqueReturnType` is a cheap pre-filter: no opaque node was
        // produced ⇒ the subtree provably has none, so skip the recursive scan.
        // The scan runs on the builder seam, and so does the *rewrite* (an
        // opaque node actually needing a parent — rare): copy-rewrite the
        // type subtree, then rebuild the entity with that child replaced.
        // Only the parent-ID computation materializes (the `SwiftMangler` is
        // a `SwiftSymbol` consumer) — the old whole-subtree
        // materialize/rewrite/adopt round-trip was the deep-opaque profile's
        // largest allocation source (an alloc pair per node, three times
        // over). The child search is `Node` equality: structural for the
        // value backend (its `firstIndex(of:)` semantics, unchanged), handle
        // identity for the arena — where the type child IS `tNode`'s handle
        // by construction. Byte-equivalence of the two is pinned by the
        // full-corpus differential.
        guard let rNode, let tNode, createdOpaqueReturnType,
              subtreeHasUnparentedOpaque(tNode) else { return rNode }
        guard let parentID = SwiftMangler().mangle(nb.materialize(rNode)) else { return rNode }
        var index = -1
        for i in 0 ..< nb.childCount(of: rNode) where nb.child(of: rNode, at: i) == tNode {
            index = i
            break
        }
        guard index >= 0 else { return rNode }
        let newType = rewriteOpaqueParents(tNode, parentID: parentID)
        var rebuilt = nb.changingKind(rNode, to: nb.kind(of: rNode))
        nb.setChild(of: &rebuilt, at: index, to: newType)
        return rebuilt
    }

    /// The reference scan (`node.children.last?.kind == .OpaqueReturnTypeParent`
    /// probe, entity kinds terminate, any-child recursion) expressed through
    /// the builder's readers — no tree materialization.
    private mutating func subtreeHasUnparentedOpaque(_ node: B.Node) -> Bool {
        if nb.kind(of: node) == .OpaqueReturnType {
            guard let last = nb.lastChild(of: node) else { return true }
            return nb.kind(of: last) != .OpaqueReturnTypeParent
        }
        let kind = nb.kind(of: node)
        if kind == .Function || kind == .Variable || kind == .Subscript {
            return false
        }
        for i in 0 ..< nb.childCount(of: node) where subtreeHasUnparentedOpaque(nb.child(of: node, at: i)) {
            return true
        }
        return false
    }

    /// The copy-rewrite: every node down to the entity-kind frontier is
    /// copied (kind + payload + children, via `changingKind` to its own
    /// kind), unparented opaque nodes gain their `.OpaqueReturnTypeParent`,
    /// and entity-kind subtrees are shared untouched — the exact shape of
    /// the previous `SwiftSymbol` value rewrite, expressed through the
    /// builder so the arena backend never leaves handle space.
    private mutating func rewriteOpaqueParents(_ node: B.Node, parentID: String) -> B.Node {
        let kind = nb.kind(of: node)
        if kind == .OpaqueReturnType {
            if let last = nb.lastChild(of: node), nb.kind(of: last) == .OpaqueReturnTypeParent { return node }
            var copy = nb.changingKind(node, to: kind)
            nb.appendChild(to: &copy, nb.make(kind: .OpaqueReturnTypeParent, name: parentID))
            return copy
        }
        if kind == .Function || kind == .Variable || kind == .Subscript {
            return node
        }
        var copy = nb.changingKind(node, to: kind)
        for i in 0 ..< nb.childCount(of: copy) {
            nb.setChild(of: &copy, at: i, to: rewriteOpaqueParents(nb.child(of: copy, at: i), parentID: parentID))
        }
        return copy
    }

    // MARK: Function types

    mutating func popFunctionType(_ kind: SwiftSymbol.Kind, hasClangType: Bool = false) -> B.Node? {
        // Children collect in the engine's scratch region (mark/truncate
        // nested, apple's factory-allocated vector) instead of a per-call
        // `[B.Node]` — the last per-symbol heap temporary on the common
        // function-symbol path.
        let mark = stacks.scratchCount
        defer { stacks.truncateScratch(to: mark) }
        if hasClangType, let ct = demangleClangType() { stacks.appendScratch(ct) }
        if let n = popNode(.SendingResultFunctionType) { stacks.appendScratch(n) }
        if let n = popNode({
            $0 == .GlobalActorFunctionType || $0 == .IsolatedAnyFunctionType || $0 == .NonIsolatedCallerFunctionType
        }) { stacks.appendScratch(n) }
        if let n = popNode(.DifferentiableFunctionType) { stacks.appendScratch(n) }
        if let n = popNode({ $0 == .ThrowsAnnotation || $0 == .TypedThrowsAnnotation }) { stacks.appendScratch(n) }
        if let n = popNode(.ConcurrentFunctionType) { stacks.appendScratch(n) }
        if let n = popNode(.AsyncAnnotation) { stacks.appendScratch(n) }
        guard let params = popFunctionParams(.ArgumentTuple) else { return nil }
        stacks.appendScratch(params)
        guard let result = popFunctionParams(.ReturnType) else { return nil }
        stacks.appendScratch(result)
        let function = stacks.withScratch(from: mark) { nb.make(kind: kind, children: $0) }
        return createType(function)
    }

    mutating func popFunctionParams(_ kind: SwiftSymbol.Kind) -> B.Node? {
        let paramsType: B.Node? = if popNode(.EmptyList) != nil {
            createType(nb.make(kind: .Tuple))
        } else {
            popNode(.`Type`)
        }
        return createWithChild(kind, paramsType)
    }

    mutating func popFunctionParamLabels(_ type: B.Node?) -> B.Node? {
        if !isOldFunctionTypeMangling, popNode(.EmptyList) != nil {
            return nb.make(kind: .LabelList)
        }
        guard let type, nb.kind(of: type) == .`Type`, var funcType = nb.firstChild(of: type) else { return nil }
        if nb.kind(of: funcType) == .DependentGenericType {
            guard nb.childCount(of: funcType) > 1, let inner = nb.firstChild(of: nb.child(of: funcType, at: 1)) else { return nil }
            funcType = inner
        }
        guard nb.kind(of: funcType) == .FunctionType || nb.kind(of: funcType) == .NoEscapeFunctionType else { return nil }

        var firstChildIdx = 0
        let skippable: [SwiftSymbol.Kind] = [
            .SendingResultFunctionType, .GlobalActorFunctionType, .IsolatedAnyFunctionType,
            .NonIsolatedCallerFunctionType, .DifferentiableFunctionType,
        ]
        for skip in skippable where firstChildIdx < nb.childCount(of: funcType)
            && nb.kind(of: nb.child(of: funcType, at: firstChildIdx)) == skip
        {
            firstChildIdx += 1
        }
        if firstChildIdx < nb.childCount(of: funcType),
           nb.kind(of: nb.child(of: funcType, at: firstChildIdx)) == .ThrowsAnnotation
           || nb.kind(of: nb.child(of: funcType, at: firstChildIdx)) == .TypedThrowsAnnotation
        {
            firstChildIdx += 1
        }
        if firstChildIdx < nb.childCount(of: funcType),
           nb.kind(of: nb.child(of: funcType, at: firstChildIdx)) == .ConcurrentFunctionType { firstChildIdx += 1 }
        if firstChildIdx < nb.childCount(of: funcType),
           nb.kind(of: nb.child(of: funcType, at: firstChildIdx)) == .AsyncAnnotation { firstChildIdx += 1 }
        guard firstChildIdx < nb.childCount(of: funcType) else { return nil }
        let parameterType = nb.child(of: funcType, at: firstChildIdx)
        guard nb.kind(of: parameterType) == .ArgumentTuple, let paramsType = nb.firstChild(of: parameterType),
              nb.kind(of: paramsType) == .`Type`, let params = nb.firstChild(of: paramsType)
        else { return nil }
        let numParams = nb.kind(of: params) == .Tuple ? nb.childCount(of: params) : 1
        if numParams == 0 { return nil }

        if isOldFunctionTypeMangling {
            // Old-style: labels are part of the argument tuple — not exercised by
            // the new-mangling corpus; emit an empty label list.
            return nb.make(kind: .LabelList)
        }

        var labelList = nb.make(kind: .LabelList)
        var hasLabels = false
        for _ in 0 ..< numParams {
            guard let label = popNode() else { return nil }
            guard nb.kind(of: label) == .Identifier || nb.kind(of: label) == .FirstElementMarker else { return nil }
            nb.appendChild(to: &labelList, label)
            if nb.kind(of: label) != .FirstElementMarker { hasLabels = true }
        }
        if !hasLabels { return nb.make(kind: .LabelList) }
        nb.reverseChildren(of: &labelList)
        return labelList
    }

    // MARK: Aggregate poppers

    /// `makeElement` receives the demangler `inout` rather than capturing it:
    /// a struct `self` cannot be captured mutably while `popList` itself holds
    /// the exclusive access (the class form captured by reference).
    private mutating func popList(_ rootKind: SwiftSymbol.Kind, makeElement: (inout Demangler<B>) -> B.Node?) -> B.Node? {
        var root = nb.make(kind: rootKind)
        if popNode(.EmptyList) == nil {
            var firstElem = false
            repeat {
                firstElem = popNode(.FirstElementMarker) != nil
                guard let element = makeElement(&self) else { return nil }
                nb.appendChild(to: &root, element)
            } while !firstElem
            nb.reverseChildren(of: &root)
        }
        return root
    }

    mutating func popTuple() -> B.Node? {
        guard popNode(.EmptyList) == nil else {
            return createType(nb.make(kind: .Tuple))
        }
        // Collect the elements in the engine scratch region (mark/append/
        // truncate, apple's factory-allocated vector) and assemble the tuple
        // with ONE `make(kind:children:)`, rather than appending each element
        // to `root` as it is built. Building a `TupleElement`'s own children
        // bumps the shared arena child pool past `root`'s run, so a per-turn
        // `appendChild(to: &root, …)` would relocate `root`'s entire child run
        // every iteration — O(n²) on a wide tuple (a 40k-element tuple copied
        // ~800M handles). One contiguous assembly is O(n). Byte-identical: the
        // elements collect in popped (reverse) order and the single
        // `reverseChildren` restores source order, exactly as the former
        // append-then-reverse did; the value backend is unchanged (its append
        // was already O(1) amortized).
        let mark = stacks.scratchCount
        defer { stacks.truncateScratch(to: mark) }
        var firstElem = false
        repeat {
            firstElem = popNode(.FirstElementMarker) != nil
            var element = nb.make(kind: .TupleElement)
            if let variadic = popNode(.VariadicMarker) { nb.appendChild(to: &element, variadic) }
            if let ident = popNode(.Identifier), let text = nb.text(of: ident) {
                nb.appendChild(to: &element, nb.make(kind: .TupleElementName, name: text))
            }
            guard let ty = popNode(.`Type`) else { return nil }
            nb.appendChild(to: &element, ty)
            stacks.appendScratch(element)
        } while !firstElem
        var root = stacks.withScratch(from: mark) { nb.make(kind: .Tuple, children: $0) }
        nb.reverseChildren(of: &root)
        return createType(root)
    }

    mutating func popPack() -> B.Node? {
        guard let root = popList(.Pack, makeElement: { $0.popNode(.`Type`) }) else { return nil }
        return createType(root)
    }

    mutating func popSILPack() -> B.Node? {
        let rootKind: SwiftSymbol.Kind
        switch nextChar() {
        case 0x64: rootKind = .SILPackDirect // 'd'
        case 0x69: rootKind = .SILPackIndirect // 'i'
        default: return nil
        }
        guard let root = popList(rootKind, makeElement: { $0.popNode(.`Type`) }) else { return nil }
        return createType(root)
    }

    mutating func popTypeList() -> B.Node? {
        popList(.TypeList, makeElement: { $0.popNode(.`Type`) })
    }

    // MARK: Protocols & conformances

    mutating func popProtocol() -> B.Node? {
        if let type = popNode(.`Type`) {
            guard nb.childCount(of: type) != 0, DemanglerPredicates.isProtocolNode(type, nb) else { return nil }
            return type
        }
        if let symbolic = popNode(.ProtocolSymbolicReference) { return symbolic }
        if let symbolic = popNode(.ObjectiveCProtocolSymbolicReference) { return symbolic }
        let name = popNode(DemanglerPredicates.isDeclName)
        let context = popContext()
        return createType(createWithChildren(.protocolNode, context, name))
    }

    mutating func popAnyProtocolConformanceList() -> B.Node? {
        popList(.AnyProtocolConformanceList, makeElement: { $0.popAnyProtocolConformance() })
    }

    mutating func popAnyProtocolConformance() -> B.Node? {
        popNode {
            switch $0 {
            case .ConcreteProtocolConformance, .PackProtocolConformance,
                 .DependentProtocolConformanceRoot, .DependentProtocolConformanceInherited,
                 .DependentProtocolConformanceAssociated, .DependentProtocolConformanceOpaque:
                true
            default:
                false
            }
        }
    }

    mutating func demangleRetroactiveProtocolConformanceRef() -> B.Node? {
        let module = popModule()
        let proto = popProtocol()
        return createWithChildren(.ProtocolConformanceRefInOtherModule, proto, module)
    }

    mutating func demangleConcreteProtocolConformance() -> B.Node? {
        let conditional = popAnyProtocolConformanceList()
        var conformanceRef = popNode(.ProtocolConformanceRefInTypeModule)
        if conformanceRef == nil { conformanceRef = popNode(.ProtocolConformanceRefInProtocolModule) }
        if conformanceRef == nil { conformanceRef = demangleRetroactiveProtocolConformanceRef() }
        let type = popNode(.`Type`)
        return createWithChildren(.ConcreteProtocolConformance, type, conformanceRef, conditional)
    }

    mutating func demanglePackProtocolConformance() -> B.Node? {
        let patternList = popAnyProtocolConformanceList()
        return createWithChild(.PackProtocolConformance, patternList)
    }

    mutating func popDependentProtocolConformance() -> B.Node? {
        popNode {
            switch $0 {
            case .DependentProtocolConformanceRoot, .DependentProtocolConformanceInherited,
                 .DependentProtocolConformanceAssociated:
                true
            default:
                false
            }
        }
    }

    mutating func demangleDependentProtocolConformanceRoot() -> B.Node? {
        let index = demangleDependentConformanceIndex()
        let proto = popProtocol()
        let dependentType = popNode(.`Type`)
        return createWithChildren(.DependentProtocolConformanceRoot, dependentType, proto, index)
    }

    mutating func demangleDependentProtocolConformanceInherited() -> B.Node? {
        let index = demangleDependentConformanceIndex()
        let proto = popProtocol()
        let nested = popDependentProtocolConformance()
        return createWithChildren(.DependentProtocolConformanceInherited, nested, proto, index)
    }

    mutating func popDependentAssociatedConformance() -> B.Node? {
        let proto = popProtocol()
        let dependentType = popNode(.`Type`)
        return createWithChildren(.DependentAssociatedConformance, dependentType, proto)
    }

    mutating func demangleDependentProtocolConformanceAssociated() -> B.Node? {
        let index = demangleDependentConformanceIndex()
        let associatedConformance = popDependentAssociatedConformance()
        let nested = popDependentProtocolConformance()
        return createWithChildren(.DependentProtocolConformanceAssociated, nested, associatedConformance, index)
    }

    mutating func demangleDependentConformanceIndex() -> B.Node? {
        let index = demangleIndex()
        if index <= 0 { return nil }
        if index == 1 { return nb.make(kind: .UnknownIndex) }
        return nb.make(kind: .Index, index: UInt64(index - 2))
    }

    mutating func demangleDependentProtocolConformanceOpaque() -> B.Node? {
        let type = popNode(.`Type`)
        let conformance = popDependentProtocolConformance()
        return createWithChildren(.DependentProtocolConformanceOpaque, conformance, type)
    }

    mutating func demangleRetroactiveConformance() -> B.Node? {
        let index = demangleIndexAsNode()
        let conformance = popAnyProtocolConformance()
        return createWithChildren(.RetroactiveConformance, index, conformance)
    }

    mutating func popRetroactiveConformances() -> B.Node? {
        var node: B.Node?
        while let conformance = popNode(.RetroactiveConformance) {
            var n = node ?? nb.make(kind: .TypeList)
            nb.appendChild(to: &n, conformance)
            node = n
        }
        if var node {
            nb.reverseChildren(of: &node)
            return node
        }
        return nil
    }

    mutating func popProtocolConformance() -> B.Node? {
        let genSig = popNode(.DependentGenericSignature)
        let module = popModule()
        let proto = popProtocol()
        var type = popNode(.`Type`)
        var ident: B.Node?
        if type == nil {
            ident = popNode(.Identifier)
            type = popNode(.`Type`)
        }
        if let genSig {
            type = createType(createWithChildren(.DependentGenericType, genSig, type))
        }
        var conf = createWithChildren(.ProtocolConformance, type, proto, module)
        if let ident { conf = addChild(conf, ident) }
        return conf
    }

    mutating func popAssociatedConformanceWitnessAccessorSubject() -> B.Node? {
        if let type = popNode(.`Type`) {
            if DemanglerPredicates.isGenericParamType(type, nb) { return type }
            pushNode(type)
        }
        return popAssocTypePath()
    }

    // MARK: Bound generics

    mutating func demangleBoundGenerics() -> (typeLists: [B.Node], retroactive: B.Node?)? {
        let retroactive = popRetroactiveConformances()
        var typeListList: [B.Node] = []
        while true {
            var list = nb.make(kind: .TypeList)
            while let ty = popNode(.`Type`) {
                nb.appendChild(to: &list, ty)
            }
            nb.reverseChildren(of: &list)
            typeListList.append(list)
            if popNode(.EmptyList) != nil { break }
            if popNode(.FirstElementMarker) == nil { return nil }
        }
        return (typeListList, retroactive)
    }

    mutating func demangleBoundGenericType() -> B.Node? {
        guard let (typeListList, retroactive) = demangleBoundGenerics() else { return nil }
        guard let nominal = popTypeAndGetAnyGeneric() else { return nil }
        guard var boundNode = demangleBoundGenericArgs(nominal, typeLists: typeListList, index: 0) else { return nil }
        if let retroactive { nb.appendChild(to: &boundNode, retroactive) }
        guard let nominalType = createType(boundNode) else { return nil }
        addSubstitution(nominalType)
        return nominalType
    }

    mutating func demangleBoundGenericArgs(_ nominal: B.Node, typeLists: [B.Node], index: Int) -> B.Node? {
        if index >= typeLists.count { return nil }

        if nb.kind(of: nominal) == .TypeSymbolicReference || nb.kind(of: nominal) == .ProtocolSymbolicReference {
            var remaining = nb.make(kind: .TypeList)
            var i = typeLists.count - 1
            while i >= index, i < typeLists.count {
                let list = typeLists[i]
                for k in 0 ..< nb.childCount(of: list) {
                    nb.appendChild(to: &remaining, nb.child(of: list, at: k))
                }
                i -= 1
            }
            return createWithChildren(.BoundGenericOtherNominalType, createType(nominal), remaining)
        }

        guard nb.childCount(of: nominal) != 0 else { return nil }
        let context = nb.child(of: nominal, at: 0)
        let consumes = DemanglerPredicates.nodeConsumesGenericArgs(nb.kind(of: nominal))
        let args = typeLists[index]
        var typeListIdx = index
        if consumes { typeListIdx += 1 }

        var workingNominal = nominal
        if typeListIdx < typeLists.count {
            let boundParent: B.Node?
            if nb.kind(of: context) == .Extension {
                guard nb.childCount(of: context) >= 2,
                      let inner = demangleBoundGenericArgs(nb.child(of: context, at: 1), typeLists: typeLists, index: typeListIdx)
                else { return nil }
                var ext = createWithChildren(.Extension, nb.firstChild(of: context), inner)
                if nb.childCount(of: context) == 3 { ext = addChild(ext, nb.child(of: context, at: 2)) }
                boundParent = ext
            } else {
                boundParent = demangleBoundGenericArgs(context, typeLists: typeLists, index: typeListIdx)
            }
            guard var newNominal = createWithChild(nb.kind(of: nominal), boundParent) else { return nil }
            for idx in 1 ..< nb.childCount(of: nominal) {
                nb.appendChild(to: &newNominal, nb.child(of: nominal, at: idx))
            }
            workingNominal = newNominal
        }
        if !consumes { return workingNominal }
        if nb.childCount(of: args) == 0 { return workingNominal }

        let kind: SwiftSymbol.Kind
        switch nb.kind(of: workingNominal) {
        case .Class: kind = .BoundGenericClass
        case .Structure: kind = .BoundGenericStructure
        case .Enum: kind = .BoundGenericEnum
        case .protocolNode: kind = .BoundGenericProtocol
        case .OtherNominalType: kind = .BoundGenericOtherNominalType
        case .TypeAlias: kind = .BoundGenericTypeAlias
        case .Function, .Constructor:
            return createWithChildren(.BoundGenericFunction, workingNominal, args)
        default:
            return nil
        }
        return createWithChildren(kind, createType(workingNominal), args)
    }

    // MARK: Generic param index

    mutating func getDependentGenericParamType(depth: Int, index: Int) -> B.Node? {
        if depth < 0 || index < 0 { return nil }
        return nb.make(kind: .DependentGenericParamType, children: [
            nb.make(kind: .Index, index: UInt64(depth)),
            nb.make(kind: .Index, index: UInt64(index)),
        ])
    }

    mutating func demangleGenericParamIndex() -> B.Node? {
        if nextIf(0x64) { // 'd'
            let depth = demangleIndex() + 1
            let index = demangleIndex()
            return getDependentGenericParamType(depth: depth, index: index)
        }
        if nextIf(0x7A) { // 'z'
            return getDependentGenericParamType(depth: 0, index: 0)
        }
        if nextIf(0x73) { // 's'
            return nb.make(kind: .ConstrainedExistentialSelf)
        }
        return getDependentGenericParamType(depth: 0, index: demangleIndex() + 1)
    }

    // MARK: Clang type

    mutating func demangleClangType() -> B.Node? {
        let numChars = demangleNatural()
        guard numChars > 0, pos + numChars <= textEnd else { return nil }
        let slice = Array(text[pos ..< pos + numChars])
        pos += numChars
        return nb.make(kind: .ClangType, name: String(decoding: slice, as: UTF8.self))
    }

    // MARK: Integer types

    mutating func demangleIntegerType() -> B.Node? {
        let integer: B.Node?
        if peekChar() == 0x6E { // 'n'
            pos += 1
            let value = demangleIndex()
            guard value >= 0 else { return nil }
            integer = nb.make(kind: .NegativeInteger, index: UInt64(bitPattern: Int64(-value)))
        } else {
            let value = demangleIndex()
            guard value >= 0 else { return nil }
            integer = nb.make(kind: .Integer, index: UInt64(value))
        }
        return createType(integer)
    }

    // MARK: Metatype representation & existential shapes

    mutating func demangleMetatypeRepresentation() -> B.Node? {
        switch nextChar() {
        case 0x74: nb.make(kind: .MetatypeRepresentation, name: "@thin") // 't'
        case 0x54: nb.make(kind: .MetatypeRepresentation, name: "@thick") // 'T'
        case 0x6F: nb.make(kind: .MetatypeRepresentation, name: "@objc_metatype") // 'o'
        default: nil
        }
    }

    mutating func demangleExtendedExistentialShape(_ nodeKind: UInt8) -> B.Node? {
        let type = popNode(.`Type`)
        var genSig: B.Node?
        if nodeKind == 0x47 { genSig = popNode(.DependentGenericSignature) } // 'G'
        if let genSig {
            return createWithChildren(.ExtendedExistentialTypeShape, genSig, type)
        }
        return createWithChild(.ExtendedExistentialTypeShape, type)
    }

    mutating func demangleSymbolicExtendedExistentialType() -> B.Node? {
        let retroactive = popRetroactiveConformances()
        var args = nb.make(kind: .TypeList)
        while let ty = popNode(.`Type`) {
            nb.appendChild(to: &args, ty)
        }
        nb.reverseChildren(of: &args)
        guard let shape = popNode() else { return nil }
        guard nb.kind(of: shape) == .UniqueExtendedExistentialTypeShapeSymbolicReference
            || nb.kind(of: shape) == .NonUniqueExtendedExistentialTypeShapeSymbolicReference
        else { return nil }
        let existential: B.Node? = if let retroactive {
            createWithChildren(.SymbolicExtendedExistentialType, shape, args, retroactive)
        } else {
            createWithChildren(.SymbolicExtendedExistentialType, shape, args)
        }
        return createType(existential)
    }
}
