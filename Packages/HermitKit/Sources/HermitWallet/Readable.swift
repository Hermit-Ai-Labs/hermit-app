import Foundation

extension Units {
    /// A quoted amount as a person reads it: "5.518223344556677889900" -> "5.518". Four significant digits, but never
    /// fewer whole digits than the number has, and at most two decimals from 1,000 up ("12345.678" -> "12345.68").
    /// For what the model and the chat show; the exact amount stays with the quote and the review sheet.
    public static func approx(_ text: String) -> String {
        guard let v = Double(text.replacingOccurrences(of: ",", with: "")), v.isFinite else { return text }
        return approx(v)
    }

    public static func approx(_ v: Double) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        let decimals: Int
        if a >= 1000 { decimals = 2 }
        else { decimals = min(18, max(0, 3 - Int(floor(log10(a))))) }
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
