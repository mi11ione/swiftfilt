# Census your binary

Aggregate a symbol listing into the Swift population report teams
hand-roll: kinds, modules, specialization cost, duplication, and the
compiler-generated share — `swiftfilt census`.

## What it answers

Pipe `nm` output or an Xcode LinkMap at `swiftfilt census` and it answers
the questions a binary-size or symbol-hygiene investigation starts with:

- What is my Swift symbol population, by module and by kind?
- How much is compiler-generated machinery — witnesses, thunks, outlined
  helpers, metadata records — versus code someone wrote?
- Which generic functions specialized how many times, and what do those
  copies cost?
- How many copies of one *logical* function exist (specializations,
  `.stub`/`.got` linker rows, outlined artifacts, partial-apply
  forwarders — grouped by ``DemangledSymbol/identityKey``)?

The classification is the library's corpus-validated ``DemangledSymbol`` —
its ``DemangledSymbol/Kind`` taxonomy, ``DemangledSymbol/module``,
``DemangledSymbol/genericOrigin``, and identity keys. The census verb adds
only parsing and arithmetic, and it checks its own: every table must tile
exactly to its totals or the run refuses to print (exit 1) rather than
show a plausible-looking report with a leak in it.

## The three inputs

Census reads standard input only (arguments are never file paths) and
auto-detects what it was given; `--format bare|nm|linkmap` overrides, and
the report's `detected:` line states the reasoning either way.

**Bare text** (the fallback): any text — a crash log, a linker error,
`strings` output. Every validated mangling counts once per occurrence.
Count-weighted.

**nm output**: BSD/llvm-nm rows (`address type name`), undefined `U` rows
included and reported as references. `llvm-nm --print-size` dumps (on
formats that store sizes — ELF; Mach-O symbol tables carry none) are
size-weighted; rows without a size column are counted and flagged.

**Xcode LinkMap** (`-Xlinker -map -Xlinker LinkMap.txt` at link time): the
highest-value input — every row carries the real linked size. The full
file is parsed: object-file ordinals are mapped and validated, `<<dead>>`
dead-stripped rows are counted and byte-totaled apart (they are not in the
binary), and linker content atoms (`literal string: …`, `_symbolic`
reflection refs, unwind info, `l_` local labels) form an explicit skipped
bucket. Lines that fail the row shape are themselves counted, never
dropped.

## Weighting honesty

Size-weighted and count-weighted results answer different questions and
are never conflated. When the input carries sizes, tables rank by bytes
(counts alongside); otherwise by count, with no bytes column. The report's
first line and the JSON summary's `weight` field say which you are
reading.

## The report

```
census — Xcode LinkMap, size-weighted
  build/census-fixture (arm64), 8 object files
  detected: first line is an ld '# Path:' header

input
  lines                     221
  ...
  rows                      150  5,450 bytes
    swift                    82  4,272 bytes
    non-swift                40    750 bytes
    malformed swift-prefix    0      0 bytes
    content atoms (skipped)  28    428 bytes
  dead-stripped rows         32  2,384 bytes   not in the binary; excluded from every table

compiler-generated machinery
  machinery is 26.6% of swift bytes (57 of 82 symbols)
  ...

specialized generic origins
  copies  bytes  generic origin
       3    484  CensusFixture.tally<A where A: Swift.Collection, ...>(A) -> Swift.Int
```

`--top N` (default 10) sizes the ranked module / specialization /
duplication tables; hidden rows collapse into an explicit `(+ N more …)`
residual so every table still sums to its population. The kind table is a
bounded taxonomy and always prints whole. Machinery is defined precisely:
thunks, witnesses, and bridging entry points (``DemangledSymbol/isThunk``),
outlined code, metadata records (enum case records included), and
variable/default-argument initializers; everything else counts as
human-written.

On a large `bare` or `nm` listing the per-row demangle — the dominant cost
of a census — spreads across CPU cores automatically; `--jobs N` caps the
worker count and `--jobs 1` forces the single-threaded pipeline. The
report and `--json` are byte-identical at every thread count: the sharded
tally and harvest merge additively, so `--jobs` changes only *where* the
work happens, never a number. A LinkMap parses single-threaded — its
section state machine and forward object-file ordinal references make the
parse order-dependent.

## Physical atoms, honest sizes

The duplication table groups *physical* atoms: a linker map's `_foo.stub`
and `_foo.got` rows demangle to the same logical identity as `_foo`
itself, so the census keys duplication by identity *plus* the unmangled
suffix (``DemangledSymbol/suffix``) — import glue never reads as
duplicated code, and an informational `linker plumbing` line reports it
instead. Rows claiming a physically impossible size (≥ 2^48 bytes) are
counted and called out (`IMPLAUSIBLE row sizes`), and the saturated totals
are labeled unreliable rather than silently wrong — both surface in
`--json` as `linkerPlumbing` and `implausibleSizes`.

## Gating in CI

`census --json` emits the same census as NDJSON under the documented
schema (<doc:JSONOutput>): one summary object (`kind` `census`), one object
per table row (`kind` `censusRow`), always complete — `--top` shapes only
the human report. Any census question becomes a budget gate:

```sh
# fail the build when thunk bytes exceed a 256 KiB budget
swiftfilt census --json < LinkMap.txt \
  | jq -es 'map(select(.table=="kinds" and (.name|startswith("thunk."))).bytes) | add // 0 | . < 262144'

# which module grew? diff two size-weighted censuses
swiftfilt census --json < old/LinkMap.txt | jq -c 'select(.table=="modules")' > old.modules
swiftfilt census --json < new/LinkMap.txt | jq -c 'select(.table=="modules")' > new.modules
diff old.modules new.modules
```

## Topics

### Related articles

- <doc:JSONOutput>
- <doc:IdentityKeysForCrashGrouping>
- <doc:TheStructuredSymbol>
