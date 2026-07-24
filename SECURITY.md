# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| latest 0.x release | ✅ |
| anything older | ❌ |

During the 0.x window only the most recent release receives security fixes. From 1.0 this widens to the current major version.

## Reporting a vulnerability

Report privately through [GitHub's private vulnerability reporting](https://github.com/mi11ione/swiftfilt/security/advisories/new) (Security tab → "Report a vulnerability"). Please don't open a public issue for anything you believe is exploitable; for everything else the regular issue tracker is the right place.

Expect an acknowledgement within a few days. Confirmed issues are fixed in the next release, credited to the reporter unless anonymity is requested.

## What counts as a security issue

swiftfilt reads attacker-controllable bytes — symbol names from crash logs, binaries, build output, anything a pipe carries — and must stay safe no matter what they contain. The library's contract is total, crash-free demangling: any input either demangles or comes back `nil`/typed error, on a bounded stack, in bounded time, continuously re-proven by the in-repo fuzz battery. In scope for private reporting:

- **Any crash on any input** — a string, byte sequence, or stream that makes the CLI or library trap, overflow the stack, SIGSEGV, or abort. This includes crafted deeply-nested manglings; the CLI runs demangling on a dedicated wide stack precisely so recursion depth is not an input-controlled crash surface.
- **Any hang on any input** — a crafted name that makes demangling or scanning fail to terminate or grow without bound. Work stays proportional to input size.
- **Memory unsafety** — any input causing out-of-bounds reads or writes, or other undefined behavior.
- **Filter integrity** — an input that makes the stream filter corrupt bytes *outside* a validated mangled name (the byte-for-byte pass-through contract), which could smuggle content past log consumers.

Out of scope (file a regular issue): a *wrong demangling* — output differing from `swift-demangle` — is a correctness bug, which the parity harness and [`KNOWN-DEVIATIONS.md`](KNOWN-DEVIATIONS.md) exist for; crashes of the development-only tools (`swiftfilt-parity`, benchmarks) on their own inputs; and anything requiring a modified build. swiftfilt performs no network access, executes nothing it reads, and treats every input as untrusted text.
