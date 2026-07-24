// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The allocation-site census — the instrument that proves WHERE the
// engine's remaining allocations come from (the recorded allocs/op
// figures are its counters). It hooks libmalloc's `malloc_logger`,
// captures a short backtrace per allocation event during N warmed-up
// demangle calls, and prints per-site counts and bytes — resolved to
// symbols through `atos` when available, atos-ready raw addresses
// otherwise.
//
// Darwin-only (the `malloc_logger` hook is libmalloc's); the mode says so
// and exits on other platforms. Run it release, like every bench mode:
//
//   swift run -c release swiftfilt-bench alloc-census
//   swift run -c release swiftfilt-bench alloc-census --census-workload oneshot \
//       --census-symbol '$s4main3fooyyF' --census-calls 2000
//
// Reading the output: `N/call` is allocation events per demangle call at
// that call stack (100c = 1.00/call); a site that scales with calls is a
// per-call cost, a small constant count is warmup residue. The workload is
// warmed first (session storage, arena slabs, printer buffer), so the
// census shows steady-state sites, which is what a hunt needs.

#if canImport(Darwin)
    import Darwin
    import Foundation
    import MachO
    import SwiftFilt

    private typealias MallocLoggerFn = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// The `malloc_logger` hook slot inside libmalloc. Single-threaded by
    /// construction, like the event log below.
    private nonisolated(unsafe) let loggerSlot: UnsafeMutablePointer<MallocLoggerFn?> = {
        let handle = dlopen(nil, RTLD_NOW)!
        return dlsym(handle, "malloc_logger")!.assumingMemoryBound(to: MallocLoggerFn?.self)
    }()

    /// Fixed-size event log: 8 return addresses + size per event. Static
    /// and preallocated because the hook runs inside malloc and must not
    /// allocate; single-threaded by construction (the census drives one
    /// workload loop on the main thread).
    private let maxCensusEvents = 4_000_000
    private nonisolated(unsafe) var eventFrames = UnsafeMutablePointer<UInt>.allocate(capacity: maxCensusEvents * 8)
    private nonisolated(unsafe) var eventSizes = UnsafeMutablePointer<UInt>.allocate(capacity: maxCensusEvents)
    private nonisolated(unsafe) var eventCount = 0
    private nonisolated(unsafe) let frameScratch = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
    private nonisolated(unsafe) var inHook = false

    private let censusHook: MallocLoggerFn = { type, _, arg2, arg3, _, _ in
        guard type & 2 != 0 else { return } // allocation events only
        guard eventCount < maxCensusEvents, !inHook else { return }
        inHook = true
        let size = type & 4 != 0 ? arg3 : arg2 // realloc carries size in arg3
        let captured = backtrace(frameScratch, 16)
        let base = eventCount * 8
        // Skip the hook + libmalloc frames (the first ~5); keep 8 callers.
        for k in 0 ..< 8 {
            let idx = 5 + k
            eventFrames[base + k] = idx < Int(captured) ? UInt(bitPattern: frameScratch[idx]) : 0
        }
        eventSizes[eventCount] = size
        eventCount += 1
        inHook = false
    }

    /// Run one allocation-site census pass and print the per-site report.
    @MainActor
    func runAllocCensus(workload: String, symbol: String, calls: Int) {
        let session = DemangleSession()
        // Steady state first: session storage, arena slabs, printer buffer,
        // and the one-shot path's warmable globals all settle here, so the
        // census measures per-call sites, not first-call buildup.
        for _ in 0 ..< 3000 {
            _ = session.demangle(symbol)
        }
        for _ in 0 ..< 50 {
            _ = demangle(symbol)
        }

        loggerSlot.pointee = censusHook
        switch workload {
        case "session":
            for _ in 0 ..< calls {
                _ = session.demangle(symbol)
            }
        case "oneshot":
            for _ in 0 ..< calls {
                _ = demangle(symbol)
            }
        default:
            loggerSlot.pointee = nil
            die("alloc-census: unknown workload '\(workload)' (session|oneshot)")
        }
        loggerSlot.pointee = nil

        var sites: [[UInt]: (count: Int, bytes: UInt)] = [:]
        for event in 0 ..< eventCount {
            let key = (0 ..< 8).map { eventFrames[event * 8 + $0] }
            let entry = sites[key] ?? (0, 0)
            sites[key] = (entry.count + 1, entry.bytes + eventSizes[event])
        }

        let slide = UInt(bitPattern: _dyld_get_image_vmaddr_slide(0))
        let names = resolveAddresses(
            Array(Set(sites.keys.flatMap(\.self))).filter { $0 != 0 },
            slide: slide,
        )
        print("alloc-census: workload=\(workload) symbol=\(symbol) calls=\(calls)")
        print("events=\(eventCount) — \(String(format: "%.2f", Double(eventCount) / Double(calls))) allocations/call")
        for (key, value) in sites.sorted(by: { $0.value.count > $1.value.count }) {
            let perCall = Double(value.count) / Double(calls)
            let bytesPerCall = value.bytes / UInt(calls)
            let frames = key.prefix(while: { $0 != 0 }).map { address in
                names[address] ?? "0x" + String(address, radix: 16)
            }
            print(String(format: "  %.2f/call %6d B/call: ", perCall, bytesPerCall) + frames.joined(separator: " <- "))
        }
        if eventCount == maxCensusEvents {
            print("note: event log filled (\(maxCensusEvents)); lower --census-calls for a complete census")
        }
    }

    /// Resolve `addresses` through one `atos` invocation against this
    /// binary; on any failure the census still prints (raw addresses plus
    /// the reproduction line), so the mode degrades, never lies.
    @MainActor
    private func resolveAddresses(_ addresses: [UInt], slide: UInt) -> [UInt: String] {
        guard !addresses.isEmpty, let binary = Bundle.main.executablePath else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
        process.arguments = ["-o", binary, "-s", "0x" + String(slide, radix: 16)]
            + addresses.map { "0x" + String($0, radix: 16) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            print("note: atos unavailable (\(error)); printing raw addresses — resolve with: atos -o \(binary) -s 0x\(String(slide, radix: 16)) <addr…>")
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            print("note: atos exited \(process.terminationStatus); printing raw addresses")
            return [:]
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        var names: [UInt: String] = [:]
        for (index, address) in addresses.enumerated() where index < lines.count {
            // Keep the symbol, drop the "(in swiftfilt-bench) (file:line)" tail.
            let resolved = lines[index].split(separator: " (in ").first.map(String.init) ?? String(lines[index])
            if !resolved.isEmpty { names[address] = resolved }
        }
        return names
    }
#else
    @MainActor
    func runAllocCensus(workload _: String, symbol _: String, calls _: Int) {
        die("alloc-census is Darwin-only (it hooks libmalloc's malloc_logger)")
    }
#endif
