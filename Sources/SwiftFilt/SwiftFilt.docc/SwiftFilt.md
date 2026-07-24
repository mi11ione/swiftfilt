# ``SwiftFilt``

A corpus-proven Swift demangler with structured output, validated style presets, crash-grouping identity keys, and a text scanner.

## Overview

SwiftFilt turns a mangled Swift symbol name back into meaning — the
demangled string, or the whole structured story: what the symbol is,
where it lives, and which logical function it belongs to.

```swift
import SwiftFilt

demangle("$s4main3fooyyF")                    // "main.foo() -> ()"

let symbol = try DemangledSymbol(parsing: "$s4main6ServerC5start4portySi_tF")
symbol.kind          // .function
symbol.identityKey   // one key for every specialization/thunk of this function
```

What a string-only demangle call cannot give you: structured output
(``DemangledSymbol`` and the full ``SwiftSymbol`` node tree), the four
validated ``DemangleStyle`` presets, every shipped mangling era back to
the legacy `_T` grammar, a typed ``DemangleError``, the crash-grouping
``DemangledSymbol/identityKey``, and a ``MangledNameScanner`` that
rewrites manglings inside arbitrary text. The engine is a pure-Swift port
of apple/swift's demangler, held to byte-level parity with
`swift-demangle` over a real-world corpus; no unvalidated rendering is
offered.

No dependencies, no imports — not even Foundation — so it runs anywhere
Swift compiles. The walls (names in, names out, no address resolution,
Swift only) are in <doc:ScopeAndGuarantees>.

Start with <doc:DemangleYourFirstSymbol>, then <doc:TheStructuredSymbol>.
Crash pipelines want <doc:IdentityKeysForCrashGrouping> and
<doc:ScanningArbitraryText>.

## Topics

### Getting started

- <doc:DemangleYourFirstSymbol>
- <doc:TheStructuredSymbol>
- <doc:IdentityKeysForCrashGrouping>
- <doc:ScanningArbitraryText>
- <doc:StylesAndValidation>
- <doc:ScopeAndGuarantees>
- <doc:PerformanceAndTheArena>

### The command-line tool

- <doc:ExplainingASymbol>
- <doc:JSONOutput>
- <doc:CensusYourBinary>

### Essentials

- ``demangle(_:style:)``
- ``demangle(validating:style:)``
- ``demangle(type:style:)``
- ``DemangleSession``
- ``isSwiftMangled(_:)``
- ``DemangleStyle``
- ``DemangleError``

### Structured symbols and crash grouping

- ``DemangledSymbol``
- ``DemangledSymbol/Kind``
- ``DemangledSymbol/IdentityKey``

### Explaining a symbol

- ``SymbolExplanation``
- ``ManglingEra``

### Scanning arbitrary text

- ``demangleAll(in:style:)``
- ``MangledNameScanner``
- ``MangledNameScanner/Match``
- ``MangledNameScanner/ByteMatch``

### The node tier

- ``SwiftDemangler``
- ``SwiftSymbol``
- ``SwiftDemanglerPrinter``
- ``SwiftMangler``
- ``SwiftManglingFlavor``

### Symbolic references

- ``SymbolicReferenceResolver``
- ``SymbolicReferenceKind``
- ``SymbolicReferenceDirectness``
