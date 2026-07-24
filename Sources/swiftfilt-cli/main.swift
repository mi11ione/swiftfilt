// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Thin entry point by design: argv, raw stdin chunks, raw stdout/stderr
// writers, and the TTY flag go to SwiftFiltCLICore's run entry;
// everything testable lives there. This file owns the only platform
// code: POSIX read/write (no Foundation), and a dedicated wide-stack
// thread for the deeply recursive demangle/print paths.

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(ucrt)
    import ucrt
#endif
import SwiftFiltCLICore

/// The stdio wiring: chunked reads from fd 0, drain-everything writes to
/// fd 1/2. A caseless enum so the helpers are plain nonisolated statics
/// regardless of top-level-code isolation inference.
private enum Stdio {
    /// The read(2) size: 1 MiB when stdin is a regular file (reads always
    /// return full buffers there, so bigger reads hand the parallel filter
    /// region-scale chunks in one syscall — sized just under the round
    /// target so buffered memory stays bounded by the round), 64 KiB
    /// otherwise (a pipe returns at most its own buffer per read anyway).
    static let readSize: Int = {
        #if canImport(Darwin) || canImport(Glibc)
            var status = stat()
            if fstat(0, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG {
                return 1 << 20
            }
        #endif
        return 1 << 16
    }()

    /// The rotating chunk buffers behind ``readChunk()``: a read(2) fills a
    /// retained buffer in place and hands it out as the chunk. By the time
    /// the same buffer rotates back (two reads later) every consumer loop
    /// has dropped its reference, so the in-place fill finds it uniquely
    /// referenced and steady-state reads allocate nothing. Two buffers, not
    /// one, so the previous read's chunk stays intact while the next read
    /// fills. Correct under ANY consumer: a holder just makes the next fill
    /// COW-copy — unshared, never aliased. Single-threaded by construction
    /// (one stdin reader on the main loop), hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static var chunkBufferA: [UInt8] = []
    private nonisolated(unsafe) static var chunkBufferB: [UInt8] = []
    private nonisolated(unsafe) static var chunkParity = false

    /// One read(2) of up to ``readSize`` from stdin, retried on EINTR.
    /// `nil` at end of input — and on a read error, which is reported to
    /// stderr first (an unreadable stdin ends the stream; it does not
    /// corrupt what was already filtered).
    static func readChunk() -> [UInt8]? {
        // Take (not copy) this rotation slot's buffer so the fill below sees
        // one reference; restore its full length first (a no-op after a full
        // read, only the trimmed tail after a short one). The slot is pinned
        // before the success path advances the parity, so the defer returns
        // the buffer to the slot it came from.
        let slot = chunkParity
        var buffer: [UInt8]
        if slot {
            buffer = chunkBufferB
            chunkBufferB = []
        } else {
            buffer = chunkBufferA
            chunkBufferA = []
        }
        if buffer.count < readSize {
            buffer.append(contentsOf: repeatElement(0, count: readSize - buffer.count))
        }
        defer {
            // Store the (possibly trimmed) buffer back into its slot —
            // shared with the returned chunk until the consumer drops it.
            if slot {
                chunkBufferB = buffer
            } else {
                chunkBufferA = buffer
            }
        }
        while true {
            var count = 0
            buffer.withUnsafeMutableBytes { raw in
                count = _read_call(0, raw.baseAddress!, raw.count)
            }
            if count > 0 {
                buffer.removeLast(readSize - count)
                chunkParity.toggle()
                return buffer
            }
            if count == 0 {
                return nil
            }
            #if canImport(Darwin) || canImport(Glibc)
                if errno == EINTR { continue }
            #endif
            write(2, "swiftfilt: error: cannot read standard input\n")
            return nil
        }
    }

    /// Whether another `readChunk()` would return without blocking —
    /// poll(2) with a zero timeout. The parallel filter coalesces reads
    /// only while this answers true, so a live trickle (`tail -f`) keeps
    /// its per-line flush and a saturating source fills whole regions.
    /// `false` on platforms without poll (coalescing simply stays off)
    /// and on any poll error.
    static func inputAvailable() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
            var probe = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            // A zero timeout cannot block; EINTR just reads as "not now".
            return poll(&probe, 1, 0) > 0 && (probe.revents & Int16(POLLIN | POLLHUP)) != 0
        #else
            return false
        #endif
    }

    /// The platform read(2) spelling.
    private static func _read_call(_ fd: Int32, _ pointer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.read(fd, pointer, count)
        #elseif canImport(Glibc)
            Glibc.read(fd, pointer, count)
        #else
            Int(_read(fd, pointer, UInt32(count)))
        #endif
    }

    /// Write every byte to `fd`, retrying partial writes and EINTR.
    /// Each call is written straight through — no user-space buffering
    /// layer sits between the filter and the pipe, which is what keeps
    /// `tail -f | swiftfilt` live.
    static func write(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            guard var cursor = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                #if canImport(Darwin) || canImport(Glibc)
                    let written = _write_call(fd, cursor, remaining)
                    if written > 0 {
                        cursor += written
                        remaining -= written
                        continue
                    }
                    if errno == EINTR { continue }
                #else
                    let written = _write_call(fd, cursor, remaining)
                    if written > 0 {
                        cursor += written
                        remaining -= written
                        continue
                    }
                #endif
                // An unwritable stream (not a closed pipe, which raises
                // SIGPIPE and ends the process in the classic filter way):
                // nothing sane to do but stop pushing.
                return
            }
        }
    }

    static func write(_ fd: Int32, _ text: String) {
        write(fd, Array(text.utf8))
    }

    /// The platform write(2) spelling.
    private static func _write_call(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.write(fd, pointer, count)
        #elseif canImport(Glibc)
            Glibc.write(fd, pointer, count)
        #else
            Int(_write(fd, pointer, UInt32(count)))
        #endif
    }

    /// Whether stdout is a terminal (`--color auto`).
    static var standardOutputIsTTY: Bool {
        #if canImport(Darwin) || canImport(Glibc)
            isatty(1) != 0
        #else
            _isatty(1) != 0
        #endif
    }

    /// Windows text-mode translation would rewrite `\r\n` and choke on
    /// `^Z`; byte-identity requires binary stdio. No-op on POSIX.
    static func setBinaryStdio() {
        #if canImport(ucrt) && !canImport(Darwin) && !canImport(Glibc)
            _ = _setmode(0, _O_BINARY)
            _ = _setmode(1, _O_BINARY)
            _ = _setmode(2, _O_BINARY)
        #endif
    }
}

/// Carries the run across the wide-stack thread boundary; joined before
/// `status` is read, so the handoff is race-free.
private final class RunContext {
    let body: () -> Int32
    var status: Int32 = 0

    init(_ body: @escaping () -> Int32) {
        self.body = body
    }
}

/// Run `body` on a dedicated 64 MiB-stack thread and return its status.
///
/// The demangle / print / tree-dump recursion descends one frame per node
/// level; real-world symbols nest beyond a hundred levels (nested SwiftUI
/// generics) and a crafted mangling can go far deeper, which overflows
/// default thread stacks (`swift-demangle` has the same failure mode). A
/// wide stack removes that crash class for the price of one thread. Falls
/// back to running inline if the thread cannot be created (and on
/// Windows, where the main-thread stack is a link-time setting).
private func runOnDemanglerStack(_ body: @escaping () -> Int32) -> Int32 {
    #if canImport(Darwin) || canImport(Glibc)
        var attributes = pthread_attr_t()
        guard pthread_attr_init(&attributes) == 0,
              pthread_attr_setstacksize(&attributes, 64 << 20) == 0
        else {
            return body()
        }
        #if canImport(Darwin)
            // Same QoS as the parallel filter's pool threads: the run
            // thread claims worker jobs alongside them, so an asymmetric
            // class would park the caller's share on efficiency cores.
            _ = pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INITIATED, 0)
        #endif
        defer { pthread_attr_destroy(&attributes) }
        let context = RunContext(body)
        let raw = Unmanaged.passRetained(context).toOpaque()
        #if canImport(Darwin)
            var thread: pthread_t?
            let created = pthread_create(&thread, &attributes, { raw in
                let context = Unmanaged<RunContext>.fromOpaque(raw).takeUnretainedValue()
                context.status = context.body()
                return nil
            }, raw)
            guard created == 0, let started = thread else {
                Unmanaged<RunContext>.fromOpaque(raw).release()
                return body()
            }
        #else
            var started = pthread_t()
            let created = pthread_create(&started, &attributes, { raw in
                guard let raw else { return nil }
                let context = Unmanaged<RunContext>.fromOpaque(raw).takeUnretainedValue()
                context.status = context.body()
                return nil
            }, raw)
            guard created == 0 else {
                Unmanaged<RunContext>.fromOpaque(raw).release()
                return body()
            }
        #endif
        pthread_join(started, nil)
        let status = context.status
        Unmanaged<RunContext>.fromOpaque(raw).release()
        return status
    #else
        return body()
    #endif
}

// The platform worker pool behind the parallel filter: persistent
// pthreads with the same 64 MiB stacks as the main demangler thread
// (every thread that demangles needs the deep-recursion headroom), woken
// per round through a condition-variable job queue. The calling thread
// participates as a worker too, so a pool of N−1 threads reports N
// workers and rounds use every core without idling the caller.
//
// Lives for the process (created at most once, when a rewrite-mode
// filter run first engages parallelism); the threads park on the work
// condition between rounds and die with the process.
#if canImport(Darwin) || canImport(Glibc)
    private final class PosixWorkerPool: FilterWorkerPool, @unchecked Sendable {
        private(set) var workerCount = 1

        // The mutex/condition storage is pointer-allocated (a pthread
        // mutex must never be copied) and intentionally never freed —
        // the pool is process-lifetime by design.
        private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        private let workCond = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
        private let doneCond = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)

        // Round state, all guarded by `mutex`.
        private var generation: UInt64 = 0
        private var jobsTotal = 0
        private var nextJob = 0
        private var completed = 0
        private var roundBody: (@Sendable (Int) -> Void)?

        /// Build a pool for `requested` workers (0 = one per online CPU),
        /// or `nil` when parallelism cannot help (a single-CPU host, or
        /// no thread could be created). The clamp bounds thread count on
        /// absurd requests without second-guessing reasonable ones.
        static func make(requested: Int) -> PosixWorkerPool? {
            let online = Int(sysconf(Int32(_SC_NPROCESSORS_ONLN)))
            let target = requested == 0 ? online : min(requested, 32)
            guard target >= 2 else { return nil }
            let pool = PosixWorkerPool()
            pool.start(target: target)
            return pool.workerCount >= 2 ? pool : nil
        }

        private init() {
            pthread_mutex_init(mutex, nil)
            pthread_cond_init(workCond, nil)
            pthread_cond_init(doneCond, nil)
        }

        private func start(target: Int) {
            var attributes = pthread_attr_t()
            var started = 0
            if pthread_attr_init(&attributes) == 0,
               pthread_attr_setstacksize(&attributes, 64 << 20) == 0
            {
                #if canImport(Darwin)
                    _ = pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INITIATED, 0)
                #endif
                // Each worker holds a retain on the pool: once any thread
                // exists the pool is immortal (parked workers must never
                // outlive the state they wake to read) — the deliberate
                // process-lifetime design, not a leak to fix.
                for _ in 1 ..< target { // the calling thread is worker N
                    let raw = Unmanaged.passRetained(self).toOpaque()
                    #if canImport(Darwin)
                        var thread: pthread_t?
                        if pthread_create(&thread, &attributes, { raw in
                            Unmanaged<PosixWorkerPool>.fromOpaque(raw).takeUnretainedValue().workerLoop()
                            return nil
                        }, raw) == 0, thread != nil {
                            started += 1
                        } else {
                            Unmanaged<PosixWorkerPool>.fromOpaque(raw).release()
                        }
                    #else
                        var thread = pthread_t()
                        let created = pthread_create(&thread, &attributes, { raw in
                            guard let raw else { return nil }
                            Unmanaged<PosixWorkerPool>.fromOpaque(raw).takeUnretainedValue().workerLoop()
                            return nil
                        }, raw)
                        if created == 0 {
                            started += 1
                        } else {
                            Unmanaged<PosixWorkerPool>.fromOpaque(raw).release()
                        }
                    #endif
                }
                pthread_attr_destroy(&attributes)
            }
            workerCount = started + 1
        }

        func run(jobs: Int, _ body: @escaping @Sendable (Int) -> Void) {
            pthread_mutex_lock(mutex)
            roundBody = body
            jobsTotal = jobs
            nextJob = 0
            completed = 0
            generation &+= 1
            pthread_cond_broadcast(workCond)
            // The caller claims jobs alongside the pool threads: rounds
            // use every core, and a jobs=1 round needs no wakeup at all.
            while nextJob < jobsTotal {
                let job = nextJob
                nextJob += 1
                pthread_mutex_unlock(mutex)
                body(job)
                pthread_mutex_lock(mutex)
                completed += 1
            }
            while completed < jobsTotal {
                pthread_cond_wait(doneCond, mutex)
            }
            roundBody = nil
            pthread_mutex_unlock(mutex)
        }

        private func workerLoop() {
            pthread_mutex_lock(mutex)
            var seen: UInt64 = 0
            while true {
                while generation == seen {
                    pthread_cond_wait(workCond, mutex)
                }
                seen = generation
                while nextJob < jobsTotal, let body = roundBody {
                    let job = nextJob
                    nextJob += 1
                    pthread_mutex_unlock(mutex)
                    body(job)
                    pthread_mutex_lock(mutex)
                    completed += 1
                    if completed == jobsTotal {
                        // Only the caller waits on doneCond; one signal
                        // per round completion is enough.
                        pthread_cond_signal(doneCond)
                    }
                }
            }
        }
    }

    private func makeWorkerPool(requested: Int) -> FilterWorkerPool? {
        PosixWorkerPool.make(requested: requested)
    }
#else
    private func makeWorkerPool(requested _: Int) -> FilterWorkerPool? {
        nil // no pthread pool on this platform; the filter stays sequential
    }
#endif

Stdio.setBinaryStdio()
let status = runOnDemanglerStack {
    CLI.run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        input: Stdio.readChunk,
        inputAvailable: Stdio.inputAvailable,
        makeWorkerPool: makeWorkerPool(requested:),
        writeOutput: { Stdio.write(1, $0) },
        writeError: { Stdio.write(2, $0) },
        standardOutputIsTTY: Stdio.standardOutputIsTTY,
        fileExists: { path in
            // Portable existence probe for the args-mode file hint (fopen,
            // not stat: the one probe every libc spells the same way).
            guard let handle = fopen(path, "rb") else { return false }
            fclose(handle)
            return true
        },
    )
}

exit(status)
