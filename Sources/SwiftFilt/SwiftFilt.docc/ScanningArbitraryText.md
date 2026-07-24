# Scanning arbitrary text

Finding and rewriting mangled names inside crash logs, `nm` output, and
build logs — including streams that are not valid UTF-8.

## Overview

Crash SDKs and log filters reimplement this with regexes; the regexes
drift from the grammar and either miss symbols or mangle prose.
``MangledNameScanner`` grounds both halves: candidates are found by
*mangling prefix* and bounded by the *mangling character set*, and every
candidate is validated through the actual demangler — both cheap and
definitionally correct.

```swift
let scanner = MangledNameScanner()

scanner.demangleAll(in: #""_$s4main3fooyyF", referenced from:"#)
// ""main.foo() -> ()", referenced from:"

for match in scanner.matches(in: crashLogLine) {
    match.mangled        // the name as matched
    match.range          // where it sits in the string
    match.symbol         // the demangling tree (already validated)
    match.demangled(.simplified)
}
```

The module-scope ``demangleAll(in:style:)`` is the one-call version.

## How candidates are found

A candidate starts at any occurrence of a shipped mangling prefix — `$s`,
`$S`, `$e` (each optionally behind the Mach-O `_`), `_T0`, legacy `_T`
followed by a recognized old-mangling operator (so `_TK_LOGGING`-style C
names are never attempted), or `@__swiftmacro_` — and extends over the
mangling character set `[A-Za-z0-9_$.]` (the `.` because linker symbols
carry `.resume.N`/`.cold.N` suffixes that demangle as part of the name).
Trailing dots are trimmed, so a symbol ending a sentence does not swallow
the period. Prefixes match anywhere, exactly like `swift-demangle`'s
stream filter — a symbol glued behind other characters
(`_OBJC_CLASS_$__TtC…`) is still found.

## How false positives die

Every candidate must demangle through the real parser and render non-empty
in ``DemangleStyle/full``; anything else — English prose, C++ `_Z` names,
base64 that happens to contain `_T0`, hex, URLs — is left byte-for-byte
untouched. No heuristic scoring, no regex to drift.

Two inherent caveats, both shared with `swift-demangle` itself: a string
that *is* a valid short mangling (like `$ss` inside `dollar$ss`) demangles
— the grammar cannot distinguish it from a real symbol; and for the rare
specialization whose constant-propagated payload the printer must emit as
a raw mangled name, that embedded name is itself a valid mangling, so one
rewriting pass produces text a second pass would demangle further (7 of
the 10,105 golden-corpus symbols; every other output is a fixed point of
``demangleAll(in:style:)``).

## The byte-level API

Real logs are not reliably UTF-8: crash logs embed binary UUID blobs,
build logs interleave tool output mid-write. A lossy `String` decode would
corrupt exactly the bytes a filter promises to preserve, so the scanner's
core is byte-oriented and the `String` entry points are thin views over
it:

```swift
let raw: [UInt8] = readChunk()                  // any bytes, any encoding
let rewritten = scanner.demangleAll(inBytes: raw)
let found = scanner.matches(inBytes: raw)       // [MangledNameScanner.ByteMatch]
```

Mangled names are pure ASCII, so candidates are exact in any byte stream;
every byte that is not part of a validated mangling passes through
untouched — invalid UTF-8 included. This is the surface for binary-safe
log pipelines (the `swiftfilt` CLI's filter mode is built on it).

For streaming callers that must cut an over-long buffer,
``MangledNameScanner/isManglingCharacter(_:)`` is public: cutting *outside*
a maximal mangling-character run is the only cut that provably splits no
candidate.

## Cost model

Scanning is linear in the text and byte-oriented; the demangler runs only
at prefix hits. The repository's `Benchmarks/README.md` records the
measured filter throughput on a synthetic crash-log-density buffer.
