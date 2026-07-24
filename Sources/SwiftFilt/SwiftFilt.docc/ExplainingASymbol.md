# Explaining a symbol

Tell the whole story of one name — what it is when it demangles, and *why*
when it does not: `swiftfilt explain`, and its library twin
``SymbolExplanation``.

## The gap explain fills

Every demangler is silent on the symbol that does not work. A truncated
crash frame, a name corrupted in transit, a C++ symbol that wandered into
a Swift pipeline — `swift-demangle` echoes each back unchanged, with no
signal whether it declined the name or simply failed on it. The library's
``DemangleError`` draws the distinction that matters
(``DemangleError/notSwiftMangled`` versus ``DemangleError/malformed``),
but a two-case error cannot carry *where* a parse stopped or *what*
stopped it. `explain` is the verb, and ``SymbolExplanation`` the type,
that does.

## On success: the full anatomy

For a name that demangles, `explain` prints the mangling era, the curated
classification, module and path, every validated rendering, and the
crash-grouping identity key — the whole ``DemangledSymbol`` surface, laid
out:

```
$s4main6ServerC5start4portySi_tF
  status       demangled
  era          stable-ABI ($s)
  kind         function
  module       main
  path         Server.start
  full         main.Server.start(port: Swift.Int) -> ()
  simplified   Server.start(port:)
  qualified    main.Server.start(port: Swift.Int) -> ()
  unqualified  start(port: Int) -> ()
  identity     main.Server.start(port: Swift.Int) -> ()
```

## On failure: the diagnosis

When a name carries a Swift prefix but does not parse, the diagnosis names
the era (``ManglingEra``), the byte the parser could not advance past, and
what it found there — the ``SymbolExplanation/Reason`` taxonomy:

- ``SymbolExplanation/Reason/truncatedIdentifier(declaredLength:availableBytes:)`` —
  a length-prefixed identifier asks for more bytes than remain, the
  signature of a name cut short in a fixed-width log column.
- ``SymbolExplanation/Reason/unexpectedByte(_:)`` — a stray or corrupt
  byte where the grammar expects another (a raw non-ASCII byte lands here
  too: Swift identifiers are punycode, never raw UTF-8).
- ``SymbolExplanation/Reason/incompleteInput`` — the input ends
  mid-symbol, a production left unfinished.
- ``SymbolExplanation/Reason/emptyBody`` — nothing but a prefix.
- ``SymbolExplanation/Reason/unparseable`` — the legacy `_T` grammar
  parses on a scanner that exposes no cursor, so no byte-precise position
  is fabricated.

The diagnosis also lists any *complete* Swift name found embedded inside
the input — the nearest miss that turns "this whole string is not one
symbol" into "…but it contains one, and here is what it means":

```
$s4main3fooyyF trailing junk
  reason       an unexpected byte ' ' (0x20) where the grammar expects a different one
  contains     1 complete Swift name — the whole string is not one symbol:
               $s4main3fooyyF  →  main.foo() -> ()
```

And for a name with no Swift prefix at all, it names the scheme the bytes
resemble and the tool that reads it — a hand-off hint, never a claim:

```
_Z3fooiii
  status       not a Swift mangled name — no recognized mangling prefix
  looks like   C++ (Itanium _Z) — try c++filt
  hint         _Z3fooiii | c++filt
```

## Scriptable and in-process

`explain --json` emits one object per argument under the same
`schemaVersion 1`, add-only contract as the rest of the tool
(<doc:JSONOutput>) — `status`, `era`, and the reason with its fields — so
a *declined* symbol becomes a record a pipeline can gate on instead of the
silence every other tool returns. With no symbol arguments, `explain`
reads standard input, one symbol per line — the
`nm | grep | swiftfilt explain` shape — so a whole dump is diagnosed at
once:

```sh
nm MyApp | awk '{print $NF}' | swiftfilt explain --json | jq 'select(.status=="malformed")'
```

In process, ``SymbolExplanation/init(parsing:)`` is the same diagnosis as
a value. Switch on ``SymbolExplanation/outcome``:
``SymbolExplanation/demangledSymbol`` on success (the full curated tier),
``SymbolExplanation/malformed`` for the break, or the foreign hand-off
hint for a non-Swift name — exactly what a crash grouper needs to decide
whether to group a truncated frame, retry another demangler, or log why a
name did not resolve.

## Scope

`explain` stays inside the library's scope wall (<doc:ScopeAndGuarantees>):
it transforms and diagnoses *names*. It does not resolve addresses, read a
binary, or demangle C++ or Rust — for those it points you at the right
tool. The demangled renderings it prints are the same corpus-validated
output as every other surface; only the diagnosis prose is `explain`'s
own, and it evolves with the tool rather than being pinned to an oracle.

## Topics

### The explanation

- ``SymbolExplanation``
- ``SymbolExplanation/Outcome``
- ``SymbolExplanation/Malformed``
- ``SymbolExplanation/Reason``
- ``SymbolExplanation/ForeignMangling``
- ``ManglingEra``
