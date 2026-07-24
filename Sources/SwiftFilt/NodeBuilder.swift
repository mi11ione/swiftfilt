// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// The node-access seam the modern demangler and node-printer are written
/// against, so the same one apple-traceable logic body can build (and read)
/// either the public ``SwiftSymbol`` tree or, in a later stage, a bump-arena
/// representation — with no change to this protocol.
///
/// The abstraction point is the associated ``Node``: a bare handle the engine
/// passes around and never inspects directly. Every structural operation the
/// grammar and printer need — creation, reading, in-place assembly, and the two
/// `SwiftSymbol`-boundary conversions — routes through the builder, so `Node`
/// can be a value that carries its own storage (``SwiftSymbolBuilder``, where
/// `Node == SwiftSymbol`) or a trivial `Int` index into arena arrays that the
/// builder owns. The engine holds one builder and calls through it; nothing in
/// `Demangler`/`NodePrinter` assumes `Node` is anything in particular.
///
/// This stage ships exactly one conformer, ``SwiftSymbolBuilder``, whose `Node`
/// is `SwiftSymbol` and whose every method is a one-line, `@inline(__always)`
/// forward to the corresponding value operation. Because the generic core is
/// in-module and instantiated at a single concrete type, the optimizer
/// specializes it and inlines these forwards away: the abstraction is a
/// compile-time seam with no runtime cost (verified by the benchmark battery).
///
/// Node kinds are the universal currency — both a value tree and an arena speak
/// ``SwiftSymbol/Kind`` — so kind-keyed predicates need no abstraction and stay
/// shared. Only node *handles* flow through the builder.
protocol NodeBuilder {
    /// The engine's opaque node handle. A value that carries its own storage
    /// (`SwiftSymbol`) or an index into arena storage the builder owns (`Int`).
    /// `Equatable` so the (rare) child-replacement rewrites can find a known
    /// child again: structural equality for the value backend (what its
    /// `firstIndex(of:)` always used), handle identity for an arena — where a
    /// node placed as a child IS the same handle, the reference demangler's
    /// pointer-identity semantics.
    associatedtype Node: Equatable

    // MARK: Creation

    // Node operands are `consuming`: a child (or child list) handed to a builder
    // is being moved into the tree, so taking ownership lets the compiler move
    // it instead of retain/release-ing the `SwiftSymbol` backend's heap storage
    // across the call — the complement of `borrowing` on the readers below.
    // Together they give the ARC optimizer the ownership facts it needs to erase
    // the abstraction's copies (profiled: the untyped version left ~4% extra
    // retain/release on the demangle path). For a trivial `Int` node it is free.

    /// A childless, payload-free node (mirrors `SwiftSymbol(kind:)`).
    func make(kind: SwiftSymbol.Kind) -> Node
    /// A node with a single child (mirrors `SwiftSymbol(kind:child:)`).
    func make(kind: SwiftSymbol.Kind, child: consuming Node) -> Node
    /// A node with an ordered child list (mirrors `SwiftSymbol(kind:children:)`).
    func make(kind: SwiftSymbol.Kind, children: consuming [Node]) -> Node
    /// A node whose ordered child list is borrowed as a buffer — semantically
    /// `make(kind: kind, children: Array(children))`, which is exactly what
    /// the value backend does (one child-array allocation, the same one the
    /// former per-site `[Node]` temporary carried). The grammar sites that
    /// assemble a child list into the engine's scratch region (see
    /// ``EngineStacks``) hand it over through this, so the arena backend
    /// appends straight into its child slab with no per-call array at all.
    func make(kind: SwiftSymbol.Kind, children: UnsafeBufferPointer<Node>) -> Node
    // Fixed-arity constructors for the two/three/four-child grammar sites (the
    // `createWithChildren` overloads). The value backend builds the same
    // `[c0,c1,…]` storage array it would from `children:`; the arena backend
    // appends the children straight into its shared child buffer, skipping the
    // throwaway `[Node]` the `children:` form would allocate only to copy out of
    // and free. Each backend does what is optimal for its representation, and
    // both are byte-identical to the `children:` form.
    func make(kind: SwiftSymbol.Kind, child0: consuming Node, child1: consuming Node) -> Node
    func make(kind: SwiftSymbol.Kind, child0: consuming Node, child1: consuming Node, child2: consuming Node) -> Node
    func make(kind: SwiftSymbol.Kind, child0: consuming Node, child1: consuming Node, child2: consuming Node, child3: consuming Node) -> Node
    /// A node with a text payload (mirrors `SwiftSymbol(kind:name:)`). The text
    /// is *owned* — synthesized or transformed bytes, not a verbatim input slice
    /// (operator spellings, module constants, punycode-decoded or word-substituted
    /// identifiers). The value backend stores the `String`; the arena backend
    /// interns it out-of-line.
    func make(kind: SwiftSymbol.Kind, name: String) -> Node
    /// A node with an index payload (mirrors `SwiftSymbol(kind:index:)`).
    func make(kind: SwiftSymbol.Kind, index: UInt64) -> Node
    /// A node whose *owned* text was assembled as UTF-8 bytes (the
    /// word-substituted / punycode-decoded identifier accumulator, translated
    /// operator spellings). Semantically `make(kind:name:
    /// String(decoding: bytes, as: UTF8.self))` — which is exactly what the
    /// value backend does — but the arena backend pools the bytes without
    /// ever building the `String` (ill-formed sequences are normalized to the
    /// identical U+FFFD replacements first, so every representation carries
    /// the same text).
    func make(kind: SwiftSymbol.Kind, ownedBytes: consuming [UInt8]) -> Node
    /// An `.Identifier` whose text is the *verbatim* input UTF-8 slice
    /// `input[start ..< start+count]` — the zero-copy tag (stage C3). `input` is
    /// the demangle's own buffer; the arena backend records the range and binds
    /// that buffer (on its first verbatim identifier) so it can later render the
    /// slice straight through with no `String` and no per-identifier allocation,
    /// while the value backend materializes the identical `String` those bytes
    /// decode to — so the two stay byte-for-byte equal. The caller guarantees the
    /// slice is pure ASCII, so the raw bytes are exactly what
    /// `String(decoding:as:UTF8)` would render (non-ASCII, which would make the
    /// decode lossy, must go through the owned `make(kind:name:)` path instead).
    func makeIdentifier(_ input: borrowing [UInt8], start: Int, count: Int) -> Node

    // MARK: Reading

    // The node handle is passed `borrowing`: for the `SwiftSymbol` backend, a
    // node owns a heap child array (and possibly a payload string), so passing
    // it by value would retain/release that storage on every read. `borrowing`
    // reads it in place — the direct-property-access cost the pre-abstraction
    // engine had. For a trivial `Int`-index arena node it is a no-op.

    /// The node's structural kind.
    func kind(of node: borrowing Node) -> SwiftSymbol.Kind
    /// The node's text payload, or `nil`.
    func text(of node: borrowing Node) -> String?
    /// Whether the node has a text payload (`text(of:) != nil`) without
    /// materializing it — the arena backend answers from its tags.
    func hasText(of node: borrowing Node) -> Bool
    /// Whether the node's text equals `constant` — exactly `text(of:) ==
    /// constant` (so a payload-free node never matches, not even `""`). The
    /// engine's comparison constants are pure-ASCII literals, for which byte
    /// equality and `String` canonical equality coincide (no canonical
    /// decomposition maps into or out of the ASCII range), so the arena
    /// backend compares a verbatim identifier's input bytes directly with no
    /// `String` materialization — the hot sugar/module predicates
    /// (`isSwiftModule`, `findSugar`) profiled as `String` decode + compare
    /// churn before this seam.
    func textEquals(_ node: borrowing Node, _ constant: String) -> Bool
    /// Whether the node's text-or-empty equals `constant` — exactly
    /// `(text(of:) ?? "") == constant` (a payload-free node matches `""`).
    /// The `printContext` hidden-module probe's semantics.
    func textEqualsOrEmpty(_ node: borrowing Node, _ constant: String) -> Bool
    /// Whether the node's text-or-empty has `prefix` — exactly
    /// `(text(of:) ?? "").hasPrefix(prefix)`. `prefix` is a pure-ASCII
    /// constant not ending in `\r`, for which byte-prefix equality and
    /// `String.hasPrefix`'s grapheme-aligned comparison coincide on the
    /// arena's (ASCII-by-construction) verbatim slices.
    func textHasPrefix(_ node: borrowing Node, _ prefix: String) -> Bool
    /// Append `node`'s text bytes to `bytes` (nothing when the node has no text)
    /// — the allocation-free render seam the printer's hot text sites use. An
    /// arena input-range identifier appends its input slice straight through with
    /// no intermediate `String`; owned text appends its UTF-8; the value backend
    /// appends the payload `String`'s UTF-8. Byte-for-byte equal to
    /// `bytes.append(contentsOf: (text(of:) ?? "").utf8)`.
    func appendText(of node: borrowing Node, to bytes: inout [UInt8])
    /// The node's index payload, or `nil`.
    func index(of node: borrowing Node) -> UInt64?
    /// The number of children.
    func childCount(of node: borrowing Node) -> Int
    /// The child at `index` (trapping out of bounds, as `children[index]`).
    func child(of node: borrowing Node, at index: Int) -> Node
    /// The first child, or `nil` when there are none.
    func firstChild(of node: borrowing Node) -> Node?
    /// The last child, or `nil` when there are none.
    func lastChild(of node: borrowing Node) -> Node?

    // MARK: In-place assembly

    /// Append `child` to `node` (the child is moved into `node`).
    func appendChild(to node: inout Node, _ child: consuming Node)
    /// Replace the child at `index` (trapping out of bounds).
    func setChild(of node: inout Node, at index: Int, to child: consuming Node)
    /// Reverse the whole child list in place.
    func reverseChildren(of node: inout Node)
    /// Reverse the child list from `start` to the end in place — the
    /// postfix-stack fixup that restores source order after a run of pops.
    func reverseChildrenSuffix(of node: inout Node, from start: Int)
    /// The node with its kind replaced, children and payload preserved.
    func changingKind(_ node: consuming Node, to newKind: SwiftSymbol.Kind) -> Node

    // MARK: Depth ceiling

    /// Whether the tree at `node` overflowed
    /// ``SwiftManglingConstants/maxTreeDepth`` during construction. Both
    /// backends track a node's depth as it is built; a make/append that
    /// would nest past the ceiling refuses the children involved and marks
    /// the node instead, and the mark propagates to every ancestor — so an
    /// over-deep tree can never exist (every print and walk stays
    /// depth-bounded on every path including mid-parse failure), and the
    /// demangler declines any marked node the moment it surfaces.
    func isDepthPoisoned(_ node: borrowing Node) -> Bool

    /// Whether `node`'s tree is deep enough that an ordinary drop (which
    /// releases child storage one stack frame per level) should be routed
    /// through ``releaseDeep(_:)`` instead. Always false for the arena
    /// (trivial handles); the value backend answers from the node's depth.
    func needsRoutedRelease(_ node: borrowing Node) -> Bool

    /// Release possibly-deep, possibly-structure-sharing trees without
    /// recursing their depth (the value backend's topological buffer
    /// release; a no-op for the arena, whose slab frees en masse). The
    /// caller passes every remaining reference it holds — the set must be
    /// the trees' last external references for the release to free them.
    func releaseDeep(_ roots: consuming [Node])

    // MARK: `SwiftSymbol` boundary

    /// The `SwiftSymbol` subtree for `node`. Identity for the value backend;
    /// an arena backend reifies its index tree here. Used only at the public
    /// boundary and on the two `SwiftSymbol`-only interior paths (the
    /// opaque-return-type parenting rewrite, which reuses the `SwiftMangler`,
    /// and any handoff to the `SwiftSymbol`-based remangler).
    func materialize(_ node: Node) -> SwiftSymbol
    /// Absorb a `SwiftSymbol` subtree back into a `Node` — the inverse of
    /// ``materialize(_:)``. Identity for the value backend.
    func adopt(_ symbol: SwiftSymbol) -> Node
}

/// The value backend: the engine's node handle is the public ``SwiftSymbol``
/// paired with its construction-time depth, so the depth ceiling is enforced
/// as trees are BUILT — never by walking or tearing down something already
/// too deep. Every structural requirement is a thin `@inline(__always)`
/// forward to the corresponding `SwiftSymbol` value operation plus O(1)
/// depth arithmetic; a specialized `Demangler<SwiftSymbolBuilder>` /
/// `NodePrinter<SwiftSymbolBuilder>` remains the pre-abstraction engine
/// with the calls inlined away. The builder is a stateless empty value:
/// the node carries its own storage.
struct DepthTrackedSymbol {
    /// The public value tree.
    var symbol: SwiftSymbol
    /// `1` for a leaf, `1 + max(children)` otherwise;
    /// `SwiftSymbolBuilder.poisonedDepth` marks a construction that would
    /// have nested past the ceiling. Children read back out of a parent
    /// carry the (conservative) bound `parent.depth - 1` — the rare
    /// re-parenting rewrites may therefore overestimate a subtree by a few
    /// levels, which is harmless against the ceiling's ~31x real-world
    /// margin and can only ever decline early, never build deep.
    var depth: Int32
}

extension DepthTrackedSymbol: Equatable {
    /// Structural equality only: `depth` is construction bookkeeping (and a
    /// conservative bound after re-parenting reads), so the (rare)
    /// child-replacement rewrites' `firstIndex(of:)` semantics stay exactly
    /// the value tree's.
    static func == (a: DepthTrackedSymbol, b: DepthTrackedSymbol) -> Bool {
        a.symbol == b.symbol
    }
}

struct SwiftSymbolBuilder: NodeBuilder {
    typealias Node = DepthTrackedSymbol

    /// The construction ceiling (`SwiftManglingConstants.maxTreeDepth`) and
    /// the over-ceiling mark. A make/append whose result would exceed the
    /// ceiling refuses the children involved (they are released HERE, each
    /// itself ceiling-bounded) and marks the node; the mark propagates
    /// through every ancestor, and the demangler entries decline a marked
    /// root in O(1).
    static let ceiling = Int32(SwiftManglingConstants.maxTreeDepth)
    static let poisonedDepth = ceiling + 1

    @inline(__always) func make(kind: SwiftSymbol.Kind) -> Node {
        Node(symbol: SwiftSymbol(kind: kind), depth: 1)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, child: consuming Node) -> Node {
        if child.depth >= Self.ceiling {
            refuse([child.symbol])
            return Node(symbol: SwiftSymbol(kind: kind), depth: Self.poisonedDepth)
        }
        return Node(symbol: SwiftSymbol(kind: kind, child: child.symbol), depth: child.depth + 1)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, children: consuming [Node]) -> Node {
        let list = children
        var deepest: Int32 = 0
        for child in list where child.depth > deepest {
            deepest = child.depth
        }
        if deepest >= Self.ceiling {
            refuse(list.map(\.symbol))
            return Node(symbol: SwiftSymbol(kind: kind), depth: Self.poisonedDepth)
        }
        return Node(symbol: SwiftSymbol(kind: kind, children: list.map(\.symbol)), depth: deepest + 1)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, children: UnsafeBufferPointer<Node>) -> Node {
        var deepest: Int32 = 0
        for child in children where child.depth > deepest {
            deepest = child.depth
        }
        if deepest >= Self.ceiling {
            refuse(children.map(\.symbol))
            return Node(symbol: SwiftSymbol(kind: kind), depth: Self.poisonedDepth)
        }
        return Node(symbol: SwiftSymbol(kind: kind, children: children.map(\.symbol)), depth: deepest + 1)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, child0: consuming Node, child1: consuming Node) -> Node {
        let deepest = max(child0.depth, child1.depth)
        if deepest >= Self.ceiling {
            refuse([child0.symbol, child1.symbol])
            return Node(symbol: SwiftSymbol(kind: kind), depth: Self.poisonedDepth)
        }
        return Node(symbol: SwiftSymbol(kind: kind, children: [child0.symbol, child1.symbol]), depth: deepest + 1)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, child0: consuming Node, child1: consuming Node, child2: consuming Node) -> Node {
        let deepest = max(max(child0.depth, child1.depth), child2.depth)
        if deepest >= Self.ceiling {
            refuse([child0.symbol, child1.symbol, child2.symbol])
            return Node(symbol: SwiftSymbol(kind: kind), depth: Self.poisonedDepth)
        }
        return Node(
            symbol: SwiftSymbol(kind: kind, children: [child0.symbol, child1.symbol, child2.symbol]),
            depth: deepest + 1,
        )
    }

    @inline(__always) func make(
        kind: SwiftSymbol.Kind, child0: consuming Node, child1: consuming Node,
        child2: consuming Node, child3: consuming Node,
    ) -> Node {
        let deepest = max(max(child0.depth, child1.depth), max(child2.depth, child3.depth))
        if deepest >= Self.ceiling {
            refuse([child0.symbol, child1.symbol, child2.symbol, child3.symbol])
            return Node(symbol: SwiftSymbol(kind: kind), depth: Self.poisonedDepth)
        }
        return Node(
            symbol: SwiftSymbol(kind: kind, children: [child0.symbol, child1.symbol, child2.symbol, child3.symbol]),
            depth: deepest + 1,
        )
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, name: String) -> Node {
        Node(symbol: SwiftSymbol(kind: kind, name: name), depth: 1)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, index: UInt64) -> Node {
        Node(symbol: SwiftSymbol(kind: kind, index: index), depth: 1)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, ownedBytes: consuming [UInt8]) -> Node {
        // Exactly the `String` the assembling call sites built before this
        // seam existed.
        Node(symbol: SwiftSymbol(kind: kind, name: String(decoding: ownedBytes, as: UTF8.self)), depth: 1)
    }

    @inline(__always) func makeIdentifier(_ input: borrowing [UInt8], start: Int, count: Int) -> Node {
        // The value tree has no zero-copy representation: build exactly the
        // `String` the pre-C3 `demangleIdentifier` built from these input bytes.
        Node(
            symbol: SwiftSymbol(kind: .Identifier, name: String(decoding: input[start ..< start + count], as: UTF8.self)),
            depth: 1,
        )
    }

    @inline(__always) func kind(of node: borrowing Node) -> SwiftSymbol.Kind {
        node.symbol.kind
    }

    @inline(__always) func text(of node: borrowing Node) -> String? {
        node.symbol.text
    }

    @inline(__always) func hasText(of node: borrowing Node) -> Bool {
        node.symbol.text != nil
    }

    @inline(__always) func textEquals(_ node: borrowing Node, _ constant: String) -> Bool {
        node.symbol.text == constant
    }

    @inline(__always) func textEqualsOrEmpty(_ node: borrowing Node, _ constant: String) -> Bool {
        (node.symbol.text ?? "") == constant
    }

    @inline(__always) func textHasPrefix(_ node: borrowing Node, _ prefix: String) -> Bool {
        (node.symbol.text ?? "").hasPrefix(prefix)
    }

    @inline(__always) func appendText(of node: borrowing Node, to bytes: inout [UInt8]) {
        if let t = node.symbol.text { bytes.append(contentsOf: t.utf8) }
    }

    @inline(__always) func index(of node: borrowing Node) -> UInt64? {
        node.symbol.index
    }

    @inline(__always) func childCount(of node: borrowing Node) -> Int {
        node.symbol.children.count
    }

    @inline(__always) func child(of node: borrowing Node, at index: Int) -> Node {
        Node(symbol: node.symbol.children[index], depth: max(1, node.depth - 1))
    }

    @inline(__always) func firstChild(of node: borrowing Node) -> Node? {
        guard let first = node.symbol.children.first else { return nil }
        return Node(symbol: first, depth: max(1, node.depth - 1))
    }

    @inline(__always) func lastChild(of node: borrowing Node) -> Node? {
        guard let last = node.symbol.children.last else { return nil }
        return Node(symbol: last, depth: max(1, node.depth - 1))
    }

    @inline(__always) func appendChild(to node: inout Node, _ child: consuming Node) {
        if node.depth > Self.ceiling { refuse([child.symbol]); return } // poisoned stay childless
        let grown = child.depth + 1
        if grown > Self.ceiling {
            refuse([child.symbol])
            node.depth = Self.poisonedDepth
            return
        }
        node.symbol.addChild(child.symbol)
        if grown > node.depth { node.depth = grown }
    }

    @inline(__always) func setChild(of node: inout Node, at index: Int, to child: consuming Node) {
        if node.depth > Self.ceiling { refuse([child.symbol]); return } // poisoned stay childless
        let grown = child.depth + 1
        if grown > Self.ceiling {
            refuse([child.symbol])
            node.depth = Self.poisonedDepth
            return
        }
        node.symbol.children[index] = child.symbol
        if grown > node.depth { node.depth = grown }
    }

    @inline(__always) func reverseChildren(of node: inout Node) {
        node.symbol.children.reverse()
    }

    @inline(__always) func reverseChildrenSuffix(of node: inout Node, from start: Int) {
        let tail = Array(node.symbol.children[start...].reversed())
        node.symbol.children.replaceSubrange(start..., with: tail)
    }

    @inline(__always) func changingKind(_ node: consuming Node, to newKind: SwiftSymbol.Kind) -> Node {
        Node(symbol: node.symbol.changingKind(to: newKind), depth: node.depth)
    }

    @inline(__always) func isDepthPoisoned(_ node: borrowing Node) -> Bool {
        node.depth > Self.ceiling
    }

    /// Deep enough that a plain drop's recursive teardown could matter on a
    /// small stack; conservative and cheap (one compare).
    @inline(__always) func needsRoutedRelease(_ node: borrowing Node) -> Bool {
        node.depth > 256
    }

    /// Topological (parents-first) release of the unique child buffers under
    /// `roots`. With every external reference consumed into `roots`, each
    /// buffer's refcount is exactly one representative plus its parent-buffer
    /// copies; releasing representatives in topological order therefore frees
    /// every buffer at its own release, when the buffers directly inside it
    /// still hold live representatives — one level of teardown per step, at
    /// any depth, in any sharing shape, in linear time. (When aliases of
    /// these trees are still live elsewhere — a poison-refusal while the
    /// parse regions hold copies — the walk just decrements; the final
    /// holder routes here again and frees.)
    func releaseDeep(_ roots: consuming [Node]) {
        releaseDeepSymbols(roots.map(\.symbol))
    }

    private func releaseDeepSymbols(_ roots: consuming [SwiftSymbol]) {
        var reps: [SwiftSymbol] = []
        var index: [UInt: Int] = [:]
        var childIDs: [[UInt]] = []
        var indegree: [Int] = []
        var queue = roots
        var next = 0
        while next < queue.count {
            let node = queue[next]
            next += 1
            if node.children.isEmpty { continue }
            let bufferID = node.children.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            if index[bufferID] == nil {
                index[bufferID] = reps.count
                reps.append(node)
                childIDs.append([])
                indegree.append(0)
                queue.append(contentsOf: node.children)
            }
        }
        // Queue copies drop shallowly: every buffer they reference has a
        // live representative.
        queue = []
        for i in reps.indices {
            var edges: [UInt] = []
            for child in reps[i].children where !child.children.isEmpty {
                let id = child.children.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
                edges.append(id)
                indegree[index[id].unsafelyUnwrapped] += 1
            }
            childIDs[i] = edges
        }
        var ready: [Int] = indegree.indices.filter { indegree[$0] == 0 }
        let leaf = SwiftSymbol(kind: .Suffix)
        while let i = ready.popLast() {
            for id in childIDs[i] {
                let child = index[id].unsafelyUnwrapped
                indegree[child] -= 1
                if indegree[child] == 0 { ready.append(child) }
            }
            reps[i] = leaf
        }
        // The buffer graph is acyclic by construction (value trees), so the
        // Kahn walk always drains `reps` to all-placeholders here.
    }

    /// Route a poison-refusal's children through the deep release: dropping
    /// a ceiling-deep child inline would recurse its whole depth on the
    /// caller's stack.
    @inline(never) private func refuse(_ children: consuming [SwiftSymbol]) {
        releaseDeepSymbols(children)
    }

    @inline(__always) func materialize(_ node: Node) -> SwiftSymbol {
        node.symbol
    }

    func adopt(_ symbol: SwiftSymbol) -> Node {
        // Adopted subtrees come from outside the builder (the old demangler,
        // the symbolic-reference resolver), so their depth is measured here —
        // iteratively, depth-first, early-exiting at the ceiling. An
        // over-ceiling adoptee is refused childless: our copies share the
        // caller's storage, so dropping them releases nothing deep.
        var stack: [(node: SwiftSymbol, depth: Int32)] = [(symbol, 1)]
        var deepest: Int32 = 1
        while let (node, depth) = stack.popLast() {
            if depth > deepest {
                deepest = depth
                if deepest > Self.ceiling {
                    return Node(symbol: SwiftSymbol(kind: symbol.kind), depth: Self.poisonedDepth)
                }
            }
            for child in node.children {
                stack.append((child, depth + 1))
            }
        }
        return Node(symbol: symbol, depth: deepest)
    }
}
