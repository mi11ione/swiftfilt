// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

import SwiftFilt
import Testing

/// Printing Swift value ("integer") generic parameters (`RV` marker): renders as the bare `let A` — the value's type is carried in the mangling (and round-trips) but not printed, exactly as `swift-demangle` emits.
@Suite("Swift demangler value generic parameters")
struct SwiftDemanglerValueGenericTests {
    private let demangler = SwiftDemangler()
    private let printer = SwiftDemanglerPrinter()

    @Test func valueParameterRendersAsLetName() {
        let ast = demangler.demangle(symbol: "$s4main3fooyySiRVzlF")
        #expect(ast != nil)
        guard let ast else { return }
        #expect(printer.print(ast, style: .full) == "main.foo<let A>() -> ()")
        // .simplified drops the module qualifier and the return type.
        #expect(printer.print(ast, style: .simplified) == "foo<let A>()")
    }

    @Test func valueParameterRoundTrips() {
        let ast = demangler.demangle(symbol: "$s4main3fooyySiRVzlF")
        #expect(ast.flatMap { SwiftMangler().mangle($0) } == "$s4main3fooyySiRVzlF")
    }
}
