# JSON output

The NDJSON schema behind `swiftfilt --json` — the versioned contract for
the tool's machine-readable output.

## The contract

**`schemaVersion`: 1.** Every emitted object carries it. Within one
version, fields are only ever *added* — never renamed, retyped,
reordered, or removed; any breaking change increments `schemaVersion`.
Key order is fixed as documented and byte-stable across runs and
platforms, so `--json` output is safe to diff.

## Stream shape

`--json` selects NDJSON: one self-contained object per line, streamed as
input is consumed (no enclosing array). One object per *demangled symbol*
— in filter mode, one per validated mangled name in stdin; in symbol-args
mode, one per argument that demangles, in order. An argument that does not
demangle emits nothing (or a `decline` record under `--include-declines`,
below). The input line text is never embedded, keeping the NDJSON valid
UTF-8 even when the scanned stream is not.

## The record

Field order is fixed: `schemaVersion`, `mangled`, `demangled`, `style`,
then optional `module`, then `path`, `kind`, the kind payload (`accessor`
/ `thunk` / `metadata`), `isStatic`, `isThunk`, `isSpecialized`, optional
`genericOrigin`, `identityKey`, and in filter mode `line` and
`byteOffset`.

| field | type | meaning |
|---|---|---|
| `schemaVersion` | number | always `1` for this article |
| `mangled` | string | the mangled name, byte-for-byte as matched |
| `demangled` | string | the rendering in the selected style. Non-empty for the default `full` style (that rendering is the validation gate); may be empty for a degenerate tree in another style — the text filter leaves such matches unrewritten, and the record says so by carrying the empty string |
| `style` | string | which preset `demangled` is rendered in: `full`, `simplified`, `qualified`, or `unqualified` |
| `module` | string? | the defining module, present when the tree carries one statically |
| `path` | string[] | the declaration-name path from the module to the symbol's own name (no module, no signatures); `[]` when the tree carries no static names |
| `kind` | string | the curated classification, the `DemangledSymbol.Kind` case name verbatim: `function`, `initializer`, `deinitializer`, `accessor`, `variable`, `subscriptDeclaration`, `closure`, `variableInitializer`, `defaultArgument`, `type`, `enumCase`, `protocolDeclaration`, `protocolWitness`, `thunk`, `outlined`, `macro`, `metadata`, `other`. Kinds the library adds later appear as soon as the CLI learns them (the mapping is exhaustive in the CLI source, so an engine addition is a compile error there, never a silent `other`) |
| `accessor` | string, only when `kind` is `accessor` | the `AccessorKind` case name (`getter`, `setter`, `willSet`, `didSet`, `read`, `modify`, …) |
| `thunk` | string, only when `kind` is `thunk` | the `ThunkKind` case name (`reabstraction`, `curry`, `dispatch`, `keyPath`, `partialApply`, `vtable`, `objCAsyncCompletion`, `identity`, `autoDiff`) |
| `metadata` | string, only when `kind` is `metadata` | the `MetadataKind` case name (`typeMetadata`, `typeDescriptor`, `protocolDescriptor`, `conformance`, `valueWitness`, `reflection`) |
| `isStatic` | bool | whether the entity is `static` (or a `class` member, which mangles identically) |
| `isThunk` | bool | compiler-generated forwarding artifacts — broader than `kind == "thunk"` (it also covers witnesses and bridging/back-deployment markers) |
| `isSpecialized` | bool | whether the symbol is a compiler-generated specialization of a generic origin |
| `genericOrigin` | string? | for a specialization, the `full` rendering of its generic origin |
| `identityKey` | string | the crash-grouping key (<doc:IdentityKeysForCrashGrouping>) — canonical and deterministic within one swiftfilt version, never empty |
| `line` | number, filter mode only | 1-based line number of the match in the input stream (the final unterminated line counts) |
| `byteOffset` | number, filter mode only | 0-based byte offset of the mangled name's first byte within that line's bytes. `mangled` is pure ASCII, so the match spans `[byteOffset, byteOffset + mangled.length)` |

Optional fields are *omitted* (never `null`) when absent, so presence
is itself the signal.

Example (one line, wrapped for reading):

```json
{"schemaVersion":1,"mangled":"$s4main3fooyyFSi_Tg5",
 "demangled":"generic specialization <Swift.Int> of main.foo() -> ()",
 "style":"full","module":"main","path":["foo"],"kind":"function",
 "isStatic":false,"isThunk":false,"isSpecialized":true,
 "genericOrigin":"main.foo() -> ()","identityKey":"main.foo() -> ()",
 "line":10,"byteOffset":51}
```

## The --slim projection

`--slim`, valid with `--json`, drops the zero-signal fields and nothing
else: `schemaVersion` and `style` always; `demangled` and `path` when
empty; `isStatic` / `isThunk` / `isSpecialized` when false — their
remaining presence is the witness, carried **only when true**. Every kept
field keeps its value and relative order, so a slim line is the full line
with the dropped keys removed. It never changes the default `--json`
output.

## Declined symbol arguments

By default the `--json` stream is *exactly* the demangled symbols; an
argument that does not demangle emits nothing. `--include-declines` (with
`--json`, symbol-args mode) adds a diagnosis record for those, so a batch
reports which arguments failed and why instead of dropping them. Each
emits one object with `kind` `decline`, carrying the same diagnosis
`swiftfilt explain` gives (<doc:ExplainingASymbol>): `mangled`, `status`
(`malformed` or `notSwiftMangled`), `era` when a Swift prefix was
recognized, and for a `malformed` name `stoppedAtByteOffset` and `reason`
(`truncatedIdentifier` — with `declaredLength`/`availableBytes` —
`incompleteInput`, `unexpectedByte` with `byte`, or `unparseable`), plus
`embeddedSymbols` and, for `notSwiftMangled`, `foreign` when they apply.

```json
{"schemaVersion":1,"kind":"decline","mangled":"$s4main9foo",
 "status":"malformed","era":"stableABI","stoppedAtByteOffset":8,
 "reason":"truncatedIdentifier","declaredLength":9,"availableBytes":3}
```

So there is no `truncated`/`degenerate` boolean on the symbol record: a
decline record carries the full parse diagnosis, and a symbol that parses
but renders empty already shows it by carrying `"demangled":""`. The stdin
filter has no decline records — its scanner cannot tell a truncated symbol
from coincidental prose, so it passes non-manglings through untouched;
extract a symbol and pass it as an argument, or diagnose one with
`swiftfilt explain`.

## The census objects

`swiftfilt census --json` (<doc:CensusYourBinary>) emits NDJSON under the
same `schemaVersion` 1 add-only discipline, with two object kinds: one
**summary** object first (`kind` `census`), then one object per table row
(`kind` `censusRow`), grouped by table in report order — `kinds`,
`modules`, `specializations`, `duplicates`. The stream is always the
*complete* census: `--top` shapes only the human report.

The summary object's fields, in fixed order (optional fields omitted,
never `null`; every `…Bytes` twin appears only when `weight` is
`bytes`):

| field | type | meaning |
|---|---|---|
| `schemaVersion` | number | always `1` |
| `kind` | string | `census` |
| `format` | string | `bare`, `nm`, or `linkmap` |
| `weight` | string | `bytes` when the input carried sizes, `count` otherwise — the weighting every byte field and ranking used |
| `detection` | string | the format-detection reasoning |
| `path`, `arch` | string, linkmap | the map's `# Path:` / `# Arch:` headers, when present |
| `objectFiles` | number, linkmap | entries in the object-file table |
| `lines` | number | input lines |
| `structureLines`, `unparseableLines` | number, nm/linkmap | the line ledger: scaffolding lines, and lines that failed the row shape (counted, never dropped) |
| `rows`, `rowBytes` | number | the live row population |
| `swift` / `swiftBytes` | number | rows whose name demangles |
| `nonSwift`, `malformed`, `contentAtoms` (+ `…Bytes`) | number, nm/linkmap | the rest of the classification; the four buckets tile exactly to `rows` and `rowBytes` |
| `linkerPlumbing` (+`…Bytes`) | number, nm/linkmap | Swift rows carrying a linker-plumbing suffix (`.stub`/`.got`/`.stub_helper`) — informational subset of `swift`, kept out of the duplication table |
| `implausibleSizes` (+`…Bytes`) | number, nm/linkmap | rows whose size column is ≥ 2^48 bytes; byte totals saturate and the human report warns |
| `embeddedMangling` / `…Bytes` | number, nm/linkmap | non-Swift rows whose name embeds a validated mangling (informational subset of `nonSwift`) |
| `deadStripped` / `deadStrippedBytes` | number, linkmap | dead-stripped rows — never part of `rows` |
| `undefinedRows` | number, nm | `U`/`u` rows: references, not definitions |
| `rowsWithoutSize` | number, nm sized | rows weighed as 0 bytes for lack of a size column |
| `unknownOrdinalRows` | number, linkmap | rows citing an object-file ordinal the map never declared |
| `machinery` / `…Bytes`, `human` / `…Bytes` | number | the compiler-generated split; tiles exactly to `swift` |
| `specialized` / `…Bytes`, `unattributedSpecializations` / `…Bytes` | number | specialized rows in total, and those whose generic origin was not recoverable |

Row objects carry `schemaVersion`, `kind` (`censusRow`), `table`, `name`
(the kind name, module, generic origin, or identity key), `count` (rows;
copies for `specializations` and `duplicates`), and `bytes` when `weight`
is `bytes`. The `duplicates` table carries only identity keys with more
than one copy.

Census `--slim` drops `schemaVersion` and the summary's `detection`
prose — counts are never dropped at zero, because a zero is exactly what
a CI budget gate reads.

## Consuming it

```sh
# which modules crash most
swiftfilt --json < crash.log | jq -r '.module // "unknown"' | sort | uniq -c

# only the thunk frames, with their targets
swiftfilt --json < crash.log | jq -c 'select(.kind=="thunk") | {thunk, demangled, line}'

# Python: stream without loading the whole log
import json, subprocess
proc = subprocess.Popen(["swiftfilt", "--json"], stdin=open("crash.log","rb"),
                        stdout=subprocess.PIPE, text=True)
for line in proc.stdout:
    record = json.loads(line)
```

String escaping follows JSON exactly (`"`, `\`, `\n`, `\r`, `\t`, and
`\u00XX` for other control characters); all other characters, including
non-ASCII demangled names, pass through as UTF-8. Numbers are decimal
integers.
