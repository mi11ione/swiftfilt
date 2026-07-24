#!/bin/sh
# Copyright (c) 2026 Roman Zhuzhgov
# Licensed under the Apache License, Version 2.0
#
# Coverage gate: per-file 100% unit-test coverage across ALL reported
# columns (region, function, line — the branch column carries no Swift
# instrumentation and reports `-`) on the two gated targets:
#
#     Sources/SwiftFilt         (the shipped library: engine + product)
#     Sources/SwiftFiltCLICore  (the testable CLI logic)
#
# Coverage prevents crashes and dead code; correctness is owned by the
# corpus suites and the parity instrument.
#
# EXEMPT (deliberately not gated):
#   - Sources/SwiftFiltParityCore and Sources/swiftfilt-parity: the
#     in-repo trust instrument. It is never a shipped product, exists to
#     interrogate an external oracle (subprocess plumbing, timeouts,
#     process-kill paths that only a hung oracle can reach), and its own
#     correctness is proven by running it against that oracle — holding
#     its error-handling arms to unit-line-coverage would test the test.
#     Its behavior IS pinned by SwiftFiltParityTests, which must stay
#     green; it just isn't held to the 100%-per-file bar.
#   - Sources/swiftfilt-cli/main.swift: the thin POSIX shim (read/write/
#     isatty/exit plumbing around `CLI.run`). Every branch it guards is
#     an OS seam a unit test cannot honestly reach in-process; the whole
#     CLI SURFACE is tested through SwiftFiltCLICore with injected stdio.
#
# ENGINE RESIDUE LEDGER: Sources/SwiftFilt engine files are READ-ONLY
# this phase, and a residue of unreached regions remains — a mix of
# PROVEN-unreachable defensive arms (e.g. OldDemangler's `?? ""` after
# identifiers whose text is non-optional by construction, guards past
# `while true` loop invariants, single-callsite depth guards entered
# below their threshold) and rare grammar arms still lacking a crafted
# witness. Scripts/coverage-residue.txt pins every such region by its
# llvm-cov coordinates. The gate FAILS on any missed region NOT in that
# ledger (regressions and new gaps), and PASSES on any subset of it:
# llvm counter-expression artifacts can make a pinned region read as
# covered on some runs (the parity battery's random seed varies engine
# execution counts run to run), so an exact-count ratchet would flicker
# — region identity is the stable contract. Files with no ledger rows
# are held to exactly 100/100/100 in every column. Never add a ledger
# row without an engine change plus a documented argument; delete rows
# as they gain real coverage.
#
# Usage: Scripts/coverage-gate.sh [--skip-tests]
#   --skip-tests  reuse existing .build coverage data (CI runs tests
#                 separately; the default runs `swift test` here)

set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2

residue_file="$root/Scripts/coverage-residue.txt"
if [ ! -f "$residue_file" ]; then
    echo "coverage-gate: FAIL — residue ledger missing: $residue_file" >&2
    exit 1
fi
if ! command -v python3 > /dev/null 2>&1; then
    echo "coverage-gate: FAIL — python3 is required (region-level ledger comparison)" >&2
    exit 1
fi

skip_tests=0
[ "${1:-}" = "--skip-tests" ] && skip_tests=1

if [ "$skip_tests" -eq 0 ]; then
    echo "coverage-gate: running swift test --enable-code-coverage --no-parallel"
    # Serial: coverage stretches the real-thread-pool tests, which starve the
    # parallel test executor on a few-core machine (see ci.yml).
    swift test --enable-code-coverage --no-parallel > /dev/null 2>&1 || {
        echo "coverage-gate: FAIL — test run failed (rerun swift test for detail)" >&2
        exit 1
    }
fi

bin_path="$(swift build --show-bin-path)" || exit 2
profdata="$bin_path/codecov/default.profdata"
if [ ! -f "$profdata" ]; then
    echo "coverage-gate: FAIL — no coverage data at $profdata (run swift test --enable-code-coverage)" >&2
    exit 1
fi

# llvm-cov must come from the Swift toolchain (profdata format match).
if command -v xcrun > /dev/null 2>&1; then
    llvm_cov="xcrun llvm-cov"
elif command -v llvm-cov > /dev/null 2>&1; then
    llvm_cov="llvm-cov"
else
    swiftc_path="$(command -v swiftc)" || {
        echo "coverage-gate: FAIL — neither xcrun nor llvm-cov nor swiftc found" >&2
        exit 1
    }
    swiftc_real="$(readlink -f "$swiftc_path" 2> /dev/null || echo "$swiftc_path")"
    llvm_cov="$(dirname "$swiftc_real")/llvm-cov"
    if [ ! -x "$llvm_cov" ]; then
        echo "coverage-gate: FAIL — llvm-cov not found next to swiftc at $llvm_cov" >&2
        exit 1
    fi
fi

# One coverage MAPPING per gated target, against the profdata that merges
# every test target's counts (the library objects are shared, so counts
# accumulate across targets). Merging several binaries' mappings instead
# makes llvm-cov's counter expressions flicker run-to-run — one mapping
# per target keeps the report deterministic.
test_binary() {
    # Locate the coverage binary for a test target. macOS toolchains differ:
    # the Xcode build emits per-target bundles (SwiftFiltTests.xctest under
    # .build/out/Products/Debug), the SwiftPM CLI a single combined
    # <Package>PackageTests.xctest. Prefer the per-target bundle; fall back to
    # the combined one, which is usable for every source prefix (the report is
    # filtered by directory regardless). The executable is at
    # Contents/MacOS/<bundle-name> inside the bundle.
    for name in "$1" SwiftFiltPackageTests; do
        b="$(find .build -type d -name "$name.xctest" -print 2> /dev/null | head -1)"
        if [ -n "$b" ] && [ -f "$b/Contents/MacOS/$name" ]; then
            echo "$b/Contents/MacOS/$name"
            return 0
        fi
    done
    return 1
}

status=0
total_files=0
report_all=""

for spec in "SwiftFiltTests Sources/SwiftFilt/" "SwiftFiltCLITests Sources/SwiftFiltCLICore/"; do
    binary_name="${spec%% *}"
    dir="${spec#* }"
    binary="$(test_binary "$binary_name")"
    if [ -z "$binary" ] || [ ! -f "$binary" ]; then
        echo "coverage-gate: FAIL — coverage binary not found for $binary_name" >&2
        echo "coverage-gate: .xctest artifacts present under .build:" >&2
        find .build -name "*.xctest" -print 2> /dev/null | sed 's/^/  /' >&2
        exit 1
    fi
    report="$($llvm_cov report "$binary" -instr-profile "$profdata" -use-color=false 2> /dev/null)"
    if [ -z "$report" ]; then
        echo "coverage-gate: FAIL — llvm-cov report produced no output for $binary_name" >&2
        exit 1
    fi
    report_all="$report_all
$report"

    # Column layout: 1 file, 2 regions, 3 missed regions, 5 functions,
    # 6 missed functions, 8 lines, 9 missed lines.
    rows="$(printf '%s\n' "$report" | awk -v d="$dir" '$1 ~ "^"d".*\\.swift$" { print $1, $3, $6, $9 }')"
    if [ -z "$rows" ]; then
        echo "coverage-gate: FAIL — no $dir rows in the $binary_name coverage report" >&2
        exit 1
    fi

    while IFS=' ' read -r file mr mf ml; do
        total_files=$((total_files + 1))
        if ! grep -q "^$file " "$residue_file"; then
            if [ "$mr" != "0" ] || [ "$mf" != "0" ] || [ "$ml" != "0" ]; then
                echo "coverage-gate: FAIL — $file below 100% (missed regions=$mr functions=$mf lines=$ml)" >&2
                status=1
            fi
        fi
    done <<EOF
$rows
EOF
done

# Region-identity check for ledgered files: every missed code region in
# the current run must be pinned in the residue ledger; anything new is
# a regression. Evaluated per target against its own mapping (see above).
if ! python3 - "$bin_path" "$profdata" "$residue_file" <<'PYEOF'
import json, subprocess, sys, collections, os

bin_path, profdata, residue_file = sys.argv[1], sys.argv[2], sys.argv[3]
pins = set()
pinned_files = set()
for line in open(residue_file):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    path, region = line.rsplit(" ", 1)
    pins.add((path, region))
    pinned_files.add(path)

def binary(name):
    # Per-target bundle (Xcode build) or the combined <Package>PackageTests
    # bundle (SwiftPM CLI); mirror test_binary() in the shell above.
    import glob
    for candidate in (name, "SwiftFiltPackageTests"):
        for exe in glob.glob(f".build/**/{candidate}.xctest/Contents/MacOS/{candidate}", recursive=True):
            if os.path.isfile(exe):
                return exe
    return f"{bin_path}/{name}.xctest/Contents/MacOS/{name}"

failures = []
covered_pins = set()
seen_pins = set()
for name, prefix in [("SwiftFiltTests", "Sources/SwiftFilt/"),
                     ("SwiftFiltCLITests", "Sources/SwiftFiltCLICore/")]:
    cmd = ["xcrun", "llvm-cov", "export", binary(name), "-instr-profile", profdata,
           "Sources/SwiftFilt", "Sources/SwiftFiltCLICore"]
    try:
        out = subprocess.run(cmd, capture_output=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        cmd = ["llvm-cov", "export", binary(name), "-instr-profile", profdata,
               "Sources/SwiftFilt", "Sources/SwiftFiltCLICore"]
        out = subprocess.run(cmd, capture_output=True, check=True).stdout
    data = json.loads(out)
    per = collections.defaultdict(dict)
    for fn in data["data"][0]["functions"]:
        fnames = fn["filenames"]
        for r in fn["regions"]:
            ls, cs, le, ce, count, fid, _, kind = r
            if kind != 0:
                continue
            f = fnames[fid] if fid < len(fnames) else fnames[0]
            i = f.find(prefix)
            if i < 0:
                continue
            key = (ls, cs, le, ce)
            d = per[f[i:]]
            d[key] = d.get(key, 0) + count
    for f, regions in per.items():
        if f not in pinned_files:
            continue  # unpinned files are enforced by the report pass
        for (ls, cs, le, ce), count in regions.items():
            region = f"{ls}:{cs}-{le}:{ce}"
            if (f, region) in pins:
                seen_pins.add((f, region))
                if count > 0:
                    covered_pins.add((f, region))
            elif count == 0:
                failures.append(f"{f} {region}")

if failures:
    print("coverage-gate: FAIL — missed regions not in the residue ledger (new gaps or regressions):", file=sys.stderr)
    for f in sorted(failures):
        print(f"  {f}", file=sys.stderr)
    sys.exit(1)
print(f"coverage-gate: residue ledger — {len(pins)} pinned regions, "
      f"{len(covered_pins)} reading covered this run (llvm counter artifacts or ratchet-down candidates)")
sys.exit(0)
PYEOF
then
    status=1
fi

# Every ledger entry must still exist as a source file (a deleted or
# renamed engine file must leave the ledger in the same change).
missing_ledger="$(grep -v '^#' "$residue_file" | awk 'NF { print $1 }' | sort -u | while IFS= read -r file; do
    if [ ! -f "$file" ]; then echo "$file"; fi
done)"
if [ -n "$missing_ledger" ]; then
    echo "coverage-gate: FAIL — ledger entries for missing files:" >&2
    printf '%s\n' "$missing_ledger" >&2
    status=1
fi

# Census cross-check: every gated source file must either appear in its
# target's coverage report or be PROVEN declaration-only. llvm-cov emits
# no mapping for a file with zero executable regions (pure declaration
# files — e.g. SwiftManglingConstants.swift), so absence alone is not a
# gap; but absence with executable declarations in the source would be a
# silently-green hole, and fails. The proof is token-level on
# comment-stripped source; doc text cannot satisfy it, and a token inside
# a string literal can only cause a loud FAIL, never a pass.
declaration_only=0
missing_with_code=""
files_list="${TMPDIR:-/tmp}/coverage-gate-files.$$"
seen_list="${TMPDIR:-/tmp}/coverage-gate-seen.$$"
missing_list="${TMPDIR:-/tmp}/coverage-gate-missing.$$"
find Sources/SwiftFilt Sources/SwiftFiltCLICore -name '*.swift' | sort > "$files_list"
printf '%s\n' "$report_all" | awk '$1 ~ /^Sources\/(SwiftFilt|SwiftFiltCLICore)\/.*\.swift$/ { print $1 }' | sort -u > "$seen_list"
comm -23 "$files_list" "$seen_list" > "$missing_list"
while IFS= read -r missing; do
    if sed 's@//.*@@' "$missing" | grep -qE '(^|[^[:alnum:]_])(func|init|var|subscript|deinit)([^[:alnum:]_]|$)'; then
        missing_with_code="$missing_with_code  missing from report despite executable declarations: $missing
"
    else
        declaration_only=$((declaration_only + 1))
    fi
done < "$missing_list"
rm -f "$files_list" "$seen_list" "$missing_list"
if [ -n "$missing_with_code" ]; then
    echo "coverage-gate: FAIL — files absent from the coverage report that are not declaration-only:" >&2
    printf '%s' "$missing_with_code" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    ledgered_files="$(grep -v '^#' "$residue_file" | awk 'NF { print $1 }' | sort -u | grep -c .)"
    at_hundred=$((total_files - ledgered_files))
    echo "coverage-gate: PASS — $at_hundred gated files at 100% across all columns; $ledgered_files read-only engine files within their pinned residue; $declaration_only declaration-only file(s) verified free of executable declarations"
fi
exit "$status"
