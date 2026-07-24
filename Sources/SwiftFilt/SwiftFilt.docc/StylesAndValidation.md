# Styles and validation

The four rendering presets, what each one is for, and exactly what
"validated" means for each.

## Overview

``DemangleStyle`` offers four presets and deliberately nothing else: every
one is held to byte-parity with a `swift-demangle` output mode over the
golden corpus of real-world symbols. An arbitrary printer-option
combination would carry no such guarantee, so the library does not offer
one.

```swift
let name = "$s4main6ServerC5start4portySi_tF"
demangle(name)                       // .full is the default
demangle(name, style: .simplified)   // "start(port:)"
demangle(name, style: .qualified)    // no type sugar
demangle(name, style: .unqualified)  // no module/context qualification
```

## The presets

| preset | oracle mode | rendering |
| --- | --- | --- |
| ``DemangleStyle/full`` | plain `swift-demangle` (`-compact`) | fully qualified, sugared types, full signatures — `main.fetch(url: Foundation.URL) async throws -> [Swift.Int]`. What most Apple tooling shows. |
| ``DemangleStyle/simplified`` | `swift-demangle -simplified` | the crash-reporter rendering: no module qualification, no argument/return types, no specialization payloads; thunks shorten to a marker — `fetch(url:)`, `closure #1 in viewDidLoad()`. |
| ``DemangleStyle/qualified`` | `swift-demangle -no-sugar` | fully qualified with every type spelled canonically (`Swift.Optional<Swift.Int>`, never `Int?`) — the most comparison-stable rendering; ``DemangledSymbol/identityKey`` prints in it. |
| ``DemangleStyle/unqualified`` | none exists | sugared types with no module/context qualification — `fetch(url: URL) async throws -> [Int]`, for displays where context is known. |

## What each validation leg proves

The in-repo parity instrument (`swiftfilt-parity`, not part of this
library's API) re-earns the styles' claims on every change, per leg:

- **full / simplified / qualified** — byte-parity against the
  corresponding `swift-demangle` mode, over the committed golden corpus
  on every PR and over a 13,074,789-symbol real-world corpus at
  acceptance.
- **tree** — node-for-node agreement of the demangling tree with
  `swift-demangle -tree-only`, so the structure every curated field is
  computed from matches the reference, not just the printed text.
- **classify** — the `{N}` / `{T:target}` / `{C}` marker semantics
  against `swift-demangle -classify`.
- **decline agreement** — what the oracle refuses to demangle,
  SwiftFilt refuses too, and vice versa: completeness is validated in
  both directions, so the library neither misses names nor invents
  demanglings for junk.
- **roundtrip** — demangle → remangle (``SwiftMangler``) → compare,
  adjudicated against the reference remangler, so the tree is proven
  faithful enough to reproduce its own mangling.

**The honest asterisk: `unqualified` is exercised, not oracled.**
`swift-demangle` has no unqualified output mode, so no oracle leg can
exist for it. Its live leg gates on crash/hang/emptiness only; its
rendering substance is owned by the library's fixture suites. It is
the only preset whose text is not oracle-anchored, and this is stated
wherever the styles are claimed validated.

Every known divergence between SwiftFilt and the oracle is catalogued
with evidence in the repository's `KNOWN-DEVIATIONS.md`; the parity
contract is zero unexplained rows.

## Choosing a preset

Crash-frame UIs want ``DemangleStyle/simplified``. Anything that compares,
groups, or persists names wants ``DemangleStyle/qualified`` — sugar
spellings can evolve, canonical spellings are stable, and identity keys
already use it. Everything user-facing that needs the whole story wants
``DemangleStyle/full``. Output is deterministic per library version in
every preset; rendering changes arrive only in minor releases.
