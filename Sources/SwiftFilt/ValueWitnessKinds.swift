// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// The value-witness kinds, generated from apple/swift's
/// `include/swift/Demangling/ValueWitnessMangling.def`. The parser maps a
/// 2-character mangling code to the kind's ordinal (stored in the `ValueWitness`
/// node's index); the printer maps the ordinal back to the display word.
enum ValueWitnessKinds {
    struct Entry: Sendable { let code: String; let name: String }
    static let all: [Entry] = [
        Entry(code: "al", name: "allocateBuffer"),
        Entry(code: "ca", name: "assignWithCopy"),
        Entry(code: "ta", name: "assignWithTake"),
        Entry(code: "de", name: "deallocateBuffer"),
        Entry(code: "xx", name: "destroy"),
        Entry(code: "XX", name: "destroyBuffer"),
        Entry(code: "Xx", name: "destroyArray"),
        Entry(code: "CP", name: "initializeBufferWithCopyOfBuffer"),
        Entry(code: "Cp", name: "initializeBufferWithCopy"),
        Entry(code: "cp", name: "initializeWithCopy"),
        Entry(code: "Tk", name: "initializeBufferWithTake"),
        Entry(code: "tk", name: "initializeWithTake"),
        Entry(code: "pr", name: "projectBuffer"),
        Entry(code: "TK", name: "initializeBufferWithTakeOfBuffer"),
        Entry(code: "Cc", name: "initializeArrayWithCopy"),
        Entry(code: "Tt", name: "initializeArrayWithTakeFrontToBack"),
        Entry(code: "tT", name: "initializeArrayWithTakeBackToFront"),
        Entry(code: "xs", name: "storeExtraInhabitant"),
        Entry(code: "xg", name: "getExtraInhabitantIndex"),
        Entry(code: "ug", name: "getEnumTag"),
        Entry(code: "up", name: "destructiveProjectEnumData"),
        Entry(code: "ui", name: "destructiveInjectEnumTag"),
        Entry(code: "et", name: "getEnumTagSinglePayload"),
        Entry(code: "st", name: "storeEnumTagSinglePayload"),
    ]
    /// The ordinal for a 2-character mangling code, or `nil` if unknown.
    static func index(forCode code: String) -> Int? {
        all.firstIndex { $0.code == code }
    }

    /// The display word for an ordinal, or `nil` if out of range.
    static func name(forIndex index: Int) -> String? {
        index >= 0 && index < all.count ? all[index].name : nil
    }
}
