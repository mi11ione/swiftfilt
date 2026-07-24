// Copyright (c) 2026 Roman Zhuzhgov
// Licensed under the Apache License, Version 2.0

/// Swift's modified Punycode (RFC 3492) transcoder, a faithful port of
/// apple/swift's `lib/Demangling/Punycode.cpp`. Swift's two deviations from
/// RFC 3492: the delimiter is `_` (not `-`), and uppercase `A`–`J` stand in
/// for the digits `0`–`9` in the encoding alphabet. Non-symbol ASCII is
/// carried through the surrogate range `0xD800..<0xD880` so operator and
/// other punctuation survive a round-trip.
///
/// All arithmetic mirrors the reference's explicit 32-bit overflow guards so
/// the accept/reject boundary on adversarial input is byte-identical.
enum SwiftPunycode {
    private static let base = 36
    private static let tmin = 1
    private static let tmax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128
    private static let delimiter: UInt8 = 0x5F // '_'
    private static let intMax = Int(Int32.max)

    @inline(__always)
    private static func digitValue(_ digit: Int) -> UInt8 {
        digit < 26 ? UInt8(0x61 + digit) : UInt8(0x41 - 26 + digit) // 'a'+d / 'A'-26+d
    }

    @inline(__always)
    private static func digitIndex(_ value: UInt8) -> Int {
        if value >= 0x61, value <= 0x7A { return Int(value) - 0x61 } // a-z -> 0..25
        if value >= 0x41, value <= 0x4A { return Int(value) - 0x41 + 26 } // A-J -> 26..35
        return -1
    }

    @inline(__always)
    private static func isValidUnicodeScalar(_ s: Int) -> Bool {
        s < 0xD880 || (s >= 0xE000 && s <= 0x10FFFF)
    }

    private static func adapt(_ delta0: Int, _ numpoints: Int, _ firsttime: Bool) -> Int {
        var delta = firsttime ? delta0 / damp : delta0 / 2
        delta += delta / numpoints
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= base - tmin
            k += base
        }
        return k + (((base - tmin + 1) * delta) / (delta + skew))
    }

    /// Decode Punycode `input` (ASCII bytes) to Unicode scalar values, or
    /// `nil` on malformed / overflowing input.
    @_optimize(speed)
    static func decode(_ input: [UInt8]) -> [Int]? {
        var out: [Int] = []
        out.reserveCapacity(input.count)
        var n = initialN
        var i = 0
        var bias = initialBias

        var start = 0
        if let lastDelimiter = input.lastIndex(of: delimiter) {
            for idx in 0 ..< lastDelimiter {
                let c = input[idx]
                if c > 0x7F { return nil }
                out.append(Int(c))
            }
            start = lastDelimiter + 1
        }

        var idx = start
        while idx < input.count {
            let oldi = i
            var w = 1
            var k = base
            while true {
                if idx >= input.count { return nil }
                let codePoint = input[idx]
                idx += 1
                let digit = digitIndex(codePoint)
                if digit < 0 { return nil }
                if digit > (intMax - i) / w { return nil }
                i += digit * w
                let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                if digit < t { break }
                if w > intMax / (base - t) { return nil }
                w *= base - t
                k += base
            }
            bias = adapt(i - oldi, out.count + 1, oldi == 0)
            if i / (out.count + 1) > intMax - n { return nil }
            n += i / (out.count + 1)
            i %= out.count + 1
            if n < 0x80 { return nil }
            out.insert(n, at: i)
            i += 1
        }
        return out
    }

    /// Decode Punycode `input` to a UTF-8 `String`, unmapping the surrogate
    /// range used for non-symbol ASCII. `nil` on malformed input.
    static func decodeToString(_ input: [UInt8]) -> String? {
        guard let scalars = decode(input) else { return nil }
        var view = String.UnicodeScalarView()
        view.reserveCapacity(scalars.count)
        for raw in scalars {
            if !isValidUnicodeScalar(raw) { return nil }
            var value = raw
            if value >= 0xD800, value < 0xD880 { value -= 0xD800 }
            guard let scalar = Unicode.Scalar(UInt32(value)) else { return nil }
            view.append(scalar)
        }
        return String(view)
    }

    /// Encode Unicode scalar values to Punycode bytes, or `nil` on overflow /
    /// invalid scalar.
    @_optimize(speed)
    static func encode(_ codePoints: [Int]) -> [UInt8]? {
        var out: [UInt8] = []
        var n = initialN
        var delta = 0
        var bias = initialBias

        var h = 0
        for c in codePoints {
            if c < 0x80 { h += 1; out.append(UInt8(c)) }
            if !isValidUnicodeScalar(c) { return nil }
        }
        let b = h
        if b > 0 { out.append(delimiter) }

        while h < codePoints.count {
            var m = 0x10FFFF
            for codePoint in codePoints where codePoint >= n && codePoint < m {
                m = codePoint
            }
            if (m - n) > (intMax - delta) / (h + 1) { return nil }
            delta += (m - n) * (h + 1)
            n = m
            for c in codePoints {
                if c < n {
                    if delta == intMax { return nil }
                    delta += 1
                }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                        if q < t { break }
                        out.append(digitValue(t + ((q - t) % (base - t))))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    out.append(digitValue(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return out
    }

    /// Re-encode UTF-8 `input` to Unicode scalar values. When
    /// `mapNonSymbolChars` is true, ASCII characters outside `[$_a-zA-Z0-9]`
    /// are carried through the surrogate range. `nil` on malformed UTF-8 or a
    /// surrogate code point. Minimal validation, matching the reference.
    private static func utf8ToScalars(_ input: [UInt8], mapNonSymbolChars: Bool) -> [Int]? {
        var out: [Int] = []
        var idx = 0
        let end = input.count
        @inline(__always) func isContinuation(_ unit: UInt8) -> Bool {
            (unit & 0xC0) == 0x80
        }
        while idx < end {
            let first = input[idx]; idx += 1
            var codePoint = 0
            if first < 0x80 {
                if ManglingChars.isValidSymbolChar(first) || !mapNonSymbolChars {
                    codePoint = Int(first)
                } else {
                    codePoint = Int(first) + 0xD800
                }
            } else if first < 0xC0 {
                return nil
            } else if first < 0xE0 {
                if idx >= end { return nil }
                let second = input[idx]; idx += 1
                if !isContinuation(second) { return nil }
                codePoint = (Int(first & 0x1F) << 6) | Int(second & 0x3F)
            } else if first < 0xF0 {
                if end - idx < 2 { return nil }
                let second = input[idx]; idx += 1
                let third = input[idx]; idx += 1
                if !isContinuation(second) || !isContinuation(third) { return nil }
                codePoint = (Int(first & 0xF) << 12) | (Int(second & 0x3F) << 6) | Int(third & 0x3F)
            } else if first < 0xF8 {
                if end - idx < 3 { return nil }
                let second = input[idx]; idx += 1
                let third = input[idx]; idx += 1
                let fourth = input[idx]; idx += 1
                if !isContinuation(second) || !isContinuation(third) || !isContinuation(fourth) { return nil }
                codePoint = (Int(first & 0x7) << 18) | (Int(second & 0x3F) << 12)
                    | (Int(third & 0x3F) << 6) | Int(fourth & 0x3F)
            } else {
                return nil
            }
            if !isValidUnicodeScalar(codePoint) { return nil }
            out.append(codePoint)
        }
        return out
    }

    /// Punycode-encode UTF-8 `input`, mapping non-symbol ASCII through the
    /// surrogate range when `mapNonSymbolChars`. `nil` on failure.
    static func encodeFromUTF8(_ input: [UInt8], mapNonSymbolChars: Bool) -> [UInt8]? {
        guard let scalars = utf8ToScalars(input, mapNonSymbolChars: mapNonSymbolChars) else { return nil }
        return encode(scalars)
    }
}
