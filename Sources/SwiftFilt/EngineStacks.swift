// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// The three parse-state buffers of a ``Demangler`` — the node stack, the
/// substitution list, and the word-harvest ranges — as regions of ONE raw
/// slab allocation, in place of three separately-allocated `Array`s (which
/// billed a one-shot demangle four mallocs: two 16-capacity reserves plus
/// the word array's first allocation and its growth). Apple's demangler
/// holds the same state inline (`NodeVector`s on a shared `NodeFactory`
/// slab, `Words[MaxNumWords]` a fixed array), so one slab is the
/// reference-shaped layout, not a compression trick.
///
/// **Layout.** `nodes(16) | subs(16) | scratch(16) | words(26)` — the three
/// node regions first (same element type, one `bindMemory`), the word region
/// tail-aligned for `Range<Int>`. Word capacity is exactly
/// ``SwiftManglingConstants/maxNumWords``: the single harvest site guards
/// `wordsCount < maxNumWords` (apple's fixed `Words[MaxNumWords]` array and
/// its identical guard), so the region is grammar-full, never overrun, and
/// needs no growth arm. The scratch region is the child-list assembly
/// buffer — apple's `Vector<NodePointer>` lives on the `NodeFactory` slab
/// the same way — used mark/append/truncate-nested by the grammar sites
/// that collect children before making a node, so those sites allocate no
/// per-call array.
///
/// **Growth.** A node/substitution region that outgrows its slab slot
/// *spills*: it relocates (move-initialized, no ARC traffic) to a dedicated
/// geometric allocation and abandons its slab slot — the other regions stay
/// put, deep symbols get real doubling with no ceiling, and capacity earned
/// on a deep symbol keeps serving later parses of the same stacks (the
/// shuttle below). The abandoned slot is the arena's child-run abandonment
/// discipline: a bump region never frees mid-lifetime.
///
/// **Ownership.** A raw-pointer struct with one owner at a time: it lives in
/// a ``Demangler`` (whose deinit calls ``destroy()``) or shuttles whole —
/// one `swap` — through the engine-reuse seam (`Demangler.init(text:nb:taking:)`
/// / `giveBack(_:)`), replacing the per-buffer swaps of the former
/// `DemanglerStorage`. The empty placeholder state (`init()`, no allocation)
/// exists exactly for that shuttle: a session demangler is born empty, takes
/// the engine's warm stacks, and gives them back; ``prepareForParse()``
/// allocates on first take (the engine's storage starts empty, as the old
/// arrays did) and rewinds on every later one. ``destroy()`` on a
/// placeholder is a no-op, so tearing down either side is always safe.
///
/// Element lifetimes are managed manually and exactly: append initializes,
/// pop moves out, rewind/teardown deinitialize live elements — so the
/// `SwiftSymbol` value backend's ARC-managed nodes are retained and released
/// precisely as the `Array`s did, while the arena's trivial `Int32` handles
/// compile to plain stores. Behavior across both backends is pinned by the
/// full-corpus differential.
struct EngineStacks<Node> {
    /// The single slab allocation; `nil` is the empty placeholder state.
    private var slab: UnsafeMutableRawPointer?
    /// Region bases — into the slab until that region spills, then into its
    /// dedicated allocation. Non-`nil` whenever `slab` is (and the word
    /// region never spills, so `wordsBase` always points into the slab).
    private var nodesBase: UnsafeMutablePointer<Node>?
    private var subsBase: UnsafeMutablePointer<Node>?
    private var scratchBase: UnsafeMutablePointer<Node>?
    private var wordsBase: UnsafeMutablePointer<Range<Int>>?
    private(set) var nodesCount = 0
    private(set) var subsCount = 0
    private(set) var scratchCount = 0
    private(set) var wordsCount = 0
    private var nodesCapacity = 0
    private var subsCapacity = 0
    private var scratchCapacity = 0
    private var nodesSpilled = false
    private var subsSpilled = false
    private var scratchSpilled = false

    /// The slab slot sizes: parse-warm starting capacities for the three
    /// node regions (every real parse pushes nodes and substitutions
    /// immediately; 16 keeps the first appends off the growth path, as the
    /// arrays' `reserveCapacity(16)` did), and the grammar-exact word
    /// capacity.
    private static var nodesSlotCapacity: Int {
        16
    }

    private static var subsSlotCapacity: Int {
        16
    }

    private static var scratchSlotCapacity: Int {
        16
    }

    private static var wordsSlotCapacity: Int {
        SwiftManglingConstants.maxNumWords
    }

    /// The empty placeholder — no allocation. A parse must go through
    /// ``allocated()`` or ``prepareForParse()`` first; the placeholder only
    /// shuttles and destroys.
    init() {}

    /// Freshly-allocated stacks, ready to parse — the one-shot constructor's
    /// storage (its single engine-storage allocation).
    static func allocated() -> EngineStacks {
        var stacks = EngineStacks()
        stacks.allocateSlab()
        return stacks
    }

    /// Make taken stacks parse-ready: allocate the slab on the first take
    /// (an engine's storage starts as the empty placeholder, so a session's
    /// first call pays the one slab allocation and every later call finds it
    /// warm — the former `capacity < 16` reserve dance), or rewind live
    /// state on a warm take.
    @inline(__always)
    mutating func prepareForParse() {
        if slab == nil {
            allocateSlab()
        } else {
            removeAll()
        }
    }

    private mutating func allocateSlab() {
        let nodeStride = MemoryLayout<Node>.stride
        let nodeSlots = Self.nodesSlotCapacity + Self.subsSlotCapacity + Self.scratchSlotCapacity
        // Word region tail: `Range<Int>`-aligned (node strides are already
        // multiples of the node alignment, so only this seam needs rounding).
        let wordAlignment = MemoryLayout<Range<Int>>.alignment
        let wordsOffset = (nodeSlots * nodeStride + wordAlignment - 1) & ~(wordAlignment - 1)
        let byteCount = wordsOffset + Self.wordsSlotCapacity * MemoryLayout<Range<Int>>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: Swift.max(MemoryLayout<Node>.alignment, wordAlignment),
        )
        slab = raw
        let nodeBlock = raw.bindMemory(to: Node.self, capacity: nodeSlots)
        nodesBase = nodeBlock
        subsBase = nodeBlock + Self.nodesSlotCapacity
        scratchBase = nodeBlock + Self.nodesSlotCapacity + Self.subsSlotCapacity
        wordsBase = (raw + wordsOffset).bindMemory(to: Range<Int>.self, capacity: Self.wordsSlotCapacity)
        nodesCapacity = Self.nodesSlotCapacity
        subsCapacity = Self.subsSlotCapacity
        scratchCapacity = Self.scratchSlotCapacity
    }

    /// Deinitialize live elements and free the slab and any spill
    /// allocations, returning to the placeholder state (so a double destroy,
    /// or destroying a given-back demangler's placeholder, is a no-op). The
    /// value backend's nodes release their trees here exactly as the arrays'
    /// teardown did.
    mutating func destroy() {
        guard slab != nil else { return }
        removeAll()
        if nodesSpilled { nodesBase.unsafelyUnwrapped.deallocate() }
        if subsSpilled { subsBase.unsafelyUnwrapped.deallocate() }
        if scratchSpilled { scratchBase.unsafelyUnwrapped.deallocate() }
        slab.unsafelyUnwrapped.deallocate()
        self = EngineStacks()
    }

    /// Move every live element out through `consume` (newest first per
    /// region), leaving all regions empty — the deep-teardown seam: when a
    /// value-backend parse has built deep (but in-ceiling) trees and then
    /// fails or declines, the demangler drains its regions through the
    /// builder's routed release instead of the recursive element teardown
    /// that ``removeAll()``'s deinitialize would run. On the placeholder
    /// (or an already-empty state) every count is zero and this is a no-op.
    mutating func drainElements(_ consume: (Node) -> Void) {
        while nodesCount > 0 {
            consume(removeLastNode())
        }
        while subsCount > 0 {
            subsCount -= 1
            consume((subsBase.unsafelyUnwrapped + subsCount).move())
        }
        while scratchCount > 0 {
            scratchCount -= 1
            consume((scratchBase.unsafelyUnwrapped + scratchCount).move())
        }
        wordsCount = 0
    }

    /// Rewind all regions (capacity kept — slab and spills stay for the
    /// next parse), deinitializing live elements so the value backend's
    /// nodes release exactly as `removeAll(keepingCapacity:)` released them.
    /// The scratch region is transient (its users truncate back to their
    /// mark on every path out), so it is empty here on every real reset;
    /// deinitializing its (zero) live elements keeps the invariant local.
    @inline(__always)
    mutating func removeAll() {
        nodesBase.unsafelyUnwrapped.deinitialize(count: nodesCount)
        subsBase.unsafelyUnwrapped.deinitialize(count: subsCount)
        scratchBase.unsafelyUnwrapped.deinitialize(count: scratchCount)
        nodesCount = 0
        subsCount = 0
        scratchCount = 0
        wordsCount = 0
    }

    /// One spill body for every region (line coverage owed by whichever
    /// region grows in a given run — deep symbols grow nodes/subs; a
    /// many-child assembly grows scratch): relocate to a dedicated doubled
    /// allocation (moved, no ARC traffic), abandon the slab slot, free the
    /// previous spill if this is not the first.
    @inline(never)
    private static func spill(
        _ base: inout UnsafeMutablePointer<Node>?, _ count: Int,
        _ capacity: inout Int, _ spilled: inout Bool,
    ) {
        let newCapacity = capacity * 2
        let fresh = UnsafeMutablePointer<Node>.allocate(capacity: newCapacity)
        fresh.moveInitialize(from: base.unsafelyUnwrapped, count: count)
        if spilled { base.unsafelyUnwrapped.deallocate() }
        base = fresh
        capacity = newCapacity
        spilled = true
    }

    // MARK: Node stack

    @inline(__always)
    mutating func pushNode(_ node: consuming Node) {
        if nodesCount == nodesCapacity { Self.spill(&nodesBase, nodesCount, &nodesCapacity, &nodesSpilled) }
        (nodesBase.unsafelyUnwrapped + nodesCount).initialize(to: node)
        nodesCount += 1
    }

    /// Move the top node out (caller has checked the stack is non-empty —
    /// both pop shapes below guard through ``lastNodePointer``/`nodesCount`).
    @inline(__always)
    mutating func removeLastNode() -> Node {
        nodesCount -= 1
        return (nodesBase.unsafelyUnwrapped + nodesCount).move()
    }

    @inline(__always)
    mutating func popNode() -> Node? {
        nodesCount > 0 ? removeLastNode() : nil
    }

    /// Borrowing pointer to the top node (`nil` when empty): the pop-probes
    /// read the top's kind in place through `pointee` (an addressor, so no
    /// copy), avoiding the retain/release a by-value peek costs the
    /// `SwiftSymbol` backend — the former `nodeStack[indices.last]` borrow.
    @inline(__always)
    var lastNodePointer: UnsafeMutablePointer<Node>? {
        nodesCount > 0 ? nodesBase.unsafelyUnwrapped + (nodesCount - 1) : nil
    }

    /// The node at `index` (a copy, as iterating the old array copied) —
    /// the final-assembly walk reads the leftover stack through this.
    @inline(__always)
    func node(at index: Int) -> Node {
        (nodesBase.unsafelyUnwrapped + index).pointee
    }

    // MARK: Substitutions

    @inline(__always)
    mutating func appendSub(_ node: consuming Node) {
        if subsCount == subsCapacity { Self.spill(&subsBase, subsCount, &subsCapacity, &subsSpilled) }
        (subsBase.unsafelyUnwrapped + subsCount).initialize(to: node)
        subsCount += 1
    }

    /// The substitution at `index` (bounds are the caller's guard, exactly
    /// as the array sites checked `index < substitutions.count`).
    @inline(__always)
    func sub(at index: Int) -> Node {
        (subsBase.unsafelyUnwrapped + index).pointee
    }

    // MARK: Scratch (child-list assembly)

    // A grammar site that collects children before making a node records
    // `scratchCount` as its mark, appends, hands the assembled run to the
    // builder through `withScratch`, and truncates back to its mark on every
    // path out — nesting-safe (an inner collector's run sits above the
    // outer's mark), the discipline of apple's factory-allocated
    // `Vector<NodePointer>`.

    @inline(__always)
    mutating func appendScratch(_ node: consuming Node) {
        if scratchCount == scratchCapacity { Self.spill(&scratchBase, scratchCount, &scratchCapacity, &scratchSpilled) }
        (scratchBase.unsafelyUnwrapped + scratchCount).initialize(to: node)
        scratchCount += 1
    }

    /// Drop scratch elements above `mark` (deinitialized, so the value
    /// backend releases them; the assembled node holds its own copies).
    @inline(__always)
    mutating func truncateScratch(to mark: Int) {
        (scratchBase.unsafelyUnwrapped + mark).deinitialize(count: scratchCount - mark)
        scratchCount = mark
    }

    /// Borrow the scratch run `[mark, scratchCount)` as a buffer — the
    /// assembled child list handed to `NodeBuilder.make(kind:children:)`.
    @inline(__always)
    func withScratch<R>(from mark: Int, _ body: (UnsafeBufferPointer<Node>) -> R) -> R {
        body(UnsafeBufferPointer(start: scratchBase.unsafelyUnwrapped + mark, count: scratchCount - mark))
    }

    // MARK: Words

    /// Record a word-harvest range. The single call site guards
    /// `wordsCount < maxNumWords` (the region's exact capacity — apple's
    /// `Words[MaxNumWords]` fixed array and its guard), so the region cannot
    /// overrun and carries no growth arm.
    @inline(__always)
    mutating func appendWord(_ range: Range<Int>) {
        (wordsBase.unsafelyUnwrapped + wordsCount).initialize(to: range)
        wordsCount += 1
    }

    @inline(__always)
    func word(at index: Int) -> Range<Int> {
        (wordsBase.unsafelyUnwrapped + index).pointee
    }
}
