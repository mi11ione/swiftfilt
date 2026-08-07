# swiftfilt benchmarks

swiftfilt against every incumbent way to demangle Swift symbols, on identical inputs, through one harness — speed, CPU/power, memory, and measured correctness. This is its own SwiftPM package outside the root graph, so the published SwiftFilt package keeps zero dependencies. Build and run from this directory.

## The card

Apple M4, macOS 27, Swift 6.4, release, foreground; medians of 5 runs on the committed 10,845-symbol real-world fixture stream. Winner bold per column — including where it is not swiftfilt.

| contender | 1-symbol latency | batch throughput | CPU/symbol | allocs/symbol | matches `swift-demangle` |
|---|---|---|---|---|---|
| **swiftfilt** one-shot | 360 ns | 772k sym/s | 1,293 ns | 13.9 | **100.00%** |
| **swiftfilt** session | 307 ns | 876k sym/s | 1,140 ns | 7.8 | **100.00%** |
| `swift-demangle` subprocess | 1.33 ms ¹ | 410k sym/s | 2,096 ns ² | — ² | **100.00%** |
| dlsym `swift_demangle` | **232 ns** | **1,318k sym/s** | **759 ns** | **5.9** | 81.46% ³ |
| CwlDemangle | 1,249 ns | 154k sym/s | 6,500 ns | 41.1 | 94.30% |
| `Runtime.demangle` (SE-0498) | 291 ns | 1,179k sym/s | 848 ns | 8.0 | 81.46% ³ |

¹ spawn-per-symbol — the only single-symbol form a subprocess has; the batch row amortizes one spawn over all 10,845 symbols via stdin (its best case). ² child-process CPU; child-side allocations are unobservable from the parent. ³ every miss is the engine's unsugared display convention, not a misparse — split out below.

Text filter / CLI wall, identical 64 MiB crash-log-density log:

| contender | wall | throughput | CPU/MB | peak RSS |
|---|---|---|---|---|
| `swiftfilt` (parallel, default) | **0.12 s** | **559 MB/s** | 11.8 ms | 41.1 MiB |
| `swiftfilt --jobs 1` | 0.47 s | 143 MB/s | 7.0 ms | 12.8 MiB |
| SwiftFilt library, single thread | — | 147 MB/s | **6.8 ms** | in-process |
| `swift-demangle` filter | 1.35 s | 50 MB/s | 20.1 ms | **3.2 MiB** |

The other contenders have no text filter — dlsym, CwlDemangle, and `Runtime.demangle` demangle one already-extracted name per call.

In one look: the dlsym hook is the fastest raw string→string engine per call, and this card says so — swiftfilt holds it to 1.5× (session) / 1.7× (one-shot) while being the only contender besides the toolchain tool that reproduces the reference rendering byte-for-byte, and the only one that also gives structure, styles, identity keys, byte-safe filtering, and a stability contract. On wall clock over real log bytes, the parallel CLI is 11× the toolchain filter.

## Correctness coverage (measured, never asserted)

Ground truth is the committed fixtures' full-style renderings — 10,844 verified rows (plus one whose verified expectation is the oracle's *decline*, below), earned against `xcrun swift-demangle` by the repository's parity instrument. Every contender ran every row; outputs byte-compared. `coverage` mode reproduces this.

| contender | resolves | matches reference | differs | declined |
|---|---|---|---|---|
| **swiftfilt** | **10,844/10,844** | **10,844 (100.00%)** | 0 | 0 |
| `swift-demangle` (args mode) | **10,844/10,844** | **10,844 (100.00%)** | 0 | 0 |
| dlsym `swift_demangle` | **10,844/10,844** | 8,833 (81.46%) | 2,011 | 0 |
| CwlDemangle | 10,422 (96.11%) | 10,226 (94.30%) | 196 | 422 |
| `Runtime.demangle` | **10,844/10,844** | 8,833 (81.46%) | 2,011 | 0 |

Per grammar era, reference-matching/total:

| contender | stable `$s` | swift4 `_T0` | legacy `_T` | objc `_Tt` | macro | embedded `$e` |
|---|---|---|---|---|---|---|
| swiftfilt | **10,290/10,290** | **81/81** | **256/256** | **210/210** | **6/6** | **1/1** |
| `swift-demangle` | **10,290/10,290** | **81/81** | **256/256** | **210/210** | **6/6** | **1/1** |
| dlsym hook | 8,330/10,290 | 61/81 | 236/256 | 199/210 | **6/6** | **1/1** |
| CwlDemangle | 9,703/10,290 | 79/81 | 251/256 | 187/210 | **6/6** | 0/1 |
| `Runtime.demangle` | 8,330/10,290 | 61/81 | 236/256 | 199/210 | **6/6** | **1/1** |

What the differences are, split by a second oracle (each tool's own `--no-sugar` rendering):

- **dlsym / `Runtime.demangle`:** all 2,011 misses byte-match `swift-demangle --no-sugar` exactly — the runtime engine renders types unsugared (`Swift.Optional<T>` where the tool prints `T?`). Zero misparses. The 81.46% measures distance from the reference rendering, not correctness: these are correct demanglings in a convention that isn't `swift-demangle`'s — the measured face of "no output-format contract", which SE-0498 states outright ("may change without any warning, during even patch releases of Swift").
- **CwlDemangle** (at its best configuration): 422 declines are grammar the 2025 port doesn't speak (`Md`/`MR` kinds, newer outlined-value variants, embedded `$e`); 196 wrong outputs are real rendering defects, none of them the sugar convention — e.g. a literal `first-element-marker ` leaking into output, a stray trailing `_`. Fast-but-stale is the vendored-copy trade, measured.
- The one **expected-decline row** (`$s4main3fooyyF3fooSiTf0pk_n`, a constant-prop payload with missing operands): `swift-demangle` declines it; swiftfilt, dlsym, CwlDemangle, and `Runtime.demangle` all resolve a lenient superset. For swiftfilt that's catalogued with evidence in [`KNOWN-DEVIATIONS.md`](../KNOWN-DEVIATIONS.md) (`constprop-degenerate-superset`); the other three catalogued deviations live in legs this vector doesn't traverse. All four are fixture-corner cases with zero hits in the 13,074,789-symbol real-world sweep.

## Notes

- **Single-symbol latency** is the identical 14-byte everyday function symbol, sequential calls. Spawn-per-symbol — the pattern scripts actually write — is ~4,000× a warm in-process call: process creation costs milliseconds, the demangle costs sub-microseconds. swiftfilt's session allocs/call is **2** (input copy + result string); one-shot is 6. Deep-generic worst case (the stream's longest mangling, 1,325 bytes): 24.1 µs, 250 allocations.
- **swiftfilt-only vectors** (no contender supports them, `structure` mode): parse to `DemangledSymbol` 1.59 µs · identity-key derivation 0.83 µs · five-field read 0.45 µs. The census streams a 1,000,000-row link map in 417 MiB peak.
- **Capabilities.** The dlsym hook and `Runtime.demangle` are string→string only — no styles, structure, old-grammar guarantee, or output-stability contract, and only inside a Swift process. `swift-demangle` gives the reference renderings but a spawn per batch, text out, no JSON, and a single-threaded filter. CwlDemangle is one embeddable Swift file, frozen at its port date. The root README's [positioning table](../README.md#positioning-vs-runtimedemangle-se-0498) is the full capability matrix; this file measures what's measurable.

## Methodology

Apple M4 (4P+6E), 24 GiB, macOS 27, Swift 6.4 (swiftlang-6.4.0.27.1), release. Absolutes are host-class-relative; the ratios are the portable part.

- **Contenders pinned:** swiftfilt 1.0.1 (this checkout) · `swift-demangle` and the dlsym'd runtime from swiftlang-6.4.0.27.1 (Xcode 27.0 beta) · CwlDemangle `mattgallagher/CwlDemangle` @ `6bfc351` (repo HEAD, 2025-03-31; no version tags, so revision-pinned) · `Runtime.demangle` from the Swift 6.4 stdlib (`@available(macOS 27)`). Where `Runtime.demangle` can't run, the harness prints the exact reason instead of silently omitting rows.
- **Each contender at its best:** swiftfilt one-shot and session are separate labeled rows; the subprocess gets one spawn per batch via stdin (coverage runs args mode, grading its demangler not its line scanner); the dlsym hook is resolved once and reused; CwlDemangle runs `.default + .synthesizeSugarOnTypes`, the options that maximize its byte-agreement (plain `.default` would score 77.73%); `Runtime.demangle` is one call per symbol. All subprocess work uses raw `posix_spawn`/`waitpid` — Foundation's `Process` was measured adding ~65 ms per spawn on this OS, which would bill harness overhead to the subprocess contenders.
- **Inputs are deterministic:** the symbol stream is the committed fixture corpora (10,845 real-world names spanning every era); the filter/CLI logs are generated from seed `0xc0ffee0015bad`, crash-log density (half the lines carry one mangled name).
- **Timing:** 1 warmup (filter: 3) + 5 recorded runs (`ContinuousClock`); reported figure is the median, spread is (max−min)/median; results fold into an opaque sink. Run FOREGROUND — macOS gives background process groups efficiency-core scheduling that roughly halves every number; the `utilization` column (≥99.9% in-process) is the tell. CPU time is the rusage user+system delta; allocations are counted in one extra unrecorded pass via libmalloc's `malloc_logger`; peak RSS is the `ru_maxrss` growth across the workload.

Reproduce:

```sh
swift build -c release --product swiftfilt   # repo root, once (for the cli rows)
cd Benchmarks
swift run -c release swiftfilt-bench card     # the whole card, one process
swift run -c release swiftfilt-bench coverage # the correctness census
swift run -c release swiftfilt-bench --json   # machine-readable
```

Modes: `all` · `demangle` · `stream` · `filter` · `structure` · `compare` · `latency` · `coverage` · `cli` · `card` · `smoke` · `alloc-census`. Options: `--runs N` · `--mib N` · `--seed VALUE` · `--symbols N` · `--baseline FILE` · `--json`. Always run release; debug numbers are meaningless.

**`alloc-census`** is the instrument behind the allocs/op columns: it hooks `malloc_logger`, captures an 8-frame backtrace per allocation across warmed-up calls, aggregates identical stacks, and resolves them through `atos` — so "where do the remaining allocations come from" is one command. It's the proof behind the ledger: a one-shot `demangle("$s4main3fooyyF")` performs exactly 6 allocations (input copy, arena object, two engine slabs, printer output, result string); through a warm `DemangleSession`, exactly 2 — the input copy and result string, the product boundary itself. Darwin-only.

**The smoke gate.** Nightly CI runs `swiftfilt-bench smoke --baseline baseline.json`, pinning one gating metric (`stream-throughput`) with a 35% tolerance — a catastrophe canary for a real (~1.5×) regression, not a precise perf gate. `baseline.json`'s thresholds are host-class-relative to the development machine; re-record from the runner on the nightly's first CI run if it breaches.
