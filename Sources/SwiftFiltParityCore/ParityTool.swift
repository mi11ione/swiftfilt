// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// swiftfilt-parity — the in-repo trust instrument. Not a shipped product:
// it re-earns the library's correctness claims against external ground
// truth (the toolchain's `swift-demangle`), the committed fixtures, and
// the library's own totality and round-trip contracts.
//
//   corpus     committed-fixture mode (the PR-speed default)
//   live       engine vs live `xcrun swift-demangle`, per style
//   roundtrip  demangle → remangle → compare, corpus-wide
//   total      the totality/fuzz battery (crash/hang/nil-or-valid)
//   selfcheck  proof that the gate gates
//
// Every subcommand consults KNOWN-DEVIATIONS.md; anything a run reports
// that is not matched by that table exits non-zero. The contract is zero
// unexplained rows.

import Foundation
import SwiftFiltCLICore

/// The instrument versions with the package; `CLI.version` is the single
/// source of truth.
public let parityVersion = CLI.version

public let parityUsage = """
usage: swiftfilt-parity <subcommand> [options]

subcommands:
  corpus [--inline-rows N]
      Committed-fixture mode (PR-speed, no subprocesses): every row of
      Tests/Fixtures/SwiftDemangling/*.tsv through the engine, diffed
      against the frozen expected columns (corpus.tsv all three
      oracle-backed styles + snapshot-declined superset contract +
      unqualified exercise + round-trip floor; apple.tsv .full;
      legacy.tsv .full/.simplified; trees.txt node-for-node), plus every
      CLI golden re-verified through the in-process CLI and the plain
      rewrites re-verified through the library filter.

  live [--skip N] [--limit N] [--tag T] [--legs L1,L2,…] [--batch N]
       [--jobs N] [--oracle PATH] [--timeout SEC] [--inline-rows N]
      Oracle mode: symbols through BOTH the engine and the live
      `xcrun swift-demangle`, diffed per leg — full (`-compact`),
      simplified (`-simplified`), qualified (`-no-sugar`), tree
      (`-tree-only`), classify (`-classify` leading markers), decline
      (decline agreement: the oracle echoes what it cannot demangle),
      unqualified (EXERCISED only: no oracle mode exists — its rendering
      substance is owned by the fixture suites, and this run gates on
      emptiness/crash). Symbols come from the committed fixtures;
      SWIFTFILT_DEMANGLE_CORPUS=<manifest.tsv> switches to the external
      corpus, streamed with bounded memory. `--skip N` resumes after the
      first N corpus rows and `--tag T` names the run's summary/TSV
      (`live-T-gating.tsv`) — together they make long sweeps
      checkpointable in foreground chunks that survive a lost session.

  roundtrip [--skip N] [--limit N] [--tag T] [--batch N] [--jobs N]
            [--oracle PATH] [--timeout SEC] [--inline-rows N]
      demangle → remangle (the shipped SwiftMangler) → compare, in two
      passes. Pass 1 (engine-only): byte-exact, or a lossless
      canonicalization that re-demangles to the identical tree (every
      legacy input that converts to $s losslessly included). Pass 2:
      every other row is adjudicated against the reference remangler
      (`swift-demangle -remangle-new`) — byte-equal conversions and
      mutual declines pass; a nil where the reference converts, a
      differing conversion, or an unadjudicable row gates. No oracle ⇒
      pass-2 rows gate as conversion-unadjudicated, never a silent pass.
      Exact counts per class, always.

  total [--items N] [--seed S] [--item-timeout-ms N] [--jobs N]
        [--battery NAME] [--from N] [--dump-items]
      The totality battery: random bytes, prefixed garbage, truncation
      sweeps of real symbols at every length, deep nesting, huge inputs,
      invalid UTF-8 through the byte scanner, and demangleAll
      pass-through — asserts nil-or-valid, never hangs (per-item
      watchdog). Deterministic under --seed (printed every run). A Swift
      runtime trap in the engine cannot be caught in-process; for
      crash-resilient enumeration shard with --battery/--from in
      subprocesses and localize with --dump-items (Scripts/total-crash-
      sweep.sh drives it) — a shard exit >128 is a crash finding.

  differential [--skip N] [--limit N] [--batch N] [--jobs N] [--inline-rows N]
      C2 backend-equivalence gate: every symbol through BOTH the bump-arena
      string path (`demangle(_:style:)`) and the `SwiftSymbol` value backend
      (`SwiftDemangler` + `SwiftDemanglerPrinter`), diffed per style
      (full/simplified/qualified/unqualified). No oracle, no
      KNOWN-DEVIATIONS — the two backends run the same generic bodies over
      two node representations, so the contract is exactly zero mismatches.
      Symbols come from the committed fixtures; SWIFTFILT_DEMANGLE_CORPUS
      switches to the external corpus, streamed with bounded memory and
      concurrent large-stack batches.

  selfcheck
      Proof that the gate gates: injects synthetic uncatalogued
      divergences through the real pipeline and asserts non-zero exit and
      row naming; also proves catalogued rows classify without gating.

  probe <symbol> …
      Evidence gatherer: one symbol's complete engine story (every
      rendering, tree, classify markers, remangling + self-consistency)
      side by side with the live oracle's. KNOWN-DEVIATIONS reproducers
      are checked with this.

environment: SWIFTFILT_DEMANGLE_CORPUS=<path to manifest.tsv> — external
  corpus for live/roundtrip (and the total truncation source); its rows
  are `mangled<TAB>first_binary<TAB>occurrences`.
exit codes: 0 clean · 1 unexplained divergence (or failed selfcheck) ·
  2 usage/setup error · 4 watchdog kill (hang finding)

KNOWN-DEVIATIONS.md (repo root) classifies expected divergences: matching
rows are reported under their entry id and do not gate. Anything
unmatched gates. The contract is zero unexplained rows.
"""

public func parityMain(_ arguments: [String]) async -> Int32 {
    // A batch child that exits early must surface as EPIPE on the stdin
    // write, not a fatal SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
    // Line-buffer stdout so progress lines flush live during long runs rather
    // than only at exit. glibc types `stdout` as a mutable C global that Swift 6
    // forbids referencing; Darwin exposes it usably, so this is Darwin-only
    // (on Linux the tool relies on default buffering — a progress nicety, not
    // correctness).
    #if canImport(Darwin)
        setvbuf(stdout, nil, _IOLBF, 0)
    #endif
    guard let subcommand = arguments.first else {
        print(parityUsage)
        return 2
    }
    let rest = Array(arguments.dropFirst())
    switch subcommand {
    case "corpus":
        return await runCorpusCommand(rest)
    case "live":
        return await runLiveCommand(rest)
    case "roundtrip":
        return await runRoundtripCommand(rest)
    case "total":
        return await runTotalCommand(rest)
    case "differential":
        return await runDifferentialCommand(rest)
    case "selfcheck":
        return runSelfCheckCommand(rest)
    case "probe":
        return await runProbeCommand(rest)
    case "--help", "-h", "help":
        print(parityUsage)
        return 0
    case "--version", "version":
        print("swiftfilt-parity \(parityVersion)")
        return 0
    default:
        eprint("swiftfilt-parity: unknown subcommand `\(subcommand)`")
        print(parityUsage)
        return 2
    }
}
