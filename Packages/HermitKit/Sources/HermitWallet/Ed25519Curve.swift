import Foundation

/// Just enough GF(2^255 - 19) arithmetic to answer one question Solana needs: is a 32-byte string a valid
/// compressed ed25519 point? Program-derived addresses (associated token accounts) must be OFF the curve.
/// Matches curve25519-dalek's `CompressedEdwardsY::decompress().is_some()`. Not used for any secret data.
enum Ed25519Curve {
    typealias Fe = [UInt64] // 4 little-endian limbs, always reduced below p

    static let p: Fe = [0xFFFF_FFFF_FFFF_FFED, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF]
    static let one: Fe = [1, 0, 0, 0]
    /// d = -121665/121666 mod p
    static let d: Fe = fromBigEndianHex("52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3")
    static let pMinus2: Fe = [0xFFFF_FFFF_FFFF_FFEB, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF]
    static let halfPMinus1: Fe = [0xFFFF_FFFF_FFFF_FFF6, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0x3FFF_FFFF_FFFF_FFFF]

    static func isOnCurve(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 32 else { return false }
        var y: Fe = [0, 0, 0, 0]
        for i in 0..<32 { y[i / 8] |= UInt64(bytes[i]) << (8 * UInt64(i % 8)) }
        y[3] &= 0x7FFF_FFFF_FFFF_FFFF // the top bit is the sign of x
        y = reduce(y)
        let yy = mul(y, y)
        let u = sub(yy, one)
        let v = add(mul(d, yy), one)
        let w = mul(u, pow(v, pMinus2))
        if w == [0, 0, 0, 0] { return true }
        return pow(w, halfPMinus1) == one // Euler's criterion
    }

    static func fromBigEndianHex(_ h: String) -> Fe {
        let b = [UInt8](hex: h)!.reversed().map { $0 }
        var f: Fe = [0, 0, 0, 0]
        for i in 0..<32 { f[i / 8] |= UInt64(b[i]) << (8 * UInt64(i % 8)) }
        return f
    }

    static func geq(_ a: Fe, _ b: Fe) -> Bool {
        for i in (0..<4).reversed() where a[i] != b[i] { return a[i] > b[i] }
        return true
    }

    static func rawSub(_ a: Fe, _ b: Fe) -> Fe {
        var r: Fe = [0, 0, 0, 0]; var borrow: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (s2, o2) = s1.subtractingReportingOverflow(borrow)
            r[i] = s2; borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return r
    }

    static func reduce(_ a: Fe) -> Fe {
        var r = a
        while geq(r, p) { r = rawSub(r, p) }
        return r
    }

    /// Folds a 5-limb value (limb 4 small) back below 2^256 using 2^256 = 38 (mod p), then below p.
    static func fold(_ t: [UInt64]) -> Fe {
        var r = Array(t[0..<4]); var carry = t[4]
        while carry != 0 {
            let (hi, lo) = carry.multipliedFullWidth(by: 38)
            var c = hi
            var (s, o) = r[0].addingReportingOverflow(lo)
            r[0] = s; var k: UInt64 = o ? 1 : 0
            for i in 1..<4 {
                (s, o) = r[i].addingReportingOverflow(k); r[i] = s; k = o ? 1 : 0
            }
            c += k; carry = c
        }
        return reduce(r)
    }

    static func add(_ a: Fe, _ b: Fe) -> Fe {
        var r: [UInt64] = [0, 0, 0, 0, 0]; var k: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(k)
            r[i] = s2; k = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        r[4] = k
        return fold(r)
    }

    static func sub(_ a: Fe, _ b: Fe) -> Fe {
        geq(a, b) ? rawSub(a, b) : add(a, rawSub(p, b))
    }

    static func mul(_ a: Fe, _ b: Fe) -> Fe {
        var t = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (hi, lo) = a[i].multipliedFullWidth(by: b[j])
                var (s, o1) = t[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s.addingReportingOverflow(carry)
                s = s2
                t[i + j] = s
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0) // cannot overflow: hi <= 2^64 - 2
            }
            t[i + 4] = carry
        }
        // t = high * 2^256 + low = high * 38 + low (mod p)
        var r: [UInt64] = [t[0], t[1], t[2], t[3], 0]
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (hi, lo) = t[i + 4].multipliedFullWidth(by: 38)
            let (s1, o1) = r[i].addingReportingOverflow(lo)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        r[4] = carry
        return fold(r)
    }

    static func pow(_ base: Fe, _ e: Fe) -> Fe {
        var r = one
        for i in (0..<256).reversed() {
            r = mul(r, r)
            if (e[i / 64] >> UInt64(i % 64)) & 1 == 1 { r = mul(r, base) }
        }
        return r
    }
}
