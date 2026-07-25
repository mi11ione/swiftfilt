# Known Deviations

The catalogue of every expected divergence between SwiftFilt and the
`swift-demangle` oracle (and the library's own round-trip contract),
with evidence. This file is both documentation and a machine-readable
table: `swiftfilt-parity` parses the entry table below and classifies
matching divergences under their entry id, reported on every run and
never gating. Anything a run reports that is NOT in this table gates
(exit non-zero). The parity contract is zero unexplained rows.

Two statuses exist:

- `expected`: a by-design divergence between SwiftFilt's scope and the
  oracle's (or vice versa). Permanent until the scope changes.
- `open-defect`: a recorded SwiftFilt bug awaiting a dedicated fix. The
  harness catalogues the defect instead of hiding it, and reports it
  loudly on every run. The entry MUST be removed by the change that
  fixes it, after which the parity run goes divergence-free and stays
  gating against regressions.

Matcher mini-language (all clauses must hold — ANDed, never any-of):
`leg=<name>` (the instrument leg: `full` · `simplified` · `qualified` ·
`tree` · `classify` · `decline` · `unqualified` · `roundtrip` ·
`corpus` · `cli-golden` · `total`) · `class=<name>` (the divergence's
machine classification, e.g. `swiftfilt-superset`, `remangle-nil`) ·
`mangled.prefix=<p>` · `mangled.suffix=<s>` · `mangled.regex=<r>` (must
match the ENTIRE mangled name) · `oracle.contains=<t>` ·
`swiftfilt.contains=<t>`. An entry with no clauses matches nothing; an
unknown clause key never matches (a typo surfaces as gating rows, never
as silent classification). Every entry is pinned to evidence including a
verbatim reproducer, checkable with `swiftfilt-parity probe <symbol>`.

## Entry table

| id | status | matcher | evidence |
|---|---|---|---|
| `oldform-labellist-not-hoisted` | open-defect | `leg=tree; class=tree-mismatch; mangled.regex=__?T0.*; oracle.contains=kind=Identifier` | For Swift-4-era `_T0` functions with argument labels, apple/swift hoists each label out of the parameter tuple into the entity's `LabelList` and strips the `TupleElementName` (Demangler.cpp `popFunctionParamLabels`, old-mangling branch: `getChildIf(Param, Node::Kind::TupleElementName)` → `Param->removeChildAt(...)` → `LabelList` `Identifier`; verified on swiftlang/swift main, 2026-07-16). SwiftFilt's port deliberately stubs that branch (`DemanglerTypes.swift`, "Old-style: labels are part of the argument tuple … emit an empty label list"), leaving the label as `TupleElementName` inside the tuple and the `LabelList` empty. All four print styles and `-classify` render identically from either shape (the live print legs are clean on these rows); only the `-tree-only` node shape and the canonical `$s` conversion differ (SwiftFilt `_T08mangling14varargsVsArrayySi3arrd_tF` → `$s8mangling14varargsVsArrayyySi3arrd_tF`, apple → `$s8mangling14varargsVsArray3arrySid_tF`; both self-consistent in their own grammar). Reproducer: `swiftfilt-parity probe '_T08mangling14varargsVsArrayySi3arrd_tF'` — oracle tree carries `kind=Identifier, text="arr"` under `LabelList`; SwiftFilt's tree carries `kind=TupleElementName, text="arr"` in the tuple. 9 fixture symbols (corpus.tsv/apple.tsv `_T0…` rows with labels); 0 hits in the 13,074,789-row real-world corpus. Fix = port the label-hoisting branch (engine change; frozen during Phase 4). |
| `constprop-degenerate-superset` | expected | `leg=decline; class=swiftfilt-superset; swiftfilt.contains=Constant Propagated` | SwiftFilt demangles function-signature-specialization constant-prop payloads with MISSING operands that the reference rejects: apple/swift requires two Types and an Identifier for `ConstantPropKeyPath` via null-propagating `addChild(paramToAdd, popNode(Node::Kind::Type))` twice (Demangler.cpp `demangleFunctionSpecialization`, verified on main 2026-07-16, and the installed swiftlang-6.4.0.25.4 declines identically), while SwiftFilt's port pops leniently (`if let t = popNode(.Type)`, `DemanglerSpecializations.swift`) and resolves a self-consistent tree from what is present. Well-formed payloads agree byte-for-byte on both sides (probe `$s1t1fyyFSiAA3StrVcs7KeyPathCyADSiGcfu_SiADcfu0_33_556644b740b1b333fecb81e55a7cce98ADSiTf3npk_n` — identical output). The engine's own suite pins the lenient accept (`hostOracleDeclinedRowsStayResolvedSupersets` in SwiftDemanglerCorpusParityTests). Reproducer: `swiftfilt-parity probe '$s4main3fooyyF3fooSiTf0pk_n'` — SwiftFilt `function signature specialization <Arg[0] = [Constant Propagated KeyPath : foo<Swift.Int,>]> of main.foo() -> ()`, remangles canonicalized self-consistent; oracle echoes (declines), tree `<<NULL>>`. 1 fixture symbol; 0 hits in the 13,074,789-row real-world corpus (compilers only emit well-formed payloads). |
| `remangler-gap-legacy-exotic-types` | open-defect | `leg=roundtrip; class=remangle-nil; mangled.prefix=_TtX` | `SwiftMangler` (the `$s`-only remangler) returns nil for two legacy exotic TYPE manglings whose trees the reference remangler CAN convert: `_TtXbSi` (SIL box type) → apple `$sSiXbD`, and `_TtXFogr_dx_dx_` (old generic @objc_block function type, converted through an impl-function-type) → apple `$sxxlIPxyd_D` (both verified against swiftlang-6.4.0.25.4 `-remangle-new`; both apple outputs re-demangle cleanly: `@box Swift.Int`, `@callee_owned <A> (@unowned A) -> (@unowned A)`). Demangling, all print styles, and the trees agree with the oracle for these inputs — only the remangle leg is short. 2 fixture symbols; 0 hits in the 13,074,789-row real-world corpus. Fix = add the missing conversion productions to the Remangler (engine change; frozen during Phase 4). |
| `remangler-gap-coroutine-continuation` | open-defect | `leg=roundtrip; class=remangle-nil; mangled.prefix=$s; mangled.suffix=TC` | `SwiftMangler` returns nil for a modern coroutine-continuation-prototype (`…TC`) over a generic `@substituted` impl-function-type with yields: `$sxSo8_NSRangeVRlzCRl_Cr0_llySo12ModelRequestCyxq_GIsPetWAlYl_TC` (apple.tsv row 381; demangles on both sides to `coroutine continuation prototype for @escaping @convention(thin) @convention(witness_method) @yield_once <A, B where A: AnyObject, B: AnyObject> @substituted <A> (@inout A) -> (@yields @inout __C._NSRange) for <__C.ModelRequest<A, B>>`). The reference remangler round-trips it to itself byte-for-byte (swiftlang-6.4.0.25.4 `-remangle-new`); SwiftFilt's Remangler lacks the production. Reproducer: `swiftfilt-parity probe '$sxSo8_NSRangeVRlzCRl_Cr0_llySo12ModelRequestCyxq_GIsPetWAlYl_TC'`. 1 fixture symbol; 0 hits in the 13,074,789-row real-world corpus. Fix = engine change; frozen during Phase 4. |

## What is deliberately NOT here

- **Mach-O `__…` names in the stdin filter frame.** Not a deviation: the
  oracle's stdin filter rewrites the mangled SPAN it finds in a line, so
  for a doubled-underscore name it matches from the second underscore
  and echoes the first (`__TMQualityOfServiceKey` → `_type metadata
  …`), while the whole-name path both tools share strips that
  underscore first (swift-demangle.cpp `demangle()`:
  `if (name.starts_with("__")) name = name.substr(1)`; the library's
  documented `__T` adapter). SwiftFilt's own filter produces the
  byte-identical `_`-prefixed line. The live render legs therefore
  accept `oracle line == "_" + render` for `__…` names — a comparison
  convention grounded in the tool source, not a divergence (7 corpus
  symbols, e.g. `__TMQualityOfServiceKey`; verified equal in BOTH args
  and filter modes on both tools). The tool also computes -classify
  markers on the underscore-stripped name; the harness and the CLI do
  the same (the spurious-`{N}` bug this uncovered in `--classify` args
  mode was fixed in `SymbolText.argumentLine` and is pinned by
  `classifyStripsOneMachOUnderscoreBeforeMarkers`).
- **Oracle-adjudicated legacy conversions.** Legacy (`_T…`) inputs
  re-mangle to the modern `$s` grammar; for most the conversion
  re-demangles to the identical tree and passes structurally, and the
  rest (85 fixture rows: old impl-function-type shapes, uncurried
  specializations, Suffix-carrying trees) are re-driven through the
  reference remangler on every run and pass only if SwiftFilt's bytes
  equal apple's byte-for-byte (`conversion-oracle-confirmed`). A static
  catalogue entry would mask regressions in exactly the rows it named;
  the structural oracle check cannot. This includes the Suffix-tree
  family: apple's own `-remangle-new` emits `mangled+suffix` bytes that
  apple's own demangler then REJECTS (measured:
  `$sS2SSbIxiid_S2SSbIxxxd_TRTA31` → `<<NULL>>`), so byte-equality with
  apple is the strongest truthful contract there — no `$s` production
  can carry an unmangled suffix.
- **The `unqualified` style's rendering substance.** Not a deviation:
  `swift-demangle` has no unqualified output mode, so there is no oracle
  leg to deviate from. The live run states the leg is exercised, not
  oracled (it gates on crash/hang/emptiness only); the rendering
  substance is owned by the engine's fixture suites
  (`DemangleStyleRenderingTests`, `SwiftDemanglerCorpusParityTests.everyRowAlsoRendersUnqualifiedAndTreeDump`)
  — never implied to be oracle-validated.
- **Snapshot-declined fixture rows.** A frozen expected column equal to
  its input records that the fixture-generation oracle declined that
  row; the corpus subcommand holds those rows to the resolved-superset
  contract (demangles, no residual mangling, self-consistent) instead of
  a byte diff. Handled structurally by the instrument, not catalogued,
  because the live run re-adjudicates the same symbols against the
  CURRENT oracle on every acceptance pass.

- **Decline legs where the oracle renders junk.** For inputs no compiler
  emits, `swift-demangle` can render fabrications where swiftfilt
  declines and echoes: a dangling substitution (`$s4main3fooyyFS`) makes
  the oracle print `main.foo() -> ()Swift.String` (it even rewrote the
  3 bytes `$eS` inside a megabyte of `/dev/urandom` to `Swift.String`);
  concatenated manglings (`$s…F$s…F`) make it invent bytes
  (`…() -> ()18446744073709550616Swift…`); and its filter appends a
  trailing newline to an unterminated final line. swiftfilt's policy on
  all three is deliberate and documented: decline what does not parse,
  echo the user's own bytes, never fabricate, never append. These are
  decline-leg/byte-fidelity differences on inputs outside any compiler's
  output, not rendering deviations; the entry table stays their judge if
  one ever surfaces on a real symbol.
- **Bare-type-led `_T` collisions in stream scanning.** A bare nominal-type
  code after `_T` (`_TS…`/`_TC…`/`_TV…`/`_TO…`) begins a *type*, never a
  top-level symbol — a type-as-symbol is `_Tt…`, its metadata `_TM…`.
  `swift-demangle` still partial-demangles the coincidental prefix (`_TSized`
  → `Swift.Int with unmangled suffix "zed"`), but SwiftFilt's `_T` candidate
  gate (`isSwiftMangled` / `MangledNameScanner`) declines it and echoes the C
  name — the never-fabricate policy applied to the `_TK_LOG…` collision class.
  The demangler called directly still renders these (the demangle legs hold
  parity — it is the authority there); only the stream scanner declines. 0
  such names in the 13,074,789-row real-world corpus.
- **Nesting beyond the construction ceiling** (a deliberate
  deeper-safety guarantee, not a deviation to fix). Below the printer's
  recursion cap (`NodePrinter::MaxDepth`, 768 — restored in 0.5.0) the
  two tools render deep nesting byte-identically, `<<too complex>>`
  marker included, in every style (swept across the Array-sugar,
  Optional-sugar, metatype, and function-type shapes). Above it the
  designs diverge by intent. The reference parses unbounded depth and
  relies on the 768 print cap alone — so a deep enough input recurses
  its parser until the host stack faults (undefined) before that cap
  can render. swiftfilt is built to never do that: the current-grammar
  parser is iterative (a stack machine, not per-level recursion), the
  value tree's teardown is topological, and `treeDump()` walks an
  explicit heap stack — none of them descends one native frame per
  level. The one native per-level descent that remains, rendering, is
  bounded at the reference's own 768. On top of that, swiftfilt refuses
  any tree that would nest past 4,096 levels at construction, which
  above the shape-dependent crossover (≈1,365 `Say` levels, ≈2,040 `Sg`
  levels; always a >4 KB synthetic mangling) returns `nil` where the
  oracle — having recursed unboundedly first — prints its cap-saturated
  render. That ceiling is the deliberate guarantee: it bounds the only
  recursion the library cannot make iterative for a caller — the
  caller's own release of a returned value tree — so nothing swiftfilt
  hands back can overflow a stack on any thread. Declining the synthetic
  deep band is therefore the stricter, safer contract, not a gap. The
  deepest real corpus symbol nests ~131 levels; 0 hits in the
  13,074,789-row sweep.

Oracle version for all evidence in this file: Apple Swift 6.4
(swiftlang-6.4.0.25.4), `swift-demangle` from
Xcode-beta.app 26 (`xcrun -f swift-demangle`), LLVM 21.0.0.
apple/swift `main` source citations retrieved 2026-07-16; depth-policy
sweeps and decline-leg evidence re-verified against the same oracle
2026-07-24.

## The oracle version floor

Every entry above is evidence recorded against that oracle, and the
print and tree legs compare RENDERING STRINGS and NODE KINDS — both of
which upstream renames between releases. Measured across 6.2.4 → 6.4:
`predefined @objc completion handler block implementation for …` became
`checked …`, and the `FunctionSignatureSpecializationParamPayload` node
kind became `Identifier`. Neither is an engine defect, but each shows up
as a divergence row indistinguishable from one.

So `Oracle.referenceVersion` (Oracle.swift) declares the floor, and a
live oracle BELOW it makes the oracled legs **advisory**: every
divergence is still counted, classified, listed, and written to the
gating TSV, but the run exits 0 and says why in the summary. Harness
errors — an unlaunchable or timing-out oracle — gate regardless, since
no toolchain skew explains those. At or above the floor nothing softens
and the legs gate exactly as before; `swiftfilt-parity selfcheck` proves
both directions, and the advisory path is pinned by
`OracleReferenceVersionTests`.

This exists because the newest publicly installable `swift-demangle` is
behind the toolchain this file was recorded against: GitHub-hosted macOS
runners top out at Xcode 26.3 (Swift 6.2.4) and swift.org's newest
release is 6.3.3, while the reference is the Xcode-beta 6.4 toolchain.
CI therefore CANNOT reproduce these entries exactly, and a gating run
there would fail on another toolchain's spelling. Raise
`referenceVersion` when the fixtures and this file are re-recorded
against a newer oracle — the floor is a statement about which oracle the
evidence belongs to, not a tolerance to be widened.
