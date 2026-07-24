// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// Constants shared by the Swift demangler, remangler, and printer, lifted
/// verbatim from apple/swift (`include/swift/Strings.h`,
/// `include/swift/Demangling/ManglingMacros.h`, and the parser/remangler
/// recursion guards).
enum SwiftManglingConstants {
    /// The standard-library module name (`STDLIB_NAME`).
    static let stdlibName = "Swift"
    /// The Objective-C module name a `So` substitution expands to
    /// (`MANGLING_MODULE_OBJC`).
    static let objCModule = "__C"
    /// The Clang-importer synthesized module name a `SC` substitution expands
    /// to (`MANGLING_MODULE_CLANG_IMPORTER`).
    static let clangImporterModule = "__C_Synthesized"
    /// The LLDB-expression module prefix (`LLDB_EXPRESSIONS_MODULE_NAME_PREFIX`).
    static let lldbExpressionsModulePrefix = "__lldb_expr_"

    /// The stable-ABI mangling prefix (`MANGLING_PREFIX_STR`).
    static let manglingPrefix = "$s"
    /// The Embedded-Swift mangling prefix (`MANGLING_PREFIX_EMBEDDED_STR`).
    static let embeddedManglingPrefix = "$e"

    /// Cap on a single substitution's repeat count
    /// (`SubstitutionMerging::MaxRepeatCount`); guards against blow-up on a
    /// bogus `…A832456823746582B…`.
    static let maxRepeatCount = 2048
    /// Remangler / printer recursion-depth ceiling.
    static let maxDepth = 1024
    /// Printer recursion-depth ceiling (`NodePrinter::MaxDepth`).
    static let maxPrintDepth = 768
    /// Parse-exit tree-depth ceiling — ours, not the reference's (whose
    /// iterative driver loop parses any depth and relies on the printer
    /// cap alone). A tree nested beyond this declines at the demangler
    /// exit: every downstream consumer the printer cap does not bound —
    /// the tree dump, the classifier walks, and the value tree's own
    /// (recursive) teardown once it escapes to a caller — descends one
    /// frame per level, so the tree itself must be bounded. Chosen more
    /// than 3× beyond the printer cap so a decline can only hit trees
    /// whose rendering is already `<<too complex>>`-saturated in every
    /// grammar shape (print depth advances at least once per 3 tree
    /// levels), and ~31× beyond the deepest real-corpus symbol (~131
    /// levels).
    static let maxTreeDepth = 4096
    /// Cap on intra-identifier word substitutions (`Words[26]`).
    static let maxNumWords = 26
}
