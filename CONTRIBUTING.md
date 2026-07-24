# Contributing to swiftfilt

swiftfilt's correctness claims are externally earned, continuously re-verified, and never weakened for convenience. This document is the bar every change is held to. It's deliberately strict — the trust infrastructure is what makes contributions safe to accept at all, including engine changes.

## Ground rules

**The library imports nothing.** `Sources/SwiftFilt` carries zero `import` statements, not even Foundation; `Sources/SwiftFiltCLICore` imports only SwiftFilt. `Scripts/check-no-imports.sh` enforces both in CI. A change that needs an import in the library is a design problem.

**100% coverage, per file, every column — with a pinned engine residue.** The library and CLI-core targets are held at 100% region/function/line coverage (`Scripts/coverage-gate.sh`). Coverage prevents crashes and dead code; correctness is owned by the oracles below. One carve-out: `Scripts/coverage-residue.txt` pins, by llvm-cov coordinates, the engine regions that remain unreached (proven-unreachable defensive arms and rare grammar arms lacking a crafted witness). The ledger is **shrink-only** — delete rows as regions gain coverage; never add one without an engine change, a documented unreachability argument, and maintainer sign-off. The gate fails on any missed region not in the ledger.

**No demangling-behavior change without an oracle.** Any change to what a name demangles to (tree shape, any of the four renderings, classify markers, remangling) must cite external ground truth: `swift-demangle` output from a pinned toolchain, or the apple/swift demangler source with file and function named. "It looks right" doesn't merge. From 1.0, any rendering change is a minor version recorded in the release notes; during 0.x the same discipline applies without the version guarantee.

**Every hand-crafted mangling is oracle-verified.** A synthesized fixture row (as opposed to one harvested from a real binary) must have its expected column produced by, or verified against, the reference tool — `swiftfilt-parity probe '<symbol>'` prints both sides. A hand-transcribed expectation is a self-mirror, not an oracle.

**Totality is non-negotiable.** Any byte sequence in, no crash, no hang, no uncontrolled recursion: a name either demangles or returns `nil`/throws the typed error. The totality battery (`swiftfilt-parity total`) and the fuzz sweep (`Scripts/total-crash-sweep.sh`) prove it; a crash on any input is a security bug (see [SECURITY.md](SECURITY.md)).

## What every change must pass

Run these locally before opening a PR; CI runs them all again.

```sh
swift test                                   # all suites
Scripts/check-no-imports.sh                  # zero-imports gate
Scripts/coverage-gate.sh                     # per-file 100% + residue ledger
swift build -c release --product swiftfilt-parity
.build/release/swiftfilt-parity corpus       # committed fixtures, all legs
.build/release/swiftfilt-parity selfcheck    # proof the gate gates
.build/release/swiftfilt-parity live         # vs live swift-demangle, 7 legs
.build/release/swiftfilt-parity roundtrip    # demangle → remangle → adjudicate
.build/release/swiftfilt-parity total        # totality/fuzz battery
```

The live legs need `swift-demangle` (macOS: any Xcode toolchain via `xcrun`; Linux: the toolchain ships it in `usr/bin`; `--oracle PATH` overrides discovery). Every subcommand consults `KNOWN-DEVIATIONS.md`; anything a run reports that the table doesn't match exits non-zero. The contract is zero unexplained rows. "Corpus green but live skipped" is not green — an engine or catalogue change must run the live and roundtrip legs too.

## KNOWN-DEVIATIONS discipline

`KNOWN-DEVIATIONS.md` is the complete, machine-read catalogue of expected swiftfilt↔oracle divergences. Two statuses, not interchangeable: `expected` is a by-design divergence, permanent until the scope changes; `open-defect` is a recorded swiftfilt bug awaiting a dedicated fix — the harness catalogues it instead of hiding it and reports it loudly on every run, and the entry MUST be removed by the change that fixes it, never merely re-worded. Every entry carries a matcher (mini-language documented in the file), evidence with the oracle version, a reproducer checkable with `swiftfilt-parity probe`, and its real-world-corpus hit count. A new unexplained divergence is a finding to fix or (with evidence) to catalogue, never to ignore. Widening a matcher to swallow more rows is the same as deleting the gate.

## Per-Swift-release re-validation

The oracle moves — each Swift release can add node kinds, rename renderings, extend the grammar. When a new toolchain ships: rerun the full live battery against the new `swift-demangle` at volume (`Scripts/acceptance-live-chunks.sh` checkpoints a full-corpus run) plus `roundtrip` and `corpus`; triage every new divergence (a grammar addition is an engine gap to port, a rendering change is a text-stability decision, an oracle bug is an entry with evidence); update the oracle-version line in `KNOWN-DEVIATIONS.md` and re-verify each reproducer. A toolchain-bump PR that skips this ritual doesn't merge.

## Code rules

- **Swift Testing.** `@Suite`/`@Test`/`#expect`, every suite with a `///` comment saying what it validates. Tests drive public API only (no `@testable import`). Test files are named for the behavior they validate, never for coverage.
- **Typed failures only.** The library throws exactly `DemangleError` from the two validating entry points; everything else returns optionals. `fatalError`/`precondition` on input-derived values is banned — hostile input produces `nil`, never a trap.
- **Value types, structural `Sendable`.** No `@unchecked Sendable`, no locks, no global mutable state in the library.
- **No `print` in the library.** The CLI writes through injected sinks; diagnostics are typed values.
- **Comments say why, briefly.** Durable rationale lives in the docs, not comment essays.

Read two existing files of the kind you're changing first. The codebase is the style guide.

## Conduct and security

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). Crash-on-hostile-input qualifies as a vulnerability here — see [SECURITY.md](SECURITY.md) for what qualifies and how to report privately.
