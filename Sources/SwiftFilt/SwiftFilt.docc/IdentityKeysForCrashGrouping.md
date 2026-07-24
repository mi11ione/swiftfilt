# Identity keys for crash grouping

One canonical key per logical function — the grouping primitive crash
pipelines hand-roll with regexes, computed structurally instead.

## Overview

A crash reporter sees one source-level function under many symbol names:
generic specializations, async partials, `@objc` thunks, outlined copies,
`.cold.1` suffixes. Grouping by demangled string splits one bug into a
dozen buckets; grouping by regex merges bugs that differ.
``DemangledSymbol/identityKey`` computes the grouping on the demangling
tree:

```swift
let a = try DemangledSymbol(parsing: "$s4main3fooyyFSi_Tg5")   // specialized for Int
let b = try DemangledSymbol(parsing: "$s4main3fooyyFSS_Tg5")   // specialized for String
let c = try DemangledSymbol(parsing: "$s4main3fooyyF")         // the generic origin

a.identityKey == b.identityKey   // true
b.identityKey == c.identityKey   // true
```

Two symbols share a key exactly when they are compiler-generated
variants of the same source-level code.

## What collapses into one key

| variant | keys as |
| --- | --- |
| Generic / function-signature / prespecialized / partial / inlined-generic specializations (`…Tg5`, `…Tp5q`, `Ti`, resilience-domain) | the unspecialized generic origin |
| Async partials (`TQn_`/`TYn_` await- and suspend-resume) and LLVM `.resume.N`-style suffixed pieces | the `async` function itself |
| Dispatch-flavor annotations: `@objc` (`To`) / non-ObjC (`TO`) bridging, dynamic/direct dispatch markers, vtable attributes, merged-function (`Tm`), outlined per-function artifacts (`Tv`), dynamic-replacement machinery (`TI`/`TX`/`Tx`), async function-pointer records (`Tu`), accessible-function records, `#_hasSymbol` queries, default-override and distributed markers | the underlying declaration |
| Back deployment: the `Twb` thunk and `TwB` fallback copy | the original function |
| Forwarders whose full target is embedded in the mangling: partial-apply forwarders (`TA`/`Ta`), curry thunks (`Tc`), dispatch thunks (`Tj`), SIL identity thunks | their target (recursively — a dispatch thunk of a curry thunk unwraps twice) |
| Entry-point flavors: allocating `__allocating_init` (`fC`); deallocating / isolated-deallocating `deinit` (`fD`/`fZ`) | the `init` (`fc`) / the plain `deinit` (`fd`) |

## What deliberately keeps its own key

| symbol | why it stays distinct |
| --- | --- |
| Protocol witnesses | a witness is per-conformance code; collapsing into the requirement would merge every conforming type's witnesses, and collapsing into the concrete method would *guess* at a symbol the mangling does not carry (for defaulted requirements no such method exists). Silent skip, never silent guess. |
| Reabstraction thunks | their mangling carries only the two function signatures, never a target |
| Key-path helpers, vtable thunks, ObjC async completion shims, outlined value-witness helpers | each is genuinely distinct executable code, not a duplicate of its subject |
| Accessors | a getter and a setter of one property are different code |
| Overloads | argument labels and types stay in the key — `foo(_: Int)` and `foo(_: String)` never merge |

## The printed form

``DemangledSymbol/IdentityKey/rawValue`` is the
``DemangleStyle/qualified`` (no-sugar, fully-qualified — the most
canonical validated preset) rendering of the normalized tree:

```
Accelerate.BNNS.arrayToTuple(_: Swift.Array<A>, fillValue: A) -> (A, A, A, A, A, A, A, A)
```

for every specialization of that function. Private-declaration
discriminators are kept, so two private `foo`s in different files stay
distinct. For degenerate manglings that normalize to nothing, the key
falls back to the un-normalized rendering, then to the mangled name itself
— a demangleable symbol never produces an empty key.

## Stability and persistence

The key is deterministic: one input, one key, on every run and platform.
Compare keys from the same SwiftFilt version; across versions the grammar
(and thus spellings) can evolve, so persist the `rawValue` string and
re-derive rather than assume it eternal. There is deliberately no
`init(rawValue:)` — a key always comes from a demangling, so a stored
string can never smuggle in an unvalidated identity.

## From the command line

Every `--json` record carries the same key, so a shell one-liner
crash-groups a log:

```sh
swiftfilt --json --slim < crash.log | jq -r .identityKey | sort | uniq -c | sort -rn
```
