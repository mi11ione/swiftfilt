#!/bin/sh
# Copyright (c) 2026 Roman Zhuzhgov
# Licensed under the Apache License, Version 2.0
#
# Builds the census test fixtures from the checked-in Swift source in
# Tests/Fixtures/Census/src, then locks the census CLI goldens under
# Tests/Fixtures/CLI/golden. The fixtures are REAL tool output over a
# real program — never hand-typed listings:
#
#   LinkMap.txt    the ld link map of the compiled fixture program
#                  (-map, -dead_strip so the map carries a real
#                  `# Dead Stripped Symbols:` section, -reproducible so
#                  rebuilds are byte-stable per toolchain). Compiled via
#                  an explicit relative-path .o so the map's object-file
#                  and output paths are machine-independent; the SDK
#                  .tbd rows in `# Object files:` do vary by Xcode
#                  install, which census output never echoes (it prints
#                  only the table's row count).
#   nm.txt         `nm` over the fixture binary — the BSD/llvm-nm
#                  Mach-O shape (address, type char, name; U rows for
#                  undefined imports).
#   nm-sized.txt   the `llvm-nm --print-size` (ELF) shape, generated
#                  from LinkMap.txt's real rows because Mach-O carries
#                  no symbol sizes (`nm --print-size` on Mach-O warns
#                  "sizes … are always zero"): real manglings, real
#                  sizes, `%016x %016x %c %s` rows plus real undefined
#                  imports from nm.txt as size-less `U` rows. Every
#                  Swift-prefixed name is oracle-verified through
#                  `xcrun swift-demangle` before the file freezes.
#
# The fixture program is standard-library-only; regeneration needs only
# a Swift toolchain (macOS with Xcode command-line tools for nm/ld). A
# different toolchain may shift sizes and symbol sets, in which case the
# goldens re-lock from the rebuilt fixtures — the goldens normalize
# nothing.
#
# Usage: Scripts/build-census-fixtures.sh

set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
census="$root/Tests/Fixtures/Census"
golden="$root/Tests/Fixtures/CLI/golden"

echo "building the census fixture program..."
cd "$census"
rm -rf build
mkdir build
swiftc -O -module-name CensusFixture -c src/main.swift -o build/main.o
swiftc -O -module-name CensusFixture build/main.o -o build/census-fixture \
    -Xlinker -map -Xlinker LinkMap.txt \
    -Xlinker -dead_strip \
    -Xlinker -reproducible

echo "sanity-running the fixture program..."
./build/census-fixture > /dev/null

echo "capturing nm.txt..."
nm build/census-fixture > nm.txt

echo "generating nm-sized.txt from the LinkMap's real rows..."
python3 - << 'PY'
import re
import subprocess
import sys

rows = []
section = None
for line in open("LinkMap.txt"):
    line = line.rstrip("\n")
    if line.startswith("#"):
        if line.startswith("# Symbols:"):
            section = "symbols"
        elif line.startswith("# Dead Stripped Symbols:"):
            section = None
        continue
    if section != "symbols" or not line:
        continue
    m = re.match(r"^0x([0-9A-Fa-f]+)\t0x([0-9A-Fa-f]+)\t\[ *\d+\] (.*)$", line)
    if not m:
        sys.exit("nm-sized generation: unparseable # Symbols: row: %r" % line)
    address, size, name = int(m.group(1), 16), int(m.group(2), 16), m.group(3)
    # The sized-nm shape is a symbol table: keep symbol-shaped names only
    # (linkmap content atoms like `literal string: …` have no place in an
    # nm dump).
    if re.fullmatch(r"[A-Za-z0-9_$.@]+", name):
        rows.append((address, size, name))

if len(rows) < 40:
    sys.exit("nm-sized generation: only %d rows survived; the fixture lost its population" % len(rows))

undefined = []
for line in open("nm.txt"):
    if line.startswith(" ") and " U " in line:
        undefined.append(line.rsplit(" U ", 1)[1].strip())
undefined = sorted(undefined)[:4]
if len(undefined) < 4:
    sys.exit("nm-sized generation: expected at least 4 undefined imports in nm.txt")

# Oracle-verify every Swift-prefixed name before freezing: each must
# demangle through the reference tool (swift-demangle echoes inputs it
# declines, so a changed output IS the proof of demanglability).
swiftish = [n for _, _, n in rows if n.startswith(("_$s", "$s"))]
swiftish += [n for n in undefined if n.startswith(("_$s", "$s"))]
oracle = subprocess.run(
    ["xcrun", "swift-demangle", "-compact", *swiftish],
    capture_output=True, text=True, check=True,
).stdout.splitlines()
for name, demangled in zip(swiftish, oracle):
    if demangled.strip() == name:
        sys.exit("nm-sized generation: oracle declined %r; refusing to freeze it" % name)
print("  oracle-verified %d Swift names through xcrun swift-demangle" % len(swiftish))

with open("nm-sized.txt", "w") as out:
    for address, size, name in rows:
        out.write("%016x %016x %c %s\n" % (address, size, "t", name))
    for name in undefined:
        out.write("%s U %s\n" % (" " * 16, name))
print("  nm-sized.txt: %d sized rows + %d undefined" % (len(rows), len(undefined)))
PY

rm -rf build

echo "locking census goldens..."
cd "$root"
swift build > /dev/null
swiftfilt="$root/.build/debug/swiftfilt"
map="Tests/Fixtures/Census/LinkMap.txt"
nm_plain="Tests/Fixtures/Census/nm.txt"
nm_sized="Tests/Fixtures/Census/nm-sized.txt"
crash="Tests/Fixtures/CLI/input/crash-log.txt"

"$swiftfilt" census --color never < "$map" > "$golden/census-linkmap.txt"
"$swiftfilt" census --color never --top 3 < "$map" > "$golden/census-linkmap.top3.txt"
"$swiftfilt" census --json < "$map" > "$golden/census-linkmap.ndjson"
"$swiftfilt" census --json --slim < "$map" > "$golden/census-linkmap.slim.ndjson"
"$swiftfilt" census --color never < "$nm_plain" > "$golden/census-nm.txt"
"$swiftfilt" census --json --slim < "$nm_plain" > "$golden/census-nm.slim.ndjson"
"$swiftfilt" census --color never < "$nm_sized" > "$golden/census-nm-sized.txt"
"$swiftfilt" census --json < "$nm_sized" > "$golden/census-nm-sized.ndjson"
"$swiftfilt" census --color never < "$crash" > "$golden/census-bare.txt"
"$swiftfilt" census --json < "$crash" > "$golden/census-bare.ndjson"

echo "census fixtures and goldens locked:"
ls -l "$census"/LinkMap.txt "$census"/nm.txt "$census"/nm-sized.txt "$golden"/census-*
