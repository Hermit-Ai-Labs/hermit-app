import Foundation
import HermitWallet

// MARK: Typed amounts

/// One strict reader for every amount typed on Trade: plain decimal digits with an optional dot and thousands commas.
/// "inf", "nan", "1e3" and "0x10" are rejected (Double() takes some of them), and so is anything from 1e15 up.
enum TradeAmount {
    static func value(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !t.isEmpty, t != "." else { return nil }
        var dots = 0
        for u in t.unicodeScalars {
            if u == "." { dots += 1 } else if u.value < 48 || u.value > 57 { return nil }
        }
        guard dots <= 1, let v = Double(t), v.isFinite, v < 1e15 else { return nil }
        return v
    }

    /// Exact base units for typed text ("1.5" with 6 decimals -> 1_500_000), through the wallet's own parser.
    /// Nil for junk, zero, more decimals than the token has, or anything that doesn't fit a UInt64.
    static func baseUnits(text: String, decimals: Int) -> UInt64? {
        guard let v = try? Units.parse(text, decimals: decimals), v > 0 else { return nil }
        return UInt64(exactly: v)
    }

    /// Base units for an amount Hermit worked out itself (a dollar amount over a price). Rounds down, so it never
    /// spends more than the amount; nil when it isn't a finite positive number or doesn't fit a UInt64.
    static func baseUnits(_ amount: Double, decimals: Int) -> UInt64? {
        guard amount.isFinite, amount > 0 else { return nil }
        let x = (amount * pow(10, Double(decimals))).rounded(.down)
        guard x >= 1, x < 1.8e19 else { return nil }
        return UInt64(exactly: x)
    }

    /// A number written for an amount field: always a dot, never grouping, whatever the device's region.
    static func text(_ v: Double, maxFraction: Int = 4) -> String {
        v.formatted(.number.precision(.fractionLength(0...maxFraction)).grouping(.never).locale(Locale(identifier: "en_US")))
    }
}

// MARK: Approval results

/// What an approval's `perform` returned: a transaction hash, or a plain result line (a Hyperliquid fill has no hash,
/// only "Filled 0.5 at $72.2"). Hashes get shortened for display; a result line is shown whole.
enum TxText {
    static func looksLikeHash(_ s: String) -> Bool {
        if s.hasPrefix("0x") { return s.count > 10 && s.dropFirst(2).allSatisfy(\.isHexDigit) }
        // Solana signatures and NEAR hashes: base58, no spaces.
        let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        return (32...90).contains(s.count) && s.allSatisfy { base58.contains($0) }
    }
}
