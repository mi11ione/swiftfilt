# Scope & guarantees

What SwiftFilt promises, what it deliberately does not do, and where every
known gap is written down.

## The guarantees

**Totality.** Any input — any string, any byte sequence — either
demangles or returns `nil`/throws the typed ``DemangleError``. No crash,
no trap, no hang, no partial guess. Work stays proportional to input size,
and the in-repo fuzz battery (millions of adversarial items: random bytes,
prefixed garbage, truncation sweeps of real symbols at every length,
pathological nesting, invalid UTF-8 through the byte scanner) re-proves it
continuously.

**Nesting depth is bounded — deliberately, and more safely than the
reference.** The bound is a guarantee, not a caveat, enforced in four
layers:

- *Parsing is iterative.* The current-grammar demangler is a stack machine
  — it builds a tree of any depth in O(1) native stack, never one frame
  per nesting level. (The reference parser recurses per level onto the
  host stack.)
- *Rendering stops at the reference's own printer cap*
  (`NodePrinter::MaxDepth`, 768), emitting `<<too complex>>`
  byte-identically in every style. Rendering is the *only* per-level
  native descent, bounded at that same 768 — the reference's number, not
  ours.
- *Every structural walk is iterative or bounded.*
  ``SwiftSymbol/treeDump()`` walks an explicit heap stack, a returned
  tree's storage is released topologically, and the remangler is bounded
  at the reference's 1,024.
- *A construction ceiling caps the tree itself.* A tree that would nest
  past 4,096 levels (~31× the deepest symbol in the 13,074,789-row
  real-world corpus, which nests ~131; zero corpus symbols reach the
  ceiling) is refused as it is built, and the parse declines like any
  malformed input.

That ceiling is the deliberate difference from the reference, which has
none: on a pathologically deep input the reference recurses until the host
stack faults (undefined behavior) before its printer cap can render.
swiftfilt declines cleanly — totality holds at every depth. The only
observable consequence is a narrow synthetic band (manglings deeper than
4,096 tree levels, always a >4 KB string no compiler emits) where
swiftfilt returns `nil` and the reference prints a cap-saturated
`<<too complex>>`. The `swiftfilt` CLI hosts the 768-frame render on a
dedicated 64 MiB stack — headroom for the print cap, never a workaround
for unbounded recursion, of which there is none.

**Determinism.** One input, one output, on every run and platform. No
environment, locale, or toolchain sniffing anywhere in the library.

**Every grammar era, kept forever.** Stable-ABI `$s`/`$S`, Embedded Swift
`$e`, Swift 4 `_T0`, the legacy Swift ≤3 `_T` grammar (including `_Tt`
type names in Objective-C metadata), and `@__swiftmacro_` expansion names
all demangle, with or without the Mach-O leading underscore. Old grammars
are never removed: binaries, crash archives, and metadata mangled years
ago must keep demangling years from now.

**Text stability as policy.** Rendered text is exact and validated, not
best-effort (<doc:StylesAndValidation>). Within a library version the
output is byte-deterministic; renderings change only in minor releases,
recorded in the release notes. Pipelines that must survive releases should
prefer structure (``DemangledSymbol``) and identity keys over parsing
printed names.

**Correctness is defined outside the library.** The engine is a faithful
pure-Swift port of apple/swift's demangler, held to node-level and
byte-level parity with `swift-demangle` by an in-repo parity instrument:
the committed golden corpus on every change, and a 13,074,789-symbol
real-world corpus sweep plus round-trip remangling adjudication at
acceptance. Every known divergence is catalogued with evidence and a
reproducer in the repository's `KNOWN-DEVIATIONS.md`; anything
uncatalogued fails the build. The catalogue currently holds four entries,
all fixture-only — zero of them occur in the real-world corpus.

## The walls

SwiftFilt transforms *names*, and the boundary is policed deliberately:

- **It never resolves addresses.** No dSYM reading, no `atos`, no
  symbol-table lookup, no binary parsing. Hand it the name; where the name
  came from is your loader's/symbolizer's job.
- **Swift only.** C++ `_Z…` names, Rust `_R…` names, and plain C symbols
  are ``DemangleError/notSwiftMangled`` — the typed signal to hand them to
  the next demangler in line. The CLI composes with `c++filt` in a pipe
  for mixed logs.
- **No execution, no I/O.** The library reads the bytes you pass and
  nothing else. Inputs are never paths, URLs, or code.
- **No unvalidated renderings.** Four presets, each corpus-validated;
  there is deliberately no custom printer-options surface
  (<doc:StylesAndValidation>).

## Grammar growth

The mangling grammar moves with every Swift release. New node kinds appear
in ``SwiftSymbol/Kind`` (and, when they warrant it, new curated
``DemangledSymbol/Kind`` cases) in minor releases; the switching policy for
consuming code is documented on both types. A symbol from a future grammar
the library does not know yet fails honestly — it does not half-demangle.

## Where the bar is enforced

Four layers keep these claims true on every change: the ported engine test
suites and golden corpora (`swift test`), the parity instrument diffing
SwiftFilt against a live `swift-demangle` across seven legs plus
round-trip remangling, the totality fuzz battery, and a contribution bar
(`CONTRIBUTING.md`) under which no engine change merges without that
battery green. The library target is additionally held at per-file 100%
test coverage and zero `import` statements, both gated mechanically in CI.
