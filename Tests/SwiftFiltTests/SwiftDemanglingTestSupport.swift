// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import Foundation

/// Run `body` on a dedicated 128 MiB-stack thread and await its result.
///
/// Recursive demangle/`treeDump`/re-mangle/print descend one frame per tree level; the deepest
/// real corpus symbols nest ~131 levels (nested SwiftUI generics) and overflow the small
/// cooperative-pool / test-runner stack (a `SIGBUS`), as they do in `swift-demangle` without a
/// large stack — so suites feeding real symbols host their work here. The continuation bridge
/// keeps the caller in structured concurrency, freeing its cooperative thread.
func onLargeStack<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.stackSize = 128 << 20
        thread.start()
    }
}
