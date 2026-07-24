#!/bin/sh
# Copyright (c) 2026 Roman Zhuzhgov
# Licensed under the Apache License, Version 2.0
#
# Zero-imports gate, the dependency-freedom contract mechanized:
#
#   - Sources/SwiftFilt (the shipped library) carries ZERO import
#     statements — not even Foundation. The engine is pure Swift over
#     the standard library, and stays that way.
#   - Sources/SwiftFiltCLICore (the testable CLI logic) imports ONLY
#     SwiftFilt — the CLI adds wiring, never a dependency.
#
# The executables (swiftfilt-cli's POSIX shim, swiftfilt-parity) and the
# parity instrument are deliberately NOT gated: the shim needs the
# platform's read/write/isatty, and the trust instrument needs Foundation
# for subprocess management. Neither ships as library API.
#
# Fails listing every offender. Runnable from anywhere; no arguments.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)"

# An import line: optional leading attributes (`@testable`, `@_exported`,
# …), then the `import` keyword. Comment lines never match the anchor.
import_pattern='^[[:space:]]*\(@[A-Za-z_()[:alnum:]]*[[:space:]]\{1,\}\)*import[[:space:]]'

status=0

engine_offenders="$(grep -rn "$import_pattern" "$root/Sources/SwiftFilt" --include='*.swift' || true)"
if [ -n "$engine_offenders" ]; then
    echo "check-no-imports: FAIL — import statements found in Sources/SwiftFilt (the engine imports nothing):" >&2
    echo "$engine_offenders" >&2
    status=1
fi

cli_offenders="$(grep -rn "$import_pattern" "$root/Sources/SwiftFiltCLICore" --include='*.swift' \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*import[[:space:]]\{1,\}SwiftFilt[[:space:]]*$' || true)"
if [ -n "$cli_offenders" ]; then
    echo "check-no-imports: FAIL — Sources/SwiftFiltCLICore may import only SwiftFilt; offenders:" >&2
    echo "$cli_offenders" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "check-no-imports: PASS — Sources/SwiftFilt imports nothing; Sources/SwiftFiltCLICore imports only SwiftFilt"
fi
exit "$status"
