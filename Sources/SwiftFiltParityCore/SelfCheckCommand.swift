// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// `swiftfilt-parity selfcheck` — proof that the gate gates. A harness that
// only ever passes proves nothing; this subcommand injects synthetic
// divergences through the REAL classification/report pipeline (with the
// real on-disk deviations table) and asserts the tool would exit non-zero
// and name the offending row. It fails loudly if the gate fails to gate.

import Foundation
import SwiftFilt

public func runSelfCheckCommand(_ args: [String]) -> Int32 {
    guard args.isEmpty else {
        eprint("selfcheck: takes no options")
        return 2
    }
    let catalogue = DeviationCatalogue.load()
    var checks: [(name: String, passed: Bool, detail: String)] = []

    // 1. An uncatalogued divergence must gate and be named. The synthetic
    //    row uses a class/leg no real instrument emits and a mangled name
    //    no real symbol carries, so no plausible KNOWN-DEVIATIONS entry
    //    could ever mask it.
    do {
        var report = RunReport(instrument: "selfcheck", catalogue: catalogue)
        let synthetic = Divergence(
            leg: "selfcheck", klass: "synthetic-uncatalogued",
            mangled: "$s9selfcheck20SyntheticDivergenceV", swiftfilt: "injected", oracle: "injected-other",
        )
        report.record(synthetic)
        let rendered = report.render()
        let gates = report.exitCode != 0
        let named = rendered.contains("$s9selfcheck20SyntheticDivergenceV")
        checks.append((
            "uncatalogued divergence gates (exit non-zero)",
            gates, "exitCode=\(report.exitCode)",
        ))
        checks.append((
            "gating report names the offending row",
            named, named ? "row named in output" : "row MISSING from output:\n\(rendered)",
        ))
    }

    // 2. A divergence matching a catalogue entry must NOT gate — and must
    //    be reported under its id (classification, not suppression).
    do {
        let entry = DeviationEntry(
            id: "selfcheck-synthetic-entry", status: .expected,
            constraints: [("leg", "selfcheck"), ("class", "synthetic-catalogued"), ("mangled.prefix", "$s9selfcheck")],
        )
        var report = RunReport(instrument: "selfcheck", catalogue: DeviationCatalogue(entries: [entry], path: "<in-memory>"))
        report.record(Divergence(
            leg: "selfcheck", klass: "synthetic-catalogued",
            mangled: "$s9selfcheck9DeviationV", swiftfilt: "a", oracle: "b",
        ))
        let rendered = report.render()
        checks.append((
            "catalogued divergence does not gate",
            report.exitCode == 0, "exitCode=\(report.exitCode)",
        ))
        checks.append((
            "catalogued divergence is reported under its id",
            rendered.contains("selfcheck-synthetic-entry"), "id in output: \(rendered.contains("selfcheck-synthetic-entry"))",
        ))
    }

    // 3. The same matcher must not over-match: one differing clause and the
    //    row gates again (ANDed clauses, not any-of).
    do {
        let entry = DeviationEntry(
            id: "selfcheck-narrow-entry", status: .expected,
            constraints: [("leg", "selfcheck"), ("class", "synthetic-catalogued"), ("mangled.prefix", "$s9OTHER")],
        )
        var report = RunReport(instrument: "selfcheck", catalogue: DeviationCatalogue(entries: [entry], path: "<in-memory>"))
        report.record(Divergence(
            leg: "selfcheck", klass: "synthetic-catalogued",
            mangled: "$s9selfcheck9DeviationV", swiftfilt: "a", oracle: "b",
        ))
        checks.append((
            "a non-matching entry does not classify (clauses AND)",
            report.exitCode != 0, "exitCode=\(report.exitCode)",
        ))
    }

    // 4. End-to-end through a real instrument's diff logic: a fabricated
    //    fixture row with a wrong frozen column must produce a gating
    //    divergence that names the row.
    do {
        var out = CorpusOutcome()
        var report = RunReport(instrument: "selfcheck", catalogue: catalogue)
        out.compare("corpus-full", mangled: "$s4main3fooyyF", klass: "render-mismatch",
                    got: demangleForSelfCheck("$s4main3fooyyF"), expected: "DELIBERATELY-WRONG-EXPECTED")
        for divergence in out.divergences {
            report.record(divergence)
        }
        let rendered = report.render()
        checks.append((
            "a wrong frozen fixture column gates end-to-end",
            report.exitCode != 0 && rendered.contains("$s4main3fooyyF"),
            "exitCode=\(report.exitCode)",
        ))
    }

    // 5. The open-defect status must stay loud in the rendered report.
    do {
        let entry = DeviationEntry(
            id: "selfcheck-defect-entry", status: .openDefect,
            constraints: [("leg", "selfcheck"), ("class", "synthetic-defect")],
        )
        var report = RunReport(instrument: "selfcheck", catalogue: DeviationCatalogue(entries: [entry], path: "<in-memory>"))
        report.record(Divergence(leg: "selfcheck", klass: "synthetic-defect", mangled: "$s1x1yV", swiftfilt: "a", oracle: "b"))
        let rendered = report.render()
        checks.append((
            "open-defect entries render loudly",
            report.exitCode == 0 && rendered.contains("OPEN DEFECT"), "exitCode=\(report.exitCode)",
        ))
    }

    var failed = 0
    for check in checks {
        let mark = check.passed ? "ok" : "FAILED"
        print("[selfcheck] \(mark): \(check.name)\(check.passed ? "" : " — \(check.detail)")")
        if !check.passed { failed += 1 }
    }
    if failed == 0 {
        print("[selfcheck] PASSED: the gate gates (\(checks.count) checks)")
        return 0
    }
    eprint("[selfcheck] FAILED: \(failed) of \(checks.count) checks — the harness cannot be trusted to gate")
    return 1
}

/// The real engine demangling used by check 4 (kept tiny and local so the
/// self-check exercises the true product path, not a stub).
private func demangleForSelfCheck(_ mangled: String) -> String {
    SwiftFilt.demangle(mangled) ?? "<nil>"
}
