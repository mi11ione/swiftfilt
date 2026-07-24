// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// The mutable parse state and algorithm for the current (`$s`-era) Swift
/// mangling — a faithful port of apple/swift's `Demangler` in
/// `lib/Demangling/Demangler.cpp`. It is a postfix stack machine: each
/// operator pops its operands off the node stack and pushes the node it builds.
///
/// Generic over a ``NodeBuilder``: every node is created, read, and assembled
/// through `nb`, so the same body drives the public ``SwiftSymbol`` tree today
/// and can drive a bump-arena node in a later stage. The one instantiation this
/// stage ships, `Demangler<SwiftSymbolBuilder>`, monomorphizes to the
/// pre-abstraction engine with the builder calls inlined away.
///
/// A noncopyable value type: the parse is inherently stateful (a moving
/// cursor, a node stack, a substitution list), and holding that state in a
/// struct puts it a constant offset from a register-resident `self` with no
/// class instance to heap-allocate per parse and no dynamic-exclusivity
/// bookkeeping on any mutation (the class form needed `@exclusivity(unchecked)`
/// on every property to claw those access pairs back). `~Copyable` because
/// ``stacks`` owns raw slab memory the deinit releases — a copy would
/// double-free; ownership moves (the public ``SwiftDemangler`` spins up one
/// `Demangler` per call, the batch engines shuttle storage through one).
/// Methods are split across extension files by grammar area. Every builder
/// is null-propagating, so any malformed input collapses to `nil`.
struct Demangler<B: NodeBuilder>: ~Copyable {
    /// The node builder every structural operation routes through.
    let nb: B
    /// Immutable per instance: `let` lets the optimizer treat every byte read
    /// as loop-invariant across the parse (making this a `var` for in-place
    /// reset measured −2.4% on the stream benchmark). Batch reuse instead
    /// re-parses *windows* of one immutable buffer — apple's `StringRef`
    /// slice model — via ``reset(range:)``.
    let text: [UInt8]
    /// The parse window: the engine reads `text[textStart ..< textEnd]`. The
    /// whole buffer for a one-shot parse; a candidate's byte range when the
    /// scanner re-windows one demangler over a log buffer. All recorded
    /// indices (words, identifier slices, `pos`) are absolute into `text`,
    /// so windowing changes only the two bounds.
    var textStart = 0
    var textEnd: Int
    var pos = 0
    /// The node stack, substitution list, and word-harvest ranges (ranges
    /// into ``text``, as the reference demangler's `StringRef` words — no
    /// copies), packed as regions of one slab — see ``EngineStacks``.
    var stacks: EngineStacks<B.Node>
    var flavor: SwiftManglingFlavor = .standard
    var isOldFunctionTypeMangling = false
    /// Set when any `.OpaqueReturnType` node is created (the `Qr`/`QR`
    /// productions in `demangleArchetype`). `setParentForOpaqueReturnTypeNodes`
    /// gates its per-entity subtree scan on this: the reference demangler only
    /// parents opaque nodes it actually produced, so the common case (no opaque
    /// return type — nearly every symbol) skips the recursive walk entirely
    /// (profile: `subtreeHasUnparentedOpaque` ran on every function/var/subscript).
    var createdOpaqueReturnType = false
    var baseAddress: UInt64 = 0
    var symbolicReferenceResolver: SymbolicReferenceResolver?
    /// Set when any pushed node is deep enough that its drop should be
    /// routed (`NodeBuilder.needsRoutedRelease`) — the nil exits then drain
    /// the parse regions through ``drainStacksRouted()`` instead of letting
    /// the ordinary region teardown recurse a deep tree's depth. Never set
    /// for the arena backend (its releases are trivial).
    var sawDeepNode = false

    init(text: [UInt8], nb: B) {
        self.text = text
        textEnd = text.count
        self.nb = nb
        // The slab's node/substitution slots are parse-warm (capacity 16),
        // so the first appends stay off the growth path.
        stacks = .allocated()
    }

    /// Construct taking the (warm) parse stacks out of `storage` — the
    /// engine-reuse seam: an `ArenaDemangleEngine` shuttles ONE
    /// ``EngineStacks`` slab between its per-call demanglers, so a
    /// session's steady-state call allocates no engine storage at all
    /// (profiled: the per-call stack reservations and the first word
    /// appends were most of a session call's remaining allocations). The
    /// shuttle is one struct swap — no copy, no element traffic — and the
    /// taken stacks are rewound (capacity kept, slab allocated on the very
    /// first take) before parsing, so a parse sees exactly the state a
    /// fresh demangler sees; ``giveBack(_:)`` returns them when the
    /// parse's results are no longer referenced. Byte-identical behavior
    /// is pinned by the differential's session-vs-one-shot leg over the
    /// full corpus.
    init(text: [UInt8], nb: B, taking storage: inout EngineStacks<B.Node>) {
        self.text = text
        textEnd = text.count
        self.nb = nb
        stacks = EngineStacks()
        swap(&stacks, &storage)
        stacks.prepareForParse()
    }

    deinit {
        // `deinit` of a noncopyable struct cannot mutate `self`; destroy
        // through a local copy of the (plain-struct) stacks value — same
        // pointers, and the stored copy dies with `self` right after.
        var stacks = self.stacks
        stacks.destroy()
    }

    /// Return the shuttled stacks to `storage` (see the taking
    /// initializer). The demangler must not parse again afterwards.
    mutating func giveBack(_ storage: inout EngineStacks<B.Node>) {
        swap(&stacks, &storage)
    }

    /// Rewind every piece of parse state for another parse over
    /// `text[range]` — the batch scanner re-windows ONE demangler across a
    /// log buffer's candidates, so a candidate costs no engine allocation
    /// and no byte copy. `text` itself never changes (its immutability is
    /// the hot path's loop-invariance); everything else resets. The stored
    /// properties above are the complete state — extensions cannot add
    /// storage — and reused-window behavior is pinned byte-for-byte against
    /// the fresh-engine path by the differential's session leg and the
    /// scanner corpus legs.
    mutating func reset(range: Range<Int>) {
        textStart = range.lowerBound
        textEnd = range.upperBound
        pos = range.lowerBound
        stacks.removeAll()
        flavor = .standard
        isOldFunctionTypeMangling = false
        createdOpaqueReturnType = false
        baseAddress = 0
        symbolicReferenceResolver = nil
        sawDeepNode = false
    }

    // MARK: Cursor

    @inline(__always)
    func peekChar() -> UInt8 {
        pos < textEnd ? text[pos] : 0
    }

    @inline(__always)
    mutating func nextChar() -> UInt8 {
        let c = peekChar()
        pos += 1
        return c
    }

    @inline(__always)
    mutating func pushBack() {
        pos -= 1
    }

    @inline(__always)
    mutating func nextIf(_ c: UInt8) -> Bool {
        if peekChar() != c { return false }
        pos += 1
        return true
    }

    mutating func nextIf(_ s: [UInt8]) -> Bool {
        guard pos + s.count <= textEnd else { return false }
        for (i, byte) in s.enumerated() where text[pos + i] != byte {
            return false
        }
        pos += s.count
        return true
    }

    /// Consume the rest of the window as a UTF-8 string (the unmangled suffix).
    mutating func consumeAll() -> String {
        let slice = pos < textEnd ? text[pos ..< textEnd] : []
        pos = textEnd
        return String(decoding: slice, as: UTF8.self)
    }

    /// Whether the parse window begins with `prefix` — the windowed
    /// `text.starts(with:)`.
    @inline(__always)
    func windowStarts(with prefix: [UInt8]) -> Bool {
        guard textStart + prefix.count <= textEnd else { return false }
        for (i, byte) in prefix.enumerated() where text[textStart + i] != byte {
            return false
        }
        return true
    }

    // MARK: Node stack

    @inline(__always)
    mutating func pushNode(_ node: B.Node) {
        if nb.needsRoutedRelease(node) { sawDeepNode = true }
        stacks.pushNode(node)
    }

    @inline(__always)
    mutating func popNode() -> B.Node? {
        stacks.popNode()
    }

    @inline(__always)
    mutating func popNode(_ kind: SwiftSymbol.Kind) -> B.Node? {
        // Peek the top through the region pointer and read its kind in place
        // — a by-value peek would retain/release the `SwiftSymbol` backend's
        // heap storage on every (very frequent) pop-probe; the borrowing
        // read avoids it.
        guard let top = stacks.lastNodePointer, nb.kind(of: top.pointee) == kind else { return nil }
        return stacks.removeLastNode()
    }

    @inline(__always)
    mutating func popNode(_ predicate: (SwiftSymbol.Kind) -> Bool) -> B.Node? {
        guard let top = stacks.lastNodePointer, predicate(nb.kind(of: top.pointee)) else { return nil }
        return stacks.removeLastNode()
    }

    mutating func addSubstitution(_ node: B.Node?) {
        if let node { stacks.appendSub(node) }
    }

    // MARK: Numbers / indices

    mutating func demangleNatural() -> Int {
        if !ManglingChars.isDigit(peekChar()) { return -1000 }
        var num = 0
        while true {
            let c = peekChar()
            if !ManglingChars.isDigit(c) { return num }
            let newNum = (10 &* num) &+ Int(c - 0x30)
            if newNum < num { return -1000 }
            num = newNum
            pos += 1
        }
    }

    mutating func demangleIndex() -> Int {
        if nextIf(0x5F) { return 0 } // '_'
        let num = demangleNatural()
        if num >= 0, nextIf(0x5F) { return num + 1 }
        return -1000
    }

    @inline(__always)
    mutating func demangleIndexAsNode() -> B.Node? {
        let idx = demangleIndex()
        return idx >= 0 ? nb.make(kind: .Number, index: UInt64(idx)) : nil
    }

    // MARK: Node builders (null-propagating)

    // These per-node wrappers were plain (un-annotated) functions the optimizer
    // freely inlined when the engine was concrete. Made generic, they specialize
    // per builder but the specialized bodies inline less eagerly into their many
    // call sites — enough to show on the demangle profile. `@inline(__always)`
    // restores the pre-abstraction inlining, so `Demangler<SwiftSymbolBuilder>`
    // is the pre-abstraction code (verified perf-neutral by the benchmark).

    @inline(__always)
    func createType(_ child: B.Node?) -> B.Node? {
        createWithChild(.`Type`, child)
    }

    @inline(__always)
    func createWithChild(_ kind: SwiftSymbol.Kind, _ child: B.Node?) -> B.Node? {
        guard let child, !nb.isDepthPoisoned(child) else { return nil }
        return nb.make(kind: kind, child: child)
    }

    /// The node builders take a fixed number of children — every call site in the
    /// grammar builds two, three, or four. Fixed-arity (rather than a
    /// `Node?...` variadic) avoids the per-call heap allocation of the
    /// variadic argument pack, which Swift materializes as an Array on every call
    /// (measured on the demangle profile as `_ArrayBuffer` churn); the reference
    /// builder's all-or-nothing null propagation is preserved unchanged.
    @inline(__always)
    func createWithChildren(_ kind: SwiftSymbol.Kind, _ c0: B.Node?, _ c1: B.Node?) -> B.Node? {
        guard let c0, let c1, !nb.isDepthPoisoned(c0), !nb.isDepthPoisoned(c1) else { return nil }
        return nb.make(kind: kind, child0: c0, child1: c1)
    }

    @inline(__always)
    func createWithChildren(_ kind: SwiftSymbol.Kind, _ c0: B.Node?, _ c1: B.Node?, _ c2: B.Node?) -> B.Node? {
        guard let c0, let c1, let c2,
              !nb.isDepthPoisoned(c0), !nb.isDepthPoisoned(c1), !nb.isDepthPoisoned(c2)
        else { return nil }
        return nb.make(kind: kind, child0: c0, child1: c1, child2: c2)
    }

    @inline(__always)
    func createWithChildren(_ kind: SwiftSymbol.Kind, _ c0: B.Node?, _ c1: B.Node?, _ c2: B.Node?, _ c3: B.Node?) -> B.Node? {
        guard let c0, let c1, let c2, let c3,
              !nb.isDepthPoisoned(c0), !nb.isDepthPoisoned(c1),
              !nb.isDepthPoisoned(c2), !nb.isDepthPoisoned(c3)
        else { return nil }
        return nb.make(kind: kind, child0: c0, child1: c1, child2: c2, child3: c3)
    }

    /// Append `child` to `parent`, returning the augmented parent — `nil` if
    /// either is `nil` (apple/swift's `addChild` "add or fail").
    @inline(__always)
    func addChild(_ parent: B.Node?, _ child: B.Node?) -> B.Node? {
        guard var parent, let child,
              !nb.isDepthPoisoned(parent), !nb.isDepthPoisoned(child)
        else { return nil }
        nb.appendChild(to: &parent, child)
        return parent
    }

    @inline(__always)
    mutating func createWithPoppedType(_ kind: SwiftSymbol.Kind) -> B.Node? {
        createWithChild(kind, popNode(.`Type`))
    }

    // MARK: Prefix detection — see the non-generic ``DemanglerPrefixes`` below.

    // MARK: Entry points

    @_optimize(speed)
    @_specialize(exported: false, where B == SwiftSymbolBuilder)
    @_specialize(exported: false, where B == ArenaBuilder)
    mutating func demangleSymbol() -> B.Node? {
        // Legacy `_T` mangling (Swift ≤3 functions, and the `_Tt` class /
        // protocol type names still emitted in ObjC metadata). The whole `_T`
        // family routes to the old demangler except the Swift-4.0 `_T0`
        // new-mangling prefix, which the prefix table below handles.
        let isOldPrefix = windowStarts(with: DemanglerPrefixes.oldManglingPrefix)
        if isOldPrefix, !windowStarts(with: DemanglerPrefixes.swift4ManglingPrefix) {
            return demangleOldSymbolAsNode()
        }
        let prefixLength = DemanglerPrefixes.manglingPrefixLength(text, from: textStart, to: textEnd)
        if prefixLength == 0 { return nil }

        if windowStarts(with: DemanglerPrefixes.embeddedPrefix) || windowStarts(with: DemanglerPrefixes.underscoredEmbeddedPrefix) {
            flavor = .embedded
        }
        isOldFunctionTypeMangling = isOldPrefix
        pos += prefixLength

        guard parseAndPushNodes() else { drainRoutedIfNeeded(); return nil }

        var topLevel = nb.make(kind: .Global)
        let suffix = popNode(.Suffix)

        // Function attributes wrap the global; a partial-apply forwarder
        // becomes the new parent for the entity that follows it.
        var parentIsForwarder = false
        var forwarder: B.Node?
        while let attr = popNode(DemanglerPredicates.isFunctionAttr) {
            if nb.kind(of: attr) == .PartialApplyForwarder || nb.kind(of: attr) == .PartialApplyObjCForwarder {
                if parentIsForwarder, var f = forwarder {
                    nb.appendChild(to: &f, attr); forwarder = f
                } else {
                    forwarder = attr
                }
                parentIsForwarder = true
            } else if parentIsForwarder, var f = forwarder {
                nb.appendChild(to: &f, attr); forwarder = f
            } else {
                nb.appendChild(to: &topLevel, attr)
            }
        }
        var entityParent = forwarder
        for i in 0 ..< stacks.nodesCount {
            let node = stacks.node(at: i)
            let child = nb.kind(of: node) == .`Type` ? (nb.firstChild(of: node) ?? node) : node
            if var parent = entityParent {
                nb.appendChild(to: &parent, child); entityParent = parent
            } else {
                nb.appendChild(to: &topLevel, child)
            }
        }
        if let finalForwarder = entityParent {
            nb.appendChild(to: &topLevel, finalForwarder)
        }
        if let suffix { nb.appendChild(to: &topLevel, suffix) }

        if nb.childCount(of: topLevel) == 0 { return nil }
        // Depth ceiling: the builders bound every construction at
        // ``SwiftManglingConstants/maxTreeDepth`` (an over-deep make refuses
        // its children and poisons the node, and the mark propagates through
        // every ancestor), so a tree past the ceiling never exists — this
        // O(1) check is the decline. The old-grammar demangler and the
        // remangler enforce their own (reference) ceilings.
        if nb.isDepthPoisoned(topLevel) { return nil }
        return topLevel
    }

    @_optimize(speed)
    @_specialize(exported: false, where B == SwiftSymbolBuilder)
    @_specialize(exported: false, where B == ArenaBuilder)
    mutating func demangleType() -> B.Node? {
        guard parseAndPushNodes() else { drainRoutedIfNeeded(); return nil }
        guard let result = popNode() else { return nil }
        // Valid only if it was the only node on the stack.
        if popNode() != nil {
            if sawDeepNode {
                var teardown: [B.Node] = [result]
                stacks.drainElements { teardown.append($0) }
                nb.releaseDeep(teardown)
            }
            return nil
        }
        // Depth ceiling — see `demangleSymbol`.
        if nb.isDepthPoisoned(result) { return nil }
        return result
    }

    /// The nil-exit drain: when a parse that built deep (in-ceiling) trees
    /// fails, the regions may hold their last references — route them
    /// through the builder's topological release so the failure never
    /// recurses a tree's depth on the caller's stack.
    @inline(__always)
    mutating func drainRoutedIfNeeded() {
        if !sawDeepNode { return }
        var teardown: [B.Node] = []
        stacks.drainElements { teardown.append($0) }
        nb.releaseDeep(teardown)
    }

    @_optimize(speed)
    @_specialize(exported: false, where B == SwiftSymbolBuilder)
    @_specialize(exported: false, where B == ArenaBuilder)
    mutating func parseAndPushNodes() -> Bool {
        let textSize = textEnd
        while pos < textSize {
            // Tolerate a NUL where an operator is expected (over-length lookups).
            if peekChar() == 0 { return true }
            guard let node = demangleOperator() else { return false }
            // Depth ceiling: a poisoned node fails the parse right here, the
            // same all-or-nothing null propagation as any malformed input —
            // never a partially-built tree presented as a demangling.
            if nb.isDepthPoisoned(node) { return false }
            pushNode(node)
        }
        return true
    }

    mutating func demangleTypeMangling() -> B.Node? {
        let type = popNode(.`Type`)
        let labelList = popFunctionParamLabels(type)
        var typeMangling = nb.make(kind: .TypeMangling)
        if let labelList { nb.appendChild(to: &typeMangling, labelList) }
        return addChild(typeMangling, type)
    }

    mutating func demangleSymbolicReference(_ rawKind: UInt8) -> B.Node? {
        guard pos + 4 <= textEnd else { return nil }
        let v = UInt32(text[pos]) | (UInt32(text[pos + 1]) << 8)
            | (UInt32(text[pos + 2]) << 16) | (UInt32(text[pos + 3]) << 24)
        let value = Int(Int32(bitPattern: v))
        let referenceAddress = baseAddress &+ UInt64(pos)
        pos += 4

        let kind: SymbolicReferenceKind
        let directness: SymbolicReferenceDirectness
        switch rawKind {
        case 0x01: kind = .context; directness = .direct
        case 0x02: kind = .context; directness = .indirect
        case 0x09: kind = .accessorFunctionReference; directness = .direct
        case 0x0A: kind = .uniqueExtendedExistentialTypeShape; directness = .direct
        case 0x0B: kind = .nonUniqueExtendedExistentialTypeShape; directness = .direct
        case 0x0C: kind = .objectiveCProtocol; directness = .direct
        default: return nil // 0x03–0x08 reserved/unimplemented
        }

        guard let resolver = symbolicReferenceResolver,
              let resolved = resolver(kind, directness, value, referenceAddress)
        else { return nil }

        // The resolver hands back a public `SwiftSymbol`; bring it into the
        // builder's node space once and reuse it for both the substitution
        // record and the returned node.
        let node = nb.adopt(resolved)
        if kind == .context || kind == .objectiveCProtocol,
           resolved.kind != .OpaqueTypeDescriptorSymbolicReference,
           resolved.kind != .OpaqueReturnTypeOf
        {
            addSubstitution(node)
        }
        return node
    }

    mutating func demangleTypeAnnotation() -> B.Node? {
        switch nextChar() {
        case 0x61: nb.make(kind: .AsyncAnnotation) // 'a'
        case 0x41: nb.make(kind: .IsolatedAnyFunctionType) // 'A'
        case 0x62: nb.make(kind: .ConcurrentFunctionType) // 'b'
        case 0x63: createWithChild(.GlobalActorFunctionType, popTypeAndGetChild()) // 'c'
        case 0x43: nb.make(kind: .NonIsolatedCallerFunctionType) // 'C'
        case 0x69: createType(createWithChild(.Isolated, popTypeAndGetChild())) // 'i'
        case 0x6A: demangleDifferentiableFunctionType() // 'j'
        case 0x6B: createType(createWithChild(.NoDerivative, popTypeAndGetChild())) // 'k'
        case 0x4B: createWithChild(.TypedThrowsAnnotation, popTypeAndGetChild()) // 'K'
        case 0x74: createType(createWithChild(.CompileTimeLiteral, popTypeAndGetChild())) // 't'
        case 0x67: createType(createWithChild(.ConstValue, popTypeAndGetChild())) // 'g'
        case 0x54: nb.make(kind: .SendingResultFunctionType) // 'T'
        case 0x75: createType(createWithChild(.Sending, popTypeAndGetChild())) // 'u'
        default: nil
        }
    }

    // MARK: Top-level dispatch

    @_optimize(speed)
    @_specialize(exported: false, where B == SwiftSymbolBuilder)
    @_specialize(exported: false, where B == ArenaBuilder)
    mutating func demangleOperator() -> B.Node? {
        while true {
            let c = nextChar()
            switch c {
            case 0xFF:
                continue // alignment padding for symbolic references
            case 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0A, 0x0B, 0x0C:
                return demangleSymbolicReference(c)
            case 0x41: return demangleMultiSubstitutions() // 'A'
            case 0x42: return demangleBuiltinType() // 'B'
            case 0x43: return demangleAnyGenericType(.Class) // 'C'
            case 0x44: return demangleTypeMangling() // 'D'
            case 0x45: return demangleExtensionContext() // 'E'
            case 0x46: return demanglePlainFunction() // 'F'
            case 0x47: return demangleBoundGenericType() // 'G'
            case 0x48: return demangleHOperator() // 'H'
            case 0x49: return demangleImplFunctionType() // 'I'
            case 0x4B: return nb.make(kind: .ThrowsAnnotation) // 'K'
            case 0x4C: return demangleLocalIdentifier() // 'L'
            case 0x4D: return demangleMetatype() // 'M'
            case 0x4E: return createWithChild(.TypeMetadata, popNode(.`Type`)) // 'N'
            case 0x4F: return demangleAnyGenericType(.Enum) // 'O'
            case 0x50: return demangleAnyGenericType(.protocolNode) // 'P'
            case 0x51: return demangleArchetype() // 'Q'
            case 0x52: return demangleGenericRequirement() // 'R'
            case 0x53: return demangleStandardSubstitution() // 'S'
            case 0x54: return demangleThunkOrSpecialization() // 'T'
            case 0x56: return demangleAnyGenericType(.Structure) // 'V'
            case 0x57: return demangleWitness() // 'W'
            case 0x58: return demangleSpecialType() // 'X'
            case 0x59: return demangleTypeAnnotation() // 'Y'
            case 0x5A: return createWithChild(.Static, popNode(DemanglerPredicates.isEntity)) // 'Z'
            case 0x61: return demangleAnyGenericType(.TypeAlias) // 'a'
            case 0x63: return popFunctionType(.FunctionType) // 'c'
            case 0x64: return nb.make(kind: .VariadicMarker) // 'd'
            case 0x66: return demangleFunctionEntity() // 'f'
            case 0x67: return demangleRetroactiveConformance() // 'g'
            case 0x68: return createType(createWithChild(.Shared, popTypeAndGetChild())) // 'h'
            case 0x69: return demangleSubscript() // 'i'
            case 0x6C: return demangleGenericSignature(hasParamCounts: false) // 'l'
            case 0x6D: return createType(createWithChild(.Metatype, popNode(.`Type`))) // 'm'
            case 0x6E: return createType(createWithChild(.Owned, popTypeAndGetChild())) // 'n'
            case 0x6F: return demangleOperatorIdentifier() // 'o'
            case 0x70: return demangleProtocolListType() // 'p'
            case 0x71: return createType(demangleGenericParamIndex()) // 'q'
            case 0x72: return demangleGenericSignature(hasParamCounts: true) // 'r'
            case 0x73: return nb.make(kind: .Module, name: SwiftManglingConstants.stdlibName) // 's'
            case 0x74: return popTuple() // 't'
            case 0x75: return demangleGenericType() // 'u'
            case 0x76: return demangleVariable() // 'v'
            case 0x77: return demangleValueWitness() // 'w'
            case 0x78: return createType(getDependentGenericParamType(depth: 0, index: 0)) // 'x'
            case 0x79: return nb.make(kind: .EmptyList) // 'y'
            case 0x7A: return createType(createWithChild(.InOut, popTypeAndGetChild())) // 'z'
            case 0x5F: return nb.make(kind: .FirstElementMarker) // '_'
            case 0x2E: // '.'
                pushBack()
                return nb.make(kind: .Suffix, name: consumeAll())
            case 0x24: return demangleIntegerType() // '$'
            default:
                pushBack()
                return demangleIdentifier()
            }
        }
    }

    private mutating func demangleHOperator() -> B.Node? {
        switch nextChar() {
        case 0x41: return demangleDependentProtocolConformanceAssociated() // 'A'
        case 0x43: return demangleConcreteProtocolConformance() // 'C'
        case 0x44: return demangleDependentProtocolConformanceRoot() // 'D'
        case 0x49: return demangleDependentProtocolConformanceInherited() // 'I'
        case 0x4F: return demangleDependentProtocolConformanceOpaque() // 'O'
        case 0x50: return createWithChild(.ProtocolConformanceRefInTypeModule, popProtocol()) // 'P'
        case 0x70: return createWithChild(.ProtocolConformanceRefInProtocolModule, popProtocol()) // 'p'
        case 0x58: return demanglePackProtocolConformance() // 'X'
        case 0x63: return createWithChild(.ProtocolConformanceDescriptorRecord, popProtocolConformance()) // 'c'
        case 0x6E: return createWithPoppedType(.NominalTypeDescriptorRecord) // 'n'
        case 0x6F: return createWithChild(.OpaqueTypeDescriptorRecord, popNode()) // 'o'
        case 0x72: return createWithChild(.ProtocolDescriptorRecord, popProtocol()) // 'r'
        case 0x46: return nb.make(kind: .AccessibleFunctionRecord) // 'F'
        default:
            pushBack()
            pushBack()
            return demangleIdentifier()
        }
    }
}

/// The mangling-prefix byte tables and prefix-length probe, factored out of the
/// generic ``Demangler`` because Swift forbids `static` stored properties in a
/// generic type — and building these arrays per call is exactly the churn the
/// reference-matching engine hoists away (profile: `manglingPrefixLength` on the
/// malloc/free path). A non-generic namespace keeps them allocated once and lets
/// ``SwiftSymbolClassifier`` probe a name without naming a builder type.
enum DemanglerPrefixes {
    /// Every current-era mangling prefix, with and without the Mach-O
    /// leading underscore, in first-match order.
    private static let prefixes: [[UInt8]] = [
        Array("_T0".utf8),
        Array("$S".utf8), Array("_$S".utf8),
        Array("$s".utf8), Array("_$s".utf8),
        Array("$e".utf8), Array("_$e".utf8),
        Array("@__swiftmacro_".utf8),
    ]

    static let oldManglingPrefix = Array("_T".utf8)
    static let swift4ManglingPrefix = Array("_T0".utf8)
    static let embeddedPrefix = Array("$e".utf8)
    static let underscoredEmbeddedPrefix = Array("_$e".utf8)

    static func manglingPrefixLength(_ text: [UInt8]) -> Int {
        manglingPrefixLength(text, from: 0, to: text.count)
    }

    /// Windowed variant: probe the prefix table at `text[from ..< to]` — the
    /// scanner re-windows one demangler over a log buffer, so the prefix test
    /// must respect the candidate's bounds, not the buffer's.
    static func manglingPrefixLength(_ text: [UInt8], from: Int, to: Int) -> Int {
        for prefix in prefixes {
            let count = prefix.count
            guard from + count <= to else { continue }
            var matches = true
            for i in 0 ..< count where text[from + i] != prefix[i] {
                matches = false
                break
            }
            if matches { return count }
        }
        return 0
    }
}
