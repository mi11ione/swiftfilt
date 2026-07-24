// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// Thin entry point: all logic lives in SwiftFiltParityCore so it is
// unit-testable (mirroring the swiftfilt-cli / SwiftFiltCLICore split).

import Foundation
import SwiftFiltParityCore

let arguments = Array(CommandLine.arguments.dropFirst())
let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var exitCode: Int32 = 2
Task.detached {
    exitCode = await parityMain(arguments)
    semaphore.signal()
}

semaphore.wait()
exit(exitCode)
