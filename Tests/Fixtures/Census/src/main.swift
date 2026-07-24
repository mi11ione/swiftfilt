// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0
//
// The census fixture program: a small, real Swift program whose compiled
// symbol population exercises every table the census verb aggregates —
// generic specializations (one origin instantiated at several types),
// protocol witnesses, closures and their partial-apply forwarders,
// accessors (get/set/didSet), default arguments, variable initializers,
// a class with init/deinit entry-point flavors, value-type metadata, and
// a deliberately dead function for the LinkMap's dead-stripped section.
// Standard library only, so regeneration needs nothing but a toolchain.

protocol Shape {
    var area: Double { get }
    func describe() -> String
}

struct Circle: Shape {
    var radius: Double
    var area: Double {
        radius * radius * 3.14159
    }

    func describe() -> String {
        "circle r=\(radius)"
    }
}

struct Box: Shape {
    var side: Double
    var area: Double {
        side * side
    }

    func describe() -> String {
        "box s=\(side)"
    }
}

final class Ledger {
    var total: Double = 0 {
        didSet { entries += 1 }
    }

    private(set) var entries: Int = 0
    static let name = "ledger"

    subscript(scaled factor: Double) -> Double {
        total * factor
    }

    func add(_ shape: some Shape, note: String = "entry") {
        total += shape.area
        _ = note
    }

    deinit {
        total = 0
    }
}

/// The generic origin the specialization table groups: instantiated at
/// Int, Double, and String below, so the census sees one origin with
/// several compiler-generated copies.
@inline(never)
func tally<T: Collection>(_ items: T) -> Int where T.Element: Equatable {
    var count = 0
    var previous: T.Element?
    for item in items {
        if item != previous { count += 1 }
        previous = item
    }
    return count
}

/// Never called: with -dead_strip the linker records it (and everything
/// only it references) in the LinkMap's dead-stripped section.
public func neverCalled(_ input: [Int]) -> Int {
    input.reduce(0, +)
}

func main() {
    let shapes: [any Shape] = [Circle(radius: 2), Box(side: 3), Circle(radius: 1)]
    let ledger = Ledger()
    for shape in shapes {
        ledger.add(shape)
    }
    ledger.add(Box(side: 5), note: "large")

    let descriptions = shapes.map { $0.describe() }
    let joined = descriptions.joined(separator: ", ")

    let intCount = tally([1, 2, 2, 3])
    let doubleCount = tally([1.5, 1.5, 2.5])
    let stringCount = tally(["a", "b", "b"])

    print("\(Ledger.name): total=\(ledger.total) entries=\(ledger.entries)")
    print("scaled=\(ledger[scaled: 2])")
    print("shapes: \(joined)")
    print("tallies: \(intCount) \(doubleCount) \(stringCount)")
}

main()
