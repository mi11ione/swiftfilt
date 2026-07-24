# swiftfilt

A Swift demangler you can pipe, script, and embed — `c++filt` for Swift, on a corpus-proven engine with structured output. A command-line tool first, a Swift library (`SwiftFilt`) underneath.

A crash log through `swiftfilt --simplified`:

```
0   MyApp    0x…104abc123 $s10AppIntents0aB8XPCErrorO9errorCodeSivg + 12
2   MyApp    0x…104abe789 $s4main3fooyyFSi_Tg5 + 4
3   MyApp    0x…104abf012 _$s3foo3barC3bas3zimyAaEC_tFTo + 40
4   libswift 0x…1904aa000 _T013call_protocol1CCAA1PA2aDP3fooSiyFTW + 20
```

becomes

```
0   MyApp    0x…104abc123 AppIntentsXPCError.errorCode.getter + 12
2   MyApp    0x…104abe789 specialized foo() + 4
3   MyApp    0x…104abf012 @objc bar.bas(zim:) + 40
4   libswift 0x…1904aa000 protocol witness for P.foo() in conformance C + 20
```

Every byte that isn't a validated Swift mangling passes through untouched — invalid UTF-8 included — so the filter is safe on anything a pipe carries. Every era demangles: stable-ABI `$s`, Embedded `$e`, Swift 4 `_T0`, the legacy `_T` grammar (frame 4), the `_Tt` names in ObjC metadata, and macro-expansion names.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mi11ione/swiftfilt/main/install.sh | sh
# or
brew install mi11ione/tap/swiftfilt
```

Prebuilt for macOS universal and Linux x86_64/aarch64; builds from source anywhere Swift compiles.

## Filter a crash log, an nm dump, a build log

No arguments means filter mode: stdin to stdout, mangled names rewritten in place, everything else byte-identical. Lines stream as they complete, so `tail -f` renders live.

```sh
swiftfilt < crash.log                      # default: full swift-demangle rendering
tail -f build.log | swiftfilt --simplified # live, frame-name style
nm MyApp | swiftfilt
swift build 2>&1 | swiftfilt               # linker errors become readable
```

`--color` highlights the replacements; mixed C++/Swift logs compose with `swiftfilt < log | c++filt`. On a redirected file or saturated pipe the rewrite spreads across CPU cores automatically — byte-identical and in order (`--jobs N` caps it, `--jobs 1` disables it) — while a live `tail -f` stays strictly line-at-a-time. Rewriting matches `swift-demangle` byte-for-byte, including the quirks: dot-glued text joins the candidate (so linker `.stub`/`.got` rows demangle), demangled text can contain commas and angle brackets (use `--json` when output must stay machine-parseable), and filtering isn't idempotent where a rendering embeds a raw mangled name.

## Ask what a symbol is

Arguments are symbols, one demangling per line; anything that doesn't demangle echoes back unchanged (`c++filt` semantics), so it's script-safe.

```sh
$ swiftfilt '$s4main3fooyyFSi_Tg5'
generic specialization <Swift.Int> of main.foo() -> ()

$ swiftfilt --classify '_$s3foo3barC3bas3zimyAaEC_tFTo'
{T:_$s3foo3barC3bas3zimyAaEC_tF,C} @objc foo.bar.bas(zim: foo.zim) -> ()
```

Styles: default is `swift-demangle`'s full rendering; `--simplified` is the crash-reporter view; `--qualified` spells every type canonically (`Swift.Optional<Swift.Int>`) for comparison-stable output; `--unqualified` drops modules. `--tree` prints the node tree, `--classify` the `swift-demangle -classify` markers. `--type` reads a bare *type* mangling (reflection / `swift-demangle -type`, no `$s` prefix): `swiftfilt --type 'SaySiG'` → `[Swift.Int]`.

## Explain what a symbol is — and why it won't demangle

Every demangler is silent on the symbol that *doesn't* work: a truncated crash frame, a corrupt name, a C++ symbol in a Swift pipeline all echo back with no hint why. `swiftfilt explain` tells the whole story.

```sh
$ swiftfilt explain '$s4main9foo'          # a frame truncated in a log column
  status       malformed — carries a Swift prefix but does not parse
  era          stable-ABI ($s)
  parse        stopped at byte 8 of 11
  reason       an identifier declares 9 bytes but only 3 remain
               likely a name cut short — a frame truncated in a fixed-width log column

$ swiftfilt explain '_Z3fooiii'            # not Swift at all
  status       not a Swift mangled name — no recognized mangling prefix
  looks like   C++ (Itanium _Z) — try c++filt
```

On a name that *does* demangle, `explain` prints the era, kind, module, path, all four styles, and the identity key. With no arguments it reads stdin one symbol per line, and `explain --json` emits one diagnosis object per input (`schemaVersion 1`) — so a *declined* symbol becomes a scriptable record instead of silence. The same diagnosis is a library type, [`SymbolExplanation`](https://swiftpackageindex.com/mi11ione/swiftfilt/documentation).

## Script it

`--json` emits NDJSON under a versioned, add-only schema — one self-contained object per symbol, with the structured fields no text rendering carries:

```sh
$ swiftfilt --json '$s4main3fooyyFSi_Tg5'
{"schemaVersion":1,"mangled":"$s4main3fooyyFSi_Tg5","demangled":"generic specialization <Swift.Int> of main.foo() -> ()","style":"full","module":"main","path":["foo"],"kind":"function","isSpecialized":true,"genericOrigin":"main.foo() -> ()","identityKey":"main.foo() -> ()"}
```

The field worth the price of admission is `identityKey`: one canonical key per *logical function*, computed on the tree — specializations, async partials, `@objc` thunks, and outlined copies all share it. Crash-group a log in one line:

```sh
swiftfilt --json --slim < crash.log | jq -r .identityKey | sort | uniq -c | sort -rn
```

Exit codes are scripting-clean: 0 for every completed run, 2 for usage errors; data on stdout, errors on stderr.

## Census what ships in your binary

`swiftfilt census` is the analysis teams hand-roll around `nm | grep | sort | uniq -c`: pipe it any symbol listing and get the Swift population — by kind, by module, which generic origins specialized how many times and at what cost, how many copies of one logical function exist, and how much is compiler-generated machinery. It auto-detects arbitrary text, `nm` output, and Xcode LinkMaps (`-Xlinker -map`, the highest-value input — it carries real sizes). Size-weighted and count-weighted results are never conflated; the first line says which you're reading.

```
$ swiftfilt census < LinkMap.txt
census — Xcode LinkMap, size-weighted
  …
compiler-generated machinery
  machinery is 26.6% of swift bytes (57 of 82 symbols)

duplicated logical functions
  copies  bytes  identity
       4  1,948  CensusFixture.main() -> ()
       2    128  protocol witness for CensusFixture.Shape.describe() -> String in …
```

Every input line is accounted for — skipped linker atoms and dead-stripped rows are counted buckets with byte totals, never silently dropped — and the census refuses to print (exit 1) if its tables ever fail to tile to its totals. `census --json` turns any question into a CI gate:

```sh
# fail the build when thunk bytes exceed a 256 KiB budget
swiftfilt census --json < LinkMap.txt | jq -es 'map(select(.table=="kinds" and (.name|startswith("thunk."))).bytes) | add // 0 | . < 262144'
```

## Use it from Swift

A zero-dependency library — no imports, not even Foundation, so it builds anywhere Swift compiles (macOS, Linux, Windows, Android, on-device iOS; CI builds the library on all four):

```swift
dependencies: [.package(url: "https://github.com/mi11ione/swiftfilt", from: "0.9.0")]
```

```swift
import SwiftFilt

demangle("$s4main3fooyyF")                      // Optional("main.foo() -> ()")
demangle("$s4main3fooyyF", style: .simplified)  // Optional("foo()")
demangle(type: "SaySiG")                        // Optional("[Swift.Int]")

// Structure instead of a string:
let symbol = try DemangledSymbol(parsing: "$s4main6ServerC5start4portySi_tF")
symbol.module        // "main"
symbol.path          // ["Server", "start"]
symbol.identityKey   // the crash-grouping key
symbol.symbol        // the full node tree, when the curated fields aren't enough

// Rewrite manglings inside arbitrary text:
demangleAll(in: "0  MyApp  0x104abc $s4main3fooyyF + 12")
```

For binary-safe log pipelines, `MangledNameScanner` exposes the byte-level scan the CLI is built on: `matches(inBytes:)` / `demangleAll(inBytes:)` take `[UInt8]`, find candidates by prefix, validate each through the real parser, and copy every other byte through untouched. Each `Match` carries `.identityKey` off the tree it already validated — crash-group a log in one pass, no second demangle. The typed failure taxonomy matters in pipelines: `DemangleError.notSwiftMangled` means hand the name to the next demangler; `.malformed` means it claims to be Swift and is corrupt. Full API docs on the [Swift Package Index](https://swiftpackageindex.com/mi11ione/swiftfilt/documentation).

## Positioning vs `Runtime.demangle` (SE-0498)

Swift 6.4's standard library adds an official demangle API. On a 6.4+ stdlib, inside a Swift process, needing one string, use it. The differences that matter:

| | `Runtime.demangle` | swiftfilt |
|---|---|---|
| output | one string | string, node tree, or `DemangledSymbol` (kind, module, path, thunk/specialization flags, identity key) |
| rendering | none | four presets, each corpus-validated against `swift-demangle` |
| grammar eras | what the installed runtime speaks | every shipped era, kept forever |
| output stability | explicitly unstable | deterministic per release; rendering changes are semver events |
| availability | SwiftStdlib 6.4 | any Swift version the package compiles on, incl. on-device iOS |
| text scanning / CLI | no | byte-safe filter, NDJSON, identity keys |

The runtime's C++ engine is faster per symbol than swiftfilt's pure-Swift engine. swiftfilt's trade is structure, era completeness, and output you can contract on.

## Why you can trust it

[![CI](https://github.com/mi11ione/swiftfilt/actions/workflows/ci.yml/badge.svg)](https://github.com/mi11ione/swiftfilt/actions/workflows/ci.yml)
[![Parity](https://github.com/mi11ione/swiftfilt/actions/workflows/parity.yml/badge.svg)](https://github.com/mi11ione/swiftfilt/actions/workflows/parity.yml)
[![Nightly](https://github.com/mi11ione/swiftfilt/actions/workflows/nightly.yml/badge.svg)](https://github.com/mi11ione/swiftfilt/actions/workflows/nightly.yml)
[![Platforms](https://github.com/mi11ione/swiftfilt/actions/workflows/platforms.yml/badge.svg)](https://github.com/mi11ione/swiftfilt/actions/workflows/platforms.yml)
[![Swift Package Index](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmi11ione%2Fswiftfilt%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/mi11ione/swiftfilt)

Correctness is defined by external oracles, never asserted from inside. The engine is a faithful pure-Swift port of apple/swift's demangler, and the in-repo `swiftfilt-parity` instrument re-earns that against a live `swift-demangle` on every PR and on your machine: renderings byte-for-byte, trees node-for-node, classify markers, decline agreement both directions, and demangle→remangle round-trips.

- At acceptance the instrument swept a **13,074,789-symbol** corpus from real shipped Apple code: **zero unexplained divergences**.
- Every known divergence lives in [`KNOWN-DEVIATIONS.md`](KNOWN-DEVIATIONS.md) with evidence and a reproducer — exactly four, all fixture-only corner cases with zero real-world hits, and anything uncatalogued fails the build.
- Totality is fuzz-proven: an 8.65M-item adversarial battery (random bytes, truncation sweeps, pathological nesting, invalid UTF-8) with **zero crashes and zero hangs**. Any input demangles or returns nil; nesting is bounded exactly as the reference bounds it, and a tree past the construction ceiling (4,096 levels, ~31× the deepest real-world symbol) declines cleanly at any depth.

## Performance

Measured against every incumbent way to demangle Swift symbols — same inputs, one harness, each at its best configuration. Apple M4, 10,845-symbol real-world stream, winner bold per column including where it isn't swiftfilt. Full card (CPU, memory, per-era correctness, methodology) in [`Benchmarks/README.md`](Benchmarks/README.md).

| contender | 1-symbol latency | batch throughput | byte-correct |
|---|---|---|---|
| **swiftfilt** one-shot | 371 ns | 723k sym/s | **100.00%** |
| **swiftfilt** session | 325 ns | 819k sym/s | **100.00%** |
| `swift-demangle` subprocess | 1.35 ms/spawn | 400k sym/s | **100.00%** |
| dlsym `swift_demangle` | **235 ns** | **1,299k sym/s** | 81.46% |
| CwlDemangle | 1,255 ns | 149k sym/s | 94.30% |
| `Runtime.demangle` (SE-0498) | 294 ns | 1,157k sym/s | 81.46% |

The dlsym hook wins raw per-call speed — swiftfilt holds it to 1.6× (session) / 1.8× (one-shot) — but gives no structure, styles, old-grammar guarantee, or output-stability contract (its 81.46% is that absence, measured), and exists only inside a Swift process. swiftfilt is the only in-process contender at 100% byte-correct, with an exact allocation budget: **6 allocations** per one-shot demangle, **2** through a warm session. Text filtering a 64 MiB log: the parallel CLI rewrites it in **0.11 s** (12× `swift-demangle`'s own filter), byte-identical and in order.

## Scope

swiftfilt transforms names. It never resolves addresses: no dSYM reading, no `atos`, no binary parsing — where a name came from is your symbolizer's job (census reads the *listings* such tools emit, never binaries). Swift only: C++ and Rust names pass through untouched (compose with `c++filt`).

## License

Apache 2.0. See [LICENSE](LICENSE).
