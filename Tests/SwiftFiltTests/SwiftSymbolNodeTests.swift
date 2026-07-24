// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The `SwiftSymbol` AST node value type: every initializer, the text/index/firstChild accessors, the in-place and copying mutators, and the `SwiftSymbol.Contents` payload union.
@Suite("SwiftSymbol node construction and accessors")
struct SwiftSymbolNodeTests {
    @Test func generalInitializerStoresAllFields() {
        let child = SwiftSymbol(kind: .Identifier, name: "x")
        let node = SwiftSymbol(kind: .Global, children: [child], contents: .index(7))
        #expect(node.kind == .Global)
        #expect(node.children == [child])
        #expect(node.contents == .index(7))
    }

    @Test func singleChildInitializerHasNoPayload() {
        let child = SwiftSymbol(kind: .Module, name: "Swift")
        let node = SwiftSymbol(kind: .`Type`, child: child)
        #expect(node.children == [child])
        #expect(node.contents == .none)
        #expect(node.firstChild == child)
    }

    @Test func nameInitializerCarriesTextPayload() {
        let node = SwiftSymbol(kind: .Identifier, name: "Foo")
        #expect(node.contents == .name("Foo"))
        #expect(node.text == "Foo")
        #expect(node.index == nil)
    }

    @Test func indexInitializerCarriesIndexPayload() {
        let node = SwiftSymbol(kind: .Number, index: 42)
        #expect(node.contents == .index(42))
        #expect(node.index == 42)
        #expect(node.text == nil)
    }

    @Test func noPayloadAccessorsAreNil() {
        let node = SwiftSymbol(kind: .EmptyList)
        #expect(node.contents == .none)
        #expect(node.text == nil)
        #expect(node.index == nil)
    }

    @Test func firstChildIsNilWhenChildless() {
        #expect(SwiftSymbol(kind: .EmptyList).firstChild == nil)
    }

    @Test func addChildMutatesInPlace() {
        var node = SwiftSymbol(kind: .Global)
        let child = SwiftSymbol(kind: .Identifier, name: "a")
        node.addChild(child)
        #expect(node.children == [child])
    }

    @Test func addingChildReturnsCopyPreservingPayload() {
        let base = SwiftSymbol(kind: .Identifier, name: "n")
        let child = SwiftSymbol(kind: .Number, index: 1)
        let extended = base.adding(child: child)
        #expect(extended.children == [child])
        #expect(extended.contents == .name("n"))
        #expect(base.children.isEmpty) // original unchanged
    }

    @Test func changingKindPreservesChildrenAndPayload() {
        let original = SwiftSymbol(kind: .Structure, name: "S", children: [SwiftSymbol(kind: .Module, name: "M")])
        let changed = original.changingKind(to: .Class)
        #expect(changed.kind == .Class)
        #expect(changed.children == original.children)
        #expect(changed.contents == original.contents)
    }

    @Test func equalAndHashableByValue() {
        let a = SwiftSymbol(kind: .Identifier, name: "x")
        let b = SwiftSymbol(kind: .Identifier, name: "x")
        let c = SwiftSymbol(kind: .Identifier, name: "y")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test func contentsCasesAreDistinct() {
        #expect(SwiftSymbol.Contents.none != .name(""))
        #expect(SwiftSymbol.Contents.name("0") != .index(0))
        #expect(SwiftSymbol.Contents.index(0) != .index(1))
    }
}

/// `treeDump()` renders exactly like the reference `NodeDumper`: two-space indent per depth, `kind=<name>`, an at-most-one `, text="…"`/`, index=…` payload (no escaping), newline, then children.
@Suite("SwiftSymbol tree dump serialization")
struct SwiftSymbolTreeDumpTests {
    @Test func singleNodeNoPayload() {
        #expect(SwiftSymbol(kind: .EmptyList).treeDump() == "kind=EmptyList\n")
    }

    @Test func textPayloadIsQuoted() {
        #expect(SwiftSymbol(kind: .Identifier, name: "Foo").treeDump() == "kind=Identifier, text=\"Foo\"\n")
    }

    @Test func indexPayloadIsDecimal() {
        #expect(SwiftSymbol(kind: .Number, index: 42).treeDump() == "kind=Number, index=42\n")
    }

    @Test func childrenIndentByTwoSpacesPerDepth() {
        let node = SwiftSymbol(kind: .`Type`, child:
            SwiftSymbol(kind: .Structure, children: [
                SwiftSymbol(kind: .Module, name: "M"),
                SwiftSymbol(kind: .Identifier, name: "S"),
            ]))
        let expected = """
        kind=Type
          kind=Structure
            kind=Module, text="M"
            kind=Identifier, text="S"

        """
        #expect(node.treeDump() == expected)
    }

    @Test func textIsNotEscaped() {
        // The reference dumper applies no escaping: an embedded quote, newline,
        // or backslash is emitted verbatim.
        let node = SwiftSymbol(kind: .Identifier, name: "a\"b\\c")
        #expect(node.treeDump() == "kind=Identifier, text=\"a\"b\\c\"\n")
    }

    @Test func protocolKindDumpsCanonicalName() {
        // `protocolNode` keeps the canonical ABI spelling "Protocol" in the dump.
        #expect(SwiftSymbol(kind: .protocolNode).treeDump() == "kind=Protocol\n")
    }
}
