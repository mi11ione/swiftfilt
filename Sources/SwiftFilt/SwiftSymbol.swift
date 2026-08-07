// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// One node in a demangled Swift symbol's tree — the structured form a
/// mangled name parses into and re-mangles out of.
///
/// Mirrors apple/swift's `swift::Demangle::Node`: a ``Kind``, an ordered list
/// of ``children``, and an at-most-one payload (``Contents`` carries text *or*
/// an index, never both — the payload union of the C++ node). A node with a
/// text/index payload carries no children and vice versa, exactly as the
/// reference parser constructs them, so ``treeDump()`` matches
/// `swift-demangle -tree-only` node-for-node.
@frozen
public struct SwiftSymbol: Sendable, Hashable {
    /// A node's single optional payload: text (identifiers, modules,
    /// operators, builtin names) or an index (numbers, depths, enum-valued
    /// attributes), or neither.
    @frozen
    public enum Contents: Sendable, Hashable {
        case none
        case name(String)
        case index(UInt64)
    }

    /// The structural kind.
    public var kind: Kind
    /// The ordered child nodes.
    public var children: [SwiftSymbol]
    /// The text-or-index payload.
    public var contents: Contents

    /// The fully general initializer.
    @inlinable
    public init(kind: Kind, children: [SwiftSymbol] = [], contents: Contents = .none) {
        self.kind = kind
        self.children = children
        self.contents = contents
    }

    /// A node with one child and no payload.
    @inlinable
    public init(kind: Kind, child: SwiftSymbol) {
        self.init(kind: kind, children: [child], contents: .none)
    }

    /// A node with a text payload (and optional children).
    @inlinable
    public init(kind: Kind, name: String, children: [SwiftSymbol] = []) {
        self.init(kind: kind, children: children, contents: .name(name))
    }

    /// A node with an index payload (and optional children).
    @inlinable
    public init(kind: Kind, index: UInt64, children: [SwiftSymbol] = []) {
        self.init(kind: kind, children: children, contents: .index(index))
    }

    /// The text payload, or `nil` when the node carries an index or nothing.
    @inlinable
    public var text: String? {
        if case let .name(value) = contents { return value }
        return nil
    }

    /// The index payload, or `nil` when the node carries text or nothing.
    @inlinable
    public var index: UInt64? {
        if case let .index(value) = contents { return value }
        return nil
    }

    /// The first child, or `nil` when the node has no children.
    @inlinable
    public var firstChild: SwiftSymbol? {
        children.first
    }

    /// Append `child` in place.
    @inlinable
    public mutating func addChild(_ child: SwiftSymbol) {
        children.append(child)
    }

    /// A copy with `child` appended.
    @inlinable
    public func adding(child: SwiftSymbol) -> SwiftSymbol {
        SwiftSymbol(kind: kind, children: children + [child], contents: contents)
    }

    /// A copy whose ``kind`` is replaced, preserving children and payload.
    @inlinable
    public func changingKind(to newKind: Kind) -> SwiftSymbol {
        SwiftSymbol(kind: newKind, children: children, contents: contents)
    }
}

// MARK: - Tree dump (validation surface)

public extension SwiftSymbol {
    /// Render the subtree exactly as apple/swift's `NodeDumper::printNode`
    /// does (the body of `swift-demangle -tree-only`, without its
    /// `Demangling for …` header): two spaces of indent per depth level, then
    /// `kind=<name>`, then a single optional `, text="<verbatim>"` or
    /// `, index=<decimal>`, then a newline, then each child at depth + 1. No
    /// escaping is applied to text, matching the reference dumper.
    ///
    /// This is the AST-node-level diff target for comparison against the
    /// `swift-demangle` oracle.
    func treeDump() -> String {
        // The accumulator is a UTF-8 byte buffer decoded once at the end, not a
        // growing `String`: the walk itself was a rounding error next to
        // `String`'s per-append grapheme bookkeeping (`_StringGuts.append`,
        // `prepareForAppendInPlace`, `isUniquelyReferenced`, `_updateCountAndFlags`),
        // and the indent was an allocation per node — `String(repeating:count:)`
        // built a fresh string for every line. Byte-exactness is structural: the
        // bytes are the exact concatenation of the pieces' UTF-8, which is what
        // `String.append` stored, so the decode reproduces the former output.
        var out: [UInt8] = []
        // Iterative pre-order walk on an explicit heap stack: no native
        // recursion, so a tree of ANY depth dumps without a stack-depth
        // bound — including a `SwiftSymbol` a caller hand-built past the
        // demangler's construction ceiling (which the engine itself never
        // produces). Byte-identical to the former recursive pre-order:
        // children are pushed in reverse so they pop back into source order,
        // and each node emits the exact same line through the shared helper.
        var stack: [(node: SwiftSymbol, depth: Int)] = [(self, 0)]
        while let (node, depth) = stack.popLast() {
            node.appendTreeDumpLine(into: &out, depth: depth)
            var index = node.children.count - 1
            while index >= 0 {
                stack.append((node.children[index], depth + 1))
                index -= 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Fixed fragments of the dump, as `StaticString` so appending one is a
    /// memcpy from a pointer and a length rather than a `String.UTF8View` walk.
    private static let kindPrefix: StaticString = "kind="
    private static let textPrefix: StaticString = ", text=\""
    private static let indexPrefix: StaticString = ", index="

    private func appendTreeDumpLine(into out: inout [UInt8], depth: Int) {
        out.append(contentsOf: repeatElement(0x20, count: depth * 2)) // spaces
        Self.kindPrefix.withUTF8Buffer { out.append(contentsOf: $0) }
        out.append(contentsOf: kind.name.utf8)
        switch contents {
        case .none: break
        case let .name(value):
            Self.textPrefix.withUTF8Buffer { out.append(contentsOf: $0) }
            out.append(contentsOf: value.utf8)
            out.append(0x22) // '"'
        case let .index(value):
            Self.indexPrefix.withUTF8Buffer { out.append(contentsOf: $0) }
            appendDecimal(value, into: &out)
        }
        out.append(0x0A) // '\n'
    }

    /// The decimal digits of `value` written straight into the buffer — the
    /// bytes `String(value)` would have produced, without the `String`.
    private func appendDecimal(_ value: UInt64, into out: inout [UInt8]) {
        if value == 0 { out.append(0x30); return }
        // UInt64.max is 20 digits; emit least-significant first, then reverse
        // the run just written.
        let start = out.count
        var remaining = value
        while remaining > 0 {
            out.append(0x30 &+ UInt8(remaining % 10))
            remaining /= 10
        }
        var lo = start
        var hi = out.count - 1
        while lo < hi {
            out.swapAt(lo, hi)
            lo += 1
            hi -= 1
        }
    }
}
