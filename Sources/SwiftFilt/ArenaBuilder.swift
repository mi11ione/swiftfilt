// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// The bump-arena ``NodeBuilder`` backend: the same one apple-traceable
/// demangler and node-printer bodies (generic over ``NodeBuilder`` since
/// stage C1) drive here without a single per-node heap allocation or ARC
/// teardown, the way apple's `NodeFactory` slab-allocates `swift::Demangle::Node`.
///
/// **Handle.** ``Node`` is a bare `Int32` index into the arena's record array —
/// trivial, so the engine's `nodeStack`/`substitutions` (`[B.Node]`) and every
/// `B.Node?` the grammar threads are POD `[Int32]`/`Int32?` with no reference
/// counting. Copying a handle aliases the arena node (it does *not* deep-copy a
/// subtree the way the `SwiftSymbol` value backend does) — which is exactly
/// apple's shared-`NodePointer` semantics: a substituted or multiply-parented
/// node is one node, referenced by many handles. The engine treats an
/// already-built node as immutable and only ever mutates freshly-built ones, so
/// aliasing is sound (and pinned by the full-corpus differential against the
/// value backend).
///
/// **Record.** ``Record`` is a fully trivial value — its ``SwiftSymbol/Kind`` is
/// just the enum's tag, and the text payload lives out-of-line in ``texts`` and
/// is referenced by index — so ``records`` is a flat, memcpy-growable buffer
/// with no ARC on reallocation. The payload mirrors ``SwiftSymbol/Contents``: a
/// node carries text *or* an index *or* neither, never more.
///
/// **Children.** Each node's children are a contiguous run
/// `[childStart, childStart+childCount)` in the shared ``childBuffer`` pool.
/// ``appendChild(to:_:)`` grows a full node's run by relocating it to a
/// freshly-reserved tail region of doubled capacity and abandoning the old one
/// (the slab bump never frees an individual node) — O(1) amortized append and,
/// crucially for the allocation-free printer, O(1) random `child(of:at:)`.
///
/// **Reuse.** ``reset()`` rewinds both slab regions and the text pools keeping
/// their capacity, so one builder demangles a whole batch (the scanner's
/// candidate stream) with zero storage reallocation after warmup; a one-shot
/// `demangle` spins up a fresh builder whose single record+child slab is its
/// entire allocation budget.
final class ArenaBuilder: NodeBuilder {
    /// The engine's opaque node handle: an index into ``records``. Trivial, so
    /// it flows through the generic engine free of retain/release.
    typealias Node = Int32

    /// One arena node. Fully trivial (no `String`/`Array` stored inline), so
    /// ``records`` grows by memcpy with no reference-counting traffic. The
    /// text/index payload is the ``SwiftSymbol/Contents`` union with the text arm
    /// split two ways: `inputStart >= 0` is a *verbatim* identifier — the input
    /// UTF-8 slice `inputBytes[inputStart ..< inputStart+inputCount]`, rendered
    /// zero-copy (stage C3); else `textRef >= 0` selects an *owned* string
    /// `texts[textRef]`; else `hasIndex` selects `indexPayload`; else the node
    /// has no payload. A node is exactly one of these, never more.
    struct Record {
        var kind: SwiftSymbol.Kind
        var textRef: Int32
        /// Verbatim-identifier tag: `>= 0` ⇒ text is `inputBytes[inputStart ..<
        /// inputStart+inputCount]` and overrides `textRef`; `-1` ⇒ not verbatim.
        var inputStart: Int32
        var inputCount: Int32
        var indexPayload: UInt64
        var hasIndex: Bool
        var childStart: Int32
        var childCount: Int32
        /// Construction-time tree depth: `1` for a leaf, `1 + max(children)`
        /// otherwise; past the ceiling the node is poisoned (see
        /// ``appendChildAt(_:_:)``) — the same contract as the value
        /// backend's ``DepthTrackedSymbol/depth``.
        var depth: Int32
    }

    /// The construction ceiling and its over-ceiling mark — shared with the
    /// value backend so both decline identically.
    private static let ceiling = SwiftSymbolBuilder.ceiling
    private static let poisonedDepth = SwiftSymbolBuilder.poisonedDepth

    /// The bump-allocated node slab, a raw `UnsafeMutablePointer` region (apple's
    /// `NodeFactory` is a malloc'd slab, not a bounds-checked/COW container). The
    /// print-heavy read path touches a node's fields thousands of times per
    /// symbol; a raw pointer read is an unchecked load with none of an `Array`'s
    /// per-access bounds check or per-append COW-uniqueness check. `Record` is
    /// trivial (its `Kind` is the enum's tag, the text is out-of-line), so the
    /// region needs no element (de)initialization ceremony and reallocation is a
    /// bitwise copy. Handle `h` is `recordsPtr[Int(h)]`, valid for `h < recordsCount`.
    // Arena state is `@exclusivity(unchecked)` for the same reason as
    // ``Demangler``'s: class-property mutations otherwise pay a dynamic
    // `swift_beginAccess` pair per bump/append — pure overhead on this
    // single-threaded, non-reentrant builder (no formal access overlaps
    // another; behavior pinned by the full-corpus differential).
    @exclusivity(unchecked) private var recordsPtr: UnsafeMutablePointer<Record>
    @exclusivity(unchecked) private var recordsCount = 0
    @exclusivity(unchecked) private var recordsCapacity: Int
    /// The shared child-handle pool: every node's children are a contiguous
    /// run `[childStart, childStart+childCount)` into it.
    @exclusivity(unchecked) private var childPtr: UnsafeMutablePointer<Int32>
    @exclusivity(unchecked) private var childCount = 0
    @exclusivity(unchecked) private var childCapacity: Int
    /// The ONE slab both regions start in: `records(128) | children(256)`
    /// bound at fixed offsets of a single raw allocation, so a fresh
    /// builder's whole storage is one malloc (two, before this merge). A
    /// region that outgrows its slot *spills* to its own geometric
    /// allocation (`growRecords`/`growChild`) and abandons the slot — the
    /// other region stays put, and the slab lives until deinit.
    @exclusivity(unchecked) private let slab: UnsafeMutableRawPointer
    @exclusivity(unchecked) private var recordsSpilled = false
    @exclusivity(unchecked) private var childSpilled = false
    /// Out-of-line *owned* text payloads — the synthesized/transformed texts
    /// that are NOT a verbatim input slice — in TWO representations behind
    /// one `Record.textRef` encoding (`>= 0` indexes ``texts``; `<= -2`
    /// indexes the byte pool as `-textRef - 2`; `-1` means no text):
    ///
    /// - ``texts``: ready-made `String`s (module/known-type constants, the
    ///   old demangler's and resolver's adopted payloads). Appending stores
    ///   the string — for the engine's constant names that is an immortal
    ///   literal reference, no byte copy — exactly the cheapest thing for a
    ///   text that already IS a `String` (pooling these measured −4.5% on
    ///   the stream: every `Si`/`So`/module node paid a byte memcpy for a
    ///   literal it could just reference).
    /// - ``ownedBytes``/``ownedRanges``: the assembled-bytes pool for texts
    ///   built as UTF-8 (word-substituted/punycode identifier accumulators,
    ///   translated operator spellings — `make(kind:ownedBytes:)`). The
    ///   render path copies pool bytes straight through with no `String`
    ///   and no ARC (the per-owned-identifier `String` box framed on the
    ///   stream profile), and the bytes are valid UTF-8 by construction so
    ///   the colder `String` reads decode to the exact value the
    ///   `String`-storing representation carried.
    ///
    /// Verbatim identifiers — the common case — use neither; they carry an
    /// `inputStart`/`inputCount` range into ``inputBytes`` (stage C3).
    @exclusivity(unchecked) private var texts: [String] = []
    @exclusivity(unchecked) private var ownedBytes: [UInt8] = []
    @exclusivity(unchecked) private var ownedRanges: [Range<Int>] = []
    /// The input UTF-8 buffer the demangle read, bound (once) the first time a
    /// verbatim identifier is created — see ``makeIdentifier(_:start:count:)``. A
    /// verbatim identifier's text is a slice of this, so an `inputStart`-tagged
    /// node renders (``appendText(of:to:)``), reads (``text(of:)``), and reifies
    /// (``materialize(_:)``) straight from here with no `String` allocation. Held
    /// for the whole demangle+print lifetime (the one-shot path and the scanner
    /// both keep this builder alive across both). A demangle that produces no
    /// verbatim identifier never binds it and never reads it.
    @exclusivity(unchecked) private var inputBytes: [UInt8] = []
    /// Whether ``inputBytes`` has been bound this demangle. Reset per demangle
    /// (see ``reset()``); the first verbatim identifier binds, the rest skip — so
    /// the input buffer is retained exactly once, never per identifier.
    @exclusivity(unchecked) private var inputBound = false
    /// Whether ``inputBytes`` is pinned across ``reset()`` — the windowed
    /// batch scan installs ONE immutable buffer and demangles thousands of
    /// candidate windows of it, so rebinding (a retain/release pair on the
    /// shared buffer) per candidate is pure churn; profiled as the dominant
    /// cross-thread cacheline contention when parallel filter workers
    /// shared one region. Pinned or not, the binding is the same buffer the
    /// windows index, so rendered bytes are identical (differential-pinned).
    @exclusivity(unchecked) private var inputPinned = false

    init() {
        // Sized for the common symbol so a fresh builder's whole allocation is
        // this one slab; larger trees grow geometrically (rare, cold path).
        // `texts` reserves lazily in `internText` instead: a symbol whose
        // identifiers are all verbatim (the zero-copy fast path) never touches
        // it, so a fresh one-shot arena skips that allocation entirely.
        recordsCapacity = 128
        childCapacity = 256
        // `Record` (UInt64 payload) dominates alignment; its stride is a
        // multiple of the child region's `Int32` alignment, so the child
        // region binds directly after the record slot with no padding seam.
        let childOffset = 128 * MemoryLayout<Record>.stride
        slab = UnsafeMutableRawPointer.allocate(
            byteCount: childOffset + 256 * MemoryLayout<Int32>.stride,
            alignment: MemoryLayout<Record>.alignment,
        )
        recordsPtr = slab.bindMemory(to: Record.self, capacity: 128)
        childPtr = (slab + childOffset).bindMemory(to: Int32.self, capacity: 256)
    }

    deinit {
        // `Record`/`Int32` are trivial, so the storage need only be freed —
        // no per-element deinitialization. Spilled regions own dedicated
        // allocations; unspilled ones live in the slab.
        if recordsSpilled { recordsPtr.deallocate() }
        if childSpilled { childPtr.deallocate() }
        slab.deallocate()
    }

    /// Rewind the bump cursors (and drop the text payloads) while keeping the
    /// slabs, so the next demangle reuses them — the batch (scanner) fast path
    /// allocates nothing after warmup. Trivial elements need no teardown.
    func reset() {
        recordsCount = 0
        childCount = 0
        texts.removeAll(keepingCapacity: true)
        ownedBytes.removeAll(keepingCapacity: true)
        ownedRanges.removeAll(keepingCapacity: true)
        // Release the retained input buffer (not just unbind) unless a
        // windowed scan pinned it: no node can reach the buffer after a
        // reset, so dropping the reference is free — and a pinned buffer is
        // exactly the one the next window parses, so keeping it saves the
        // per-candidate retain/release pair.
        if !inputPinned {
            inputBytes = []
            inputBound = false
        }
    }

    /// Pin `input` as the bound verbatim-text buffer across ``reset()``
    /// calls, until ``unpinInput()`` — the windowed batch scan's binding:
    /// one retain for the whole scan, however many candidate windows it
    /// demangles. Identifier ranges are absolute into this buffer exactly
    /// as the per-demangle bind records them.
    func pinInput(_ input: [UInt8]) {
        inputBytes = input
        inputBound = true
        inputPinned = true
    }

    /// Release a pinned buffer and return to per-demangle binding.
    func unpinInput() {
        inputPinned = false
        inputBytes = []
        inputBound = false
    }

    // MARK: Allocation primitives

    @inline(__always)
    private func ensureRecords(_ needed: Int) {
        if needed > recordsCapacity { growRecords(needed) }
    }

    @inline(never)
    private func growRecords(_ needed: Int) {
        let newCapacity = Swift.max(needed, recordsCapacity * 2)
        let newPtr = UnsafeMutablePointer<Record>.allocate(capacity: newCapacity)
        newPtr.initialize(from: recordsPtr, count: recordsCount)
        if recordsSpilled { recordsPtr.deallocate() }
        recordsSpilled = true
        recordsPtr = newPtr
        recordsCapacity = newCapacity
    }

    @inline(__always)
    private func ensureChild(_ needed: Int) {
        if needed > childCapacity { growChild(needed) }
    }

    @inline(never)
    private func growChild(_ needed: Int) {
        let newCapacity = Swift.max(needed, childCapacity * 2)
        let newPtr = UnsafeMutablePointer<Int32>.allocate(capacity: newCapacity)
        newPtr.initialize(from: childPtr, count: childCount)
        if childSpilled { childPtr.deallocate() }
        childSpilled = true
        childPtr = newPtr
        childCapacity = newCapacity
    }

    @inline(__always)
    private func allocRecord(_ kind: SwiftSymbol.Kind, _ textRef: Int32, _ indexPayload: UInt64, _ hasIndex: Bool, inputStart: Int32 = -1, inputCount: Int32 = 0) -> Int32 {
        ensureRecords(recordsCount + 1)
        (recordsPtr + recordsCount).initialize(to: Record(
            kind: kind, textRef: textRef, inputStart: inputStart, inputCount: inputCount,
            indexPayload: indexPayload, hasIndex: hasIndex, childStart: -1, childCount: 0,
            depth: 1,
        ))
        let handle = Int32(truncatingIfNeeded: recordsCount)
        recordsCount += 1
        return handle
    }

    @inline(__always)
    private func internText(_ text: String) -> Int32 {
        // First owned text of this arena's lifetime: reserve once so the
        // common several-owned-texts symbol never regrows (the reservation
        // survives `reset()`'s `keepingCapacity` for the batch paths).
        if texts.capacity == 0 { texts.reserveCapacity(16) }
        let ref = Int32(truncatingIfNeeded: texts.count)
        texts.append(text)
        return ref
    }

    /// The `textRef` encoding for a byte-pool text at `poolIndex` (see the
    /// storage note above): `-2 - poolIndex`.
    @inline(__always)
    private static func poolRef(_ poolIndex: Int) -> Int32 {
        Int32(truncatingIfNeeded: -2 - poolIndex)
    }

    /// The pool range a `textRef <= -2` names.
    @inline(__always)
    private func poolRange(_ textRef: Int32) -> Range<Int> {
        ownedRanges[Int(-2 - textRef)]
    }

    /// Append `child` to `node`'s child run. A run lives contiguously in the
    /// child slab; while it sits at the slab's tail (the overwhelmingly common
    /// case — a burst of children built by `make(kind:children:)` or the
    /// fixed-arity `make`s, uninterrupted by any other node's append) the append
    /// is a single bump, so a node's children cost exactly their own slots with
    /// no reserved waste. Only when another node has appended since this run
    /// started (so it is no longer at the tail) does the run relocate to a fresh
    /// tail region — abandoning the old slots, the slab bump never freeing an
    /// individual node. O(1) amortized, and O(1) random `child(of:at:)` from the
    /// contiguous run for the allocation-free printer.
    @inline(__always)
    private func appendChildAt(_ node: Int32, _ child: Int32) {
        let i = Int(node)
        // Depth ceiling: attaching a child at the ceiling poisons the parent
        // instead of nesting past it, so an over-deep arena tree never
        // exists (and `materialize`'s recursion stays bounded). Poisoned
        // parents stay childless.
        if recordsPtr[i].depth > Self.ceiling { return }
        let grown = recordsPtr[Int(child)].depth + 1
        if grown > Self.ceiling {
            recordsPtr[i].depth = Self.poisonedDepth
            return
        }
        if grown > recordsPtr[i].depth { recordsPtr[i].depth = grown }
        let start = Int(recordsPtr[i].childStart)
        let count = Int(recordsPtr[i].childCount)
        if count == 0 {
            ensureChild(childCount + 1)
            recordsPtr[i].childStart = Int32(truncatingIfNeeded: childCount)
            (childPtr + childCount).initialize(to: child)
            childCount += 1
            recordsPtr[i].childCount = 1
        } else if start + count == childCount {
            ensureChild(childCount + 1)
            (childPtr + childCount).initialize(to: child)
            childCount += 1
            recordsPtr[i].childCount = Int32(count + 1)
        } else {
            ensureChild(childCount + count + 1)
            let newStart = childCount
            for k in 0 ..< count {
                (childPtr + childCount + k).initialize(to: childPtr[start + k])
            }
            childCount += count
            (childPtr + childCount).initialize(to: child)
            childCount += 1
            recordsPtr[i].childStart = Int32(truncatingIfNeeded: newStart)
            recordsPtr[i].childCount = Int32(count + 1)
        }
    }

    // MARK: Creation

    @inline(__always) func make(kind: SwiftSymbol.Kind) -> Int32 {
        allocRecord(kind, -1, 0, false)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, child: consuming Int32) -> Int32 {
        let node = allocRecord(kind, -1, 0, false)
        appendChildAt(node, child)
        return node
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, children: consuming [Int32]) -> Int32 {
        let node = allocRecord(kind, -1, 0, false)
        for child in children {
            appendChildAt(node, child)
        }
        return node
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, children: UnsafeBufferPointer<Int32>) -> Int32 {
        let node = allocRecord(kind, -1, 0, false)
        for child in children {
            appendChildAt(node, child)
        }
        return node
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, child0: consuming Int32, child1: consuming Int32) -> Int32 {
        let node = allocRecord(kind, -1, 0, false)
        appendChildAt(node, child0)
        appendChildAt(node, child1)
        return node
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, child0: consuming Int32, child1: consuming Int32, child2: consuming Int32) -> Int32 {
        let node = allocRecord(kind, -1, 0, false)
        appendChildAt(node, child0)
        appendChildAt(node, child1)
        appendChildAt(node, child2)
        return node
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, child0: consuming Int32, child1: consuming Int32, child2: consuming Int32, child3: consuming Int32) -> Int32 {
        let node = allocRecord(kind, -1, 0, false)
        appendChildAt(node, child0)
        appendChildAt(node, child1)
        appendChildAt(node, child2)
        appendChildAt(node, child3)
        return node
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, name: String) -> Int32 {
        allocRecord(kind, internText(name), 0, false)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, ownedBytes bytes: consuming [UInt8]) -> Int32 {
        // Pure-ASCII assembled bytes (the overwhelming case) pool verbatim —
        // no `String` is ever built. Non-ASCII bytes round-trip through
        // `String(decoding:)` so ill-formed sequences take the identical
        // U+FFFD replacements the value backend's `String` carries.
        let assembled = consume bytes
        if ownedRanges.capacity == 0 {
            ownedRanges.reserveCapacity(8)
            ownedBytes.reserveCapacity(256)
        }
        let start = ownedBytes.count
        var allASCII = true
        for byte in assembled where byte >= 0x80 {
            allASCII = false
            break
        }
        if allASCII {
            ownedBytes.append(contentsOf: assembled)
        } else {
            ownedBytes.append(contentsOf: String(decoding: assembled, as: UTF8.self).utf8)
        }
        let ref = Self.poolRef(ownedRanges.count)
        ownedRanges.append(start ..< ownedBytes.count)
        return allocRecord(kind, ref, 0, false)
    }

    @inline(__always) func make(kind: SwiftSymbol.Kind, index: UInt64) -> Int32 {
        allocRecord(kind, -1, index, true)
    }

    /// A verbatim `.Identifier` tagged as the input slice `[start, start+count)` —
    /// no `String`, no `texts` entry, just a range into ``inputBytes`` (which the
    /// printer appends straight to its output buffer). `input` is the demangle's
    /// buffer; the first verbatim identifier binds it (retaining it exactly once
    /// for the whole demangle+print), later identifiers of the same demangle skip
    /// the bind — so the range is resolvable at render/read/reify time.
    @inline(__always) func makeIdentifier(_ input: borrowing [UInt8], start: Int, count: Int) -> Int32 {
        if !inputBound {
            inputBytes = copy input
            inputBound = true
        }
        return allocRecord(.Identifier, -1, 0, false, inputStart: Int32(truncatingIfNeeded: start), inputCount: Int32(truncatingIfNeeded: count))
    }

    // MARK: Reading

    @inline(__always) func kind(of node: borrowing Int32) -> SwiftSymbol.Kind {
        recordsPtr[Int(copy node)].kind
    }

    @inline(__always) func text(of node: borrowing Int32) -> String? {
        let record = recordsPtr[Int(copy node)]
        if record.inputStart >= 0 {
            let start = Int(record.inputStart)
            return String(decoding: inputBytes[start ..< start + Int(record.inputCount)], as: UTF8.self)
        }
        if record.textRef >= 0 { return texts[Int(record.textRef)] }
        // Pool bytes are valid UTF-8 by construction, so this decode
        // reproduces exactly the `String` a string-storing arena carried.
        if record.textRef <= -2 { return String(decoding: ownedBytes[poolRange(record.textRef)], as: UTF8.self) }
        return nil
    }

    @inline(__always) func hasText(of node: borrowing Int32) -> Bool {
        let record = recordsPtr[Int(copy node)]
        return record.inputStart >= 0 || record.textRef != -1
    }

    /// Bytes of `array[start ..< end]` equal `constant`'s UTF-8 — a manual
    /// loop; the generic `elementsEqual` iterator pairing profiled on the
    /// (very hot) module/sugar text probes.
    @inline(__always)
    private static func bytesEqual(_ array: [UInt8], _ start: Int, _ end: Int, _ constant: String) -> Bool {
        var i = start
        for byte in constant.utf8 {
            if i >= end || array[i] != byte { return false }
            i += 1
        }
        return i == end
    }

    /// Bytes of `array[start ..< end]` begin with `prefix`'s UTF-8.
    @inline(__always)
    private static func bytesHavePrefix(_ array: [UInt8], _ start: Int, _ end: Int, _ prefix: String) -> Bool {
        var i = start
        for byte in prefix.utf8 {
            if i >= end || array[i] != byte { return false }
            i += 1
        }
        return true
    }

    /// Byte comparison against a pure-ASCII engine constant — no `String`
    /// materialized for a verbatim identifier OR an owned text (see the seam
    /// contract in ``NodeBuilder/textEquals(_:_:)``: for an ASCII constant,
    /// byte equality and `String` canonical equality coincide — equal ASCII
    /// bytes are the same string, and no non-ASCII sequence canonically
    /// normalizes into pure ASCII, so both give `false` there too). A
    /// payload-free node never matches (`text(of:) == constant` with a `nil`
    /// left side).
    @inline(__always) func textEquals(_ node: borrowing Int32, _ constant: String) -> Bool {
        let record = recordsPtr[Int(copy node)]
        if record.inputStart >= 0 {
            let start = Int(record.inputStart)
            return Self.bytesEqual(inputBytes, start, start + Int(record.inputCount), constant)
        }
        if record.textRef >= 0 { return texts[Int(record.textRef)] == constant }
        if record.textRef <= -2 {
            let range = poolRange(record.textRef)
            return Self.bytesEqual(ownedBytes, range.lowerBound, range.upperBound, constant)
        }
        return false
    }

    /// As ``textEquals(_:_:)`` but with `(text(of:) ?? "")` semantics: a
    /// payload-free node matches the empty constant (the `printContext`
    /// hidden-module probe).
    @inline(__always) func textEqualsOrEmpty(_ node: borrowing Int32, _ constant: String) -> Bool {
        let record = recordsPtr[Int(copy node)]
        if record.inputStart >= 0 {
            let start = Int(record.inputStart)
            return Self.bytesEqual(inputBytes, start, start + Int(record.inputCount), constant)
        }
        if record.textRef >= 0 { return texts[Int(record.textRef)] == constant }
        if record.textRef <= -2 {
            let range = poolRange(record.textRef)
            return Self.bytesEqual(ownedBytes, range.lowerBound, range.upperBound, constant)
        }
        return constant.isEmpty
    }

    /// Byte-prefix probe against a pure-ASCII engine constant: a verbatim
    /// (ASCII-by-construction) identifier compares its input bytes with no
    /// `String`; a `String`-form owned text keeps `String.hasPrefix`
    /// exactly. Pool text byte-compares too, EXCEPT when the byte after a
    /// matching prefix is a non-ASCII continuation — `String.hasPrefix` is
    /// grapheme-aligned, and a combining scalar right after the prefix would
    /// extend its last character — so only that (pathological, never seen in
    /// real symbols) case decodes and asks `String` itself.
    @inline(__always) func textHasPrefix(_ node: borrowing Int32, _ prefix: String) -> Bool {
        let record = recordsPtr[Int(copy node)]
        if record.inputStart >= 0 {
            let count = Int(record.inputCount)
            guard prefix.utf8.count <= count else { return false }
            let start = Int(record.inputStart)
            return Self.bytesHavePrefix(inputBytes, start, start + count, prefix)
        }
        if record.textRef >= 0 { return texts[Int(record.textRef)].hasPrefix(prefix) }
        guard record.textRef <= -2 else { return prefix.isEmpty }
        let range = poolRange(record.textRef)
        guard Self.bytesHavePrefix(ownedBytes, range.lowerBound, range.upperBound, prefix) else { return false }
        let next = range.lowerBound + prefix.utf8.count
        if next == range.upperBound || ownedBytes[next] < 0x80 { return true }
        return String(decoding: ownedBytes[range], as: UTF8.self).hasPrefix(prefix)
    }

    /// Append `node`'s text bytes to `bytes`: a verbatim identifier memcpy's its
    /// input slice straight through (zero-copy — no `String`, no per-identifier
    /// allocation, the stage-C3 win); owned text memcpy's its pool slice the
    /// same way; a payload-free node appends nothing. Byte-for-byte equal to
    /// appending `text(of:) ?? ""`.
    @inline(__always) func appendText(of node: borrowing Int32, to bytes: inout [UInt8]) {
        let record = recordsPtr[Int(copy node)]
        if record.inputStart >= 0 {
            let start = Int(record.inputStart)
            bytes.append(contentsOf: inputBytes[start ..< start + Int(record.inputCount)])
        } else if record.textRef >= 0 {
            bytes.append(contentsOf: texts[Int(record.textRef)].utf8)
        } else if record.textRef <= -2 {
            bytes.append(contentsOf: ownedBytes[poolRange(record.textRef)])
        }
    }

    @inline(__always) func index(of node: borrowing Int32) -> UInt64? {
        let record = recordsPtr[Int(copy node)]
        return record.hasIndex ? record.indexPayload : nil
    }

    @inline(__always) func childCount(of node: borrowing Int32) -> Int {
        Int(recordsPtr[Int(copy node)].childCount)
    }

    @inline(__always) func child(of node: borrowing Int32, at index: Int) -> Int32 {
        childPtr[Int(recordsPtr[Int(copy node)].childStart) + index]
    }

    @inline(__always) func firstChild(of node: borrowing Int32) -> Int32? {
        let record = recordsPtr[Int(copy node)]
        return record.childCount > 0 ? childPtr[Int(record.childStart)] : nil
    }

    @inline(__always) func lastChild(of node: borrowing Int32) -> Int32? {
        let record = recordsPtr[Int(copy node)]
        return record.childCount > 0 ? childPtr[Int(record.childStart) + Int(record.childCount) - 1] : nil
    }

    // MARK: In-place assembly

    @inline(__always) func appendChild(to node: inout Int32, _ child: consuming Int32) {
        appendChildAt(node, child)
    }

    @inline(__always) func setChild(of node: inout Int32, at index: Int, to child: consuming Int32) {
        // Conservative depth bound, as the value backend's `setChild`: the
        // replacement can only ever raise the recorded depth (a shallower
        // replacement leaves a harmless overestimate against the ~31x margin).
        let replacement = child
        if recordsPtr[Int(node)].depth > Self.ceiling { return } // poisoned stay childless
        let grown = recordsPtr[Int(replacement)].depth + 1
        if grown > Self.ceiling {
            recordsPtr[Int(node)].depth = Self.poisonedDepth
            return
        }
        if grown > recordsPtr[Int(node)].depth { recordsPtr[Int(node)].depth = grown }
        childPtr[Int(recordsPtr[Int(node)].childStart) + index] = replacement
    }

    @inline(__always) func reverseChildren(of node: inout Int32) {
        let record = recordsPtr[Int(node)]
        reverseChildRange(start: Int(record.childStart), count: Int(record.childCount))
    }

    @inline(__always) func reverseChildrenSuffix(of node: inout Int32, from start: Int) {
        let record = recordsPtr[Int(node)]
        let base = Int(record.childStart)
        reverseChildRange(start: base + start, count: Int(record.childCount) - start)
    }

    @inline(__always)
    private func reverseChildRange(start: Int, count: Int) {
        guard count > 1 else { return }
        var lo = start
        var hi = start + count - 1
        while lo < hi {
            let tmp = childPtr[lo]
            childPtr[lo] = childPtr[hi]
            childPtr[hi] = tmp
            lo += 1
            hi -= 1
        }
    }

    /// A *new* node with `newKind`, the same payload, and a fresh copy of the
    /// child run — never a mutation of `node` in place. This mirrors apple's
    /// `changeKind`, which allocates a new node: `popModule` turns a popped
    /// `Identifier` into a `Module` while that same `Identifier` is still live
    /// in the substitution list, so mutating in place would corrupt the
    /// substitution. The child handles are shared (children are immutable once
    /// built), copied into their own run so a later append to either node
    /// cannot disturb the other.
    func changingKind(_ node: consuming Int32, to newKind: SwiftSymbol.Kind) -> Int32 {
        let source = recordsPtr[Int(node)]
        // Carry the verbatim-identifier tag through: `popModule` turns an
        // input-range `Identifier` into a `Module` that must still render from the
        // same input slice (module names are the common `changingKind` case).
        let result = allocRecord(newKind, source.textRef, source.indexPayload, source.hasIndex, inputStart: source.inputStart, inputCount: source.inputCount)
        let count = Int(source.childCount)
        if count > 0 {
            let oldStart = Int(source.childStart)
            for k in 0 ..< count {
                appendChildAt(result, childPtr[oldStart + k])
            }
        }
        return result
    }

    // MARK: Depth ceiling

    @inline(__always) func isDepthPoisoned(_ node: borrowing Int32) -> Bool {
        recordsPtr[Int(copy node)].depth > Self.ceiling
    }

    /// Arena handles are trivial and the slab frees en masse — no drop ever
    /// recurses, so nothing needs routing.
    @inline(__always) func needsRoutedRelease(_: borrowing Int32) -> Bool {
        false
    }

    func releaseDeep(_: consuming [Int32]) {}

    // MARK: `SwiftSymbol` boundary

    /// Reify the arena subtree at `node` into a public ``SwiftSymbol`` value
    /// tree. Used only at the public boundary and on the two `SwiftSymbol`-only
    /// interior seams (the opaque-return-type parenting rewrite, and the
    /// old-`_T`/symbolic-reference handoffs) — never on the hot string path.
    func materialize(_ node: Int32) -> SwiftSymbol {
        let record = recordsPtr[Int(node)]
        let contents: SwiftSymbol.Contents = if record.inputStart >= 0 {
            // Reify the verbatim input slice into the identical owned `String` the
            // value backend would carry (the slice is ASCII, so the decode is exact).
            .name(String(decoding: inputBytes[Int(record.inputStart) ..< Int(record.inputStart) + Int(record.inputCount)], as: UTF8.self))
        } else if record.textRef >= 0 {
            .name(texts[Int(record.textRef)])
        } else if record.textRef <= -2 {
            // Pool bytes are valid UTF-8 by construction — this decodes to
            // the exact `String` a string-storing arena carried.
            .name(String(decoding: ownedBytes[poolRange(record.textRef)], as: UTF8.self))
        } else if record.hasIndex {
            .index(record.indexPayload)
        } else {
            .none
        }
        let count = Int(record.childCount)
        guard count > 0 else { return SwiftSymbol(kind: record.kind, children: [], contents: contents) }
        var children: [SwiftSymbol] = []
        children.reserveCapacity(count)
        let start = Int(record.childStart)
        for k in 0 ..< count {
            children.append(materialize(childPtr[start + k]))
        }
        return SwiftSymbol(kind: record.kind, children: children, contents: contents)
    }

    /// Absorb a public ``SwiftSymbol`` subtree into the arena — the inverse of
    /// ``materialize(_:)``. The engine hands back `SwiftSymbol`s from the old
    /// demangler, the symbolic-reference resolver, and the opaque-return
    /// rewrite; this brings them into handle space so the rest of the tree can
    /// reference them uniformly.
    func adopt(_ symbol: SwiftSymbol) -> Int32 {
        let textRef: Int32
        let indexPayload: UInt64
        let hasIndex: Bool
        switch symbol.contents {
        case .none:
            textRef = -1; indexPayload = 0; hasIndex = false
        case let .name(value):
            textRef = internText(value); indexPayload = 0; hasIndex = false
        case let .index(value):
            textRef = -1; indexPayload = value; hasIndex = true
        }
        let node = allocRecord(symbol.kind, textRef, indexPayload, hasIndex)
        for child in symbol.children {
            appendChildAt(node, adopt(child))
        }
        return node
    }
}
