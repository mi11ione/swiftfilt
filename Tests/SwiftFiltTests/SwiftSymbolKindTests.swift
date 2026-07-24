// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// `SwiftSymbol.Kind`: enumerates the full node-kind universe, each case's `name` is its canonical ABI spelling (the tree-dump diff target), and the spelling round-trips through the raw value.
@Suite("SwiftSymbol.Kind node-kind universe")
struct SwiftSymbolKindTests {
    @Test func enumeratesTheFullKindUniverse() {
        // One case per DemangleNodes.def enumerator plus the three
        // ReferenceStorage.def entries — well over 370 distinct kinds.
        #expect(SwiftSymbol.Kind.allCases.count > 370)
    }

    @Test func everyCaseNameEqualsItsRawValue() {
        for kind in SwiftSymbol.Kind.allCases {
            #expect(kind.name == kind.rawValue)
        }
    }

    @Test func everyCaseNameRoundTripsThroughRawValue() {
        for kind in SwiftSymbol.Kind.allCases {
            #expect(SwiftSymbol.Kind(rawValue: kind.name) == kind)
        }
    }

    @Test func everyCaseNameIsNonEmptyAndUnique() {
        let names = SwiftSymbol.Kind.allCases.map(\.name)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test func protocolNodeKeepsCanonicalSpelling() {
        // The one renamed case: `Protocol` is not a legal enum identifier, so
        // the case is `protocolNode` with an explicit rawValue.
        #expect(SwiftSymbol.Kind.protocolNode.name == "Protocol")
        #expect(SwiftSymbol.Kind(rawValue: "Protocol") == .protocolNode)
    }

    @Test func canonicalSpellingsMatchReference() {
        // Spot-check representative spellings against getNodeKindString.
        #expect(SwiftSymbol.Kind.BoundGenericStructure.name == "BoundGenericStructure")
        #expect(SwiftSymbol.Kind.Global.name == "Global")
        // The `Type` case collides with the `.Type` metatype at the call site,
        // so reach it through its raw value.
        #expect(SwiftSymbol.Kind(rawValue: "Type")?.name == "Type")
        #expect(SwiftSymbol.Kind.TypeMetadataDemanglingCache.name == "TypeMetadataDemanglingCache")
        #expect(SwiftSymbol.Kind.Integer.name == "Integer")
        #expect(SwiftSymbol.Kind.Weak.name == "Weak")
    }

    @Test func unknownRawValueIsNil() {
        #expect(SwiftSymbol.Kind(rawValue: "NotARealNodeKind") == nil)
    }

    @Test func interpolationPrintsTheGrammarSpelling() {
        // description == rawValue — including the two irregular case
        // spellings, so "\(kind)" always matches the --tree output.
        #expect("\(SwiftSymbol.Kind.protocolNode)" == "Protocol")
        let typeKind: SwiftSymbol.Kind = .`Type`
        #expect("\(typeKind)" == "Type")
        #expect("\(SwiftSymbol.Kind.Structure)" == "Structure")
        #expect("\(SwiftSymbol.Kind.BoundGenericEnum)" == "BoundGenericEnum")
    }
}
