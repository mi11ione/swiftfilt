// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// The engine's two depth bounds. The printer cap renders `<<too complex>>`
/// exactly as `swift-demangle`'s `NodePrinter` does (oracle-verified). The
/// construction ceiling makes an over-deep parse fail like any malformed input —
/// the builders refuse it and the refusal null-propagates, so no over-deep tree
/// ever exists to render a partial guess. Decline cases run on the ordinary
/// stack on purpose (no deep tree is built — surviving unaided is the regression
/// proof); render cases host on a large stack.
@Suite("Depth ceiling and printer cap")
struct DepthCeilingTests {
    private let demangler = SwiftDemangler()

    /// `$s Say×n Si G×n D` — Array sugar nested `n` deep (about three tree
    /// levels per `Say`; the construction ceiling crosses near n ≈ 1365).
    private func nestedArrays(_ depth: Int, tail: String = "D") -> String {
        "$s" + String(repeating: "Say", count: depth) + "Si"
            + String(repeating: "G", count: depth) + tail
    }

    // MARK: Printer cap — the render band

    @Test func shallowNestingRendersInFull() async {
        let expected = String(repeating: "[", count: 100) + "Swift.Int"
            + String(repeating: "]", count: 100)
        let rendered = await onLargeStack { demangle(nestedArrays(100)) }
        #expect(rendered == expected)
    }

    @Test func nestingPastThePrinterCapRendersTheReferenceMarker() async {
        // 500 Array levels: past the printer cap, under the construction
        // ceiling. The reference renders 383 brackets around the marker.
        let expected = String(repeating: "[", count: 383) + "<<too complex>>"
            + String(repeating: "]", count: 383)
        let rendered = await onLargeStack { demangle(nestedArrays(500)) }
        #expect(rendered == expected)
    }

    @Test func optionalNestingPastThePrinterCapMatchesTheReference() async {
        // 1,000 Optional-sugar levels: the reference caps the inner type
        // and renders the surviving suffix run.
        let mangled = "$sSi" + String(repeating: "Sg", count: 1000)
        let expected = "<<too complex>>" + String(repeating: "?", count: 384)
        let rendered = await onLargeStack { demangle(mangled) }
        #expect(rendered == expected)
    }

    // MARK: Construction ceiling — the decline band

    @Test func nestingPastTheCeilingDeclines() {
        let mangled = nestedArrays(2000)
        #expect(demangle(mangled) == nil)
        #expect(demangler.demangle(symbol: mangled) == nil)
    }

    @Test func declinePastTheCeilingIsMalformed() {
        // Swift-prefixed but unparseable classifies as `.malformed`,
        // like every other structural refusal.
        #expect(throws: DemangleError.malformed) {
            try demangle(validating: nestedArrays(2000))
        }
    }

    @Test func optionalNestingPastTheCeilingDeclines() {
        let mangled = "$sSi" + String(repeating: "Sg", count: 2500)
        #expect(demangle(mangled) == nil)
    }

    @Test func deepTypeManglingDeclines() {
        let type = "Si" + String(repeating: "Sg", count: 2500)
        #expect(demangler.demangle(type: type) == nil)
    }

    @Test func deepPrefixWithAGarbageTailDeclinesCleanly() {
        // The over-deep construction fails the parse before the garbage
        // tail is even reached; the teardown is ceiling-bounded by
        // construction.
        let mangled = nestedArrays(2000, tail: "%%")
        #expect(demangler.demangle(symbol: mangled) == nil)
    }

    @Test func longTypeParseWithLeftoverNodesDeclines() {
        // A long window whose parse leaves more than one node on the
        // stack: the type entry declines; nothing here is deep.
        let type = String(repeating: "Si", count: 2100)
        #expect(demangler.demangle(type: type) == nil)
    }

    // MARK: Length is not depth — long but shallow stays demangled

    @Test func longButShallowSymbolsStillDemangle() {
        let name = String(repeating: "A", count: 5000)
        let mangled = "$s5000" + name + "3fooyyF"
        #expect(demangle(mangled) == "\(name).foo() -> ()")
    }

    // MARK: Value backend, shape by shape

    @Test func valueBackendDeclinesOptionalChains() {
        // Optional sugar nests through the single-child make; the ceiling
        // refusal routes the deep child through the topological release.
        let mangled = "$sSi" + String(repeating: "Sg", count: 2500)
        #expect(demangler.demangle(symbol: mangled) == nil)
    }

    @Test func deepTypeParseWithALeftoverNodeDrainsAndDeclines() {
        // The parse ends with a deep chain AND a second node on the stack:
        // the type entry declines and routes the regions' last references
        // through the deep release.
        let type = "Si" + String(repeating: "Sg", count: 800) + "Si"
        #expect(demangler.demangle(type: type) == nil)
    }

    @Test func legalDeepPrefixWithAGarbageTailDrainsRouted() {
        // In-ceiling deep tree already parsed, then the tail fails the
        // parse: the nil exit drains the regions through the routed
        // release instead of a depth-recursive teardown.
        let mangled = nestedArrays(1300, tail: "%%")
        #expect(demangler.demangle(symbol: mangled) == nil)
    }

    @Test func ceilingBoundaryNeverFabricates() async {
        // Straddle the crossover: each depth either renders (capped, with
        // the reference marker) or declines to nil — never a partial tree
        // presented as a demangling. Hosted on a large stack: the render
        // side of the boundary descends to the printer cap. Both backends
        // probed (the product function and the raw value-tree API).
        let failures = await onLargeStack {
            var bad: [String] = []
            for depth in 2040 ... 2055 {
                let mangled = "$sSi" + String(repeating: "Sg", count: depth)
                if let rendered = demangle(mangled), !rendered.contains("<<too complex>>") {
                    bad.append("Sg \(depth): \(rendered.prefix(30))")
                }
                _ = SwiftDemangler().demangle(symbol: mangled)
            }
            // Metatype chains cross through the single-child make at every
            // second level — stepping one level at a time walks the exact
            // crossing through both parities.
            for depth in 2044 ... 2052 {
                let mangled = "$sSi" + String(repeating: "m", count: depth)
                if let rendered = demangle(mangled), !rendered.contains("<<too complex>>") {
                    bad.append("m \(depth): \(rendered.prefix(30))")
                }
                _ = SwiftDemangler().demangle(symbol: mangled)
            }
            return bad
        }
        #expect(failures.isEmpty, "boundary fabrications: \(failures)")
    }

    @Test func adoptRefusesAnOverCeilingResolverTree() async {
        // A symbolic-reference resolver can hand back an arbitrarily deep
        // consumer-built tree; adoption measures it iteratively and refuses
        // past the ceiling, so the parse declines instead of importing an
        // unwalkable tree. (Hosted on a large stack: the test's own deep
        // value tree recurses its depth when the test drops it.)
        let declined = await onLargeStack {
            var deep = SwiftSymbol(kind: .Structure)
            for _ in 0 ..< 4200 {
                deep = SwiftSymbol(kind: .`Type`, child: deep)
            }
            let tree = deep
            let resolver: SymbolicReferenceResolver = { _, _, _, _ in tree }
            // "$s" + 0x01 + 4-byte offset + "4main3fooyyF"-ish tail; the
            // resolver's answer stands in for the referenced context.
            var bytes: [UInt8] = Array("$s".utf8)
            bytes.append(0x01)
            bytes.append(contentsOf: [0, 0, 0, 0])
            bytes.append(contentsOf: Array("3fooyyF".utf8))
            return SwiftDemangler().demangle(symbolBytes: bytes, resolveSymbolicReference: resolver) == nil
        }
        #expect(declined)
    }

    // MARK: Old grammar keeps its own (reference) ceiling

    @Test func oldGrammarMetatypeNestingStillDeclines() async {
        // The old demangler's recursive descent is bounded by its own
        // reference `maxDepth` (1024 frames before declining) — hosted on
        // a large stack because those frames are real, then declined.
        let mangled = "_Tt" + String(repeating: "M", count: 2000) + "Si"
        let result = await onLargeStack { SwiftDemangler().demangle(symbol: mangled) }
        #expect(result == nil)
    }

    // MARK: treeDump walks iteratively — no per-level native recursion

    @Test func treeDumpRendersTreesDeeperThanTheConstructionCeiling() async {
        // `treeDump()` walks an explicit heap stack, so it has no depth cap
        // of its own — it renders a `SwiftSymbol` a caller hand-built past
        // the engine's 4,096 construction ceiling (a shape the demangler
        // itself never produces). Built and released on a large stack (the
        // value tree's own construction and drop recurse its depth); the
        // dump between them is the iterative walk under test. 6,000 `.Type`
        // wrappers over one `.Structure` leaf → 6,001 pre-order lines, the
        // root unindented and the leaf at 6,000 levels of indent.
        let (lineCount, firstLine, lastLine) = await onLargeStack {
            var deep = SwiftSymbol(kind: .Structure)
            for _ in 0 ..< 6000 {
                deep = SwiftSymbol(kind: .`Type`, child: deep)
            }
            let dump = deep.treeDump()
            let lines = dump.split(separator: "\n", omittingEmptySubsequences: false)
            // split leaves a trailing empty element after the final newline.
            return (lines.count - 1, String(lines.first ?? ""), String(lines[lines.count - 2]))
        }
        #expect(lineCount == 6001)
        #expect(firstLine == "kind=Type")
        #expect(lastLine == String(repeating: " ", count: 6000 * 2) + "kind=Structure")
    }
}
