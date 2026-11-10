import Foundation
import Compression

/// Reads the entries of a ZIP file (what .xlsx, .docx and friends are) without any library: the central directory
/// says where each entry is, stored entries are copied and deflated ones are inflated with Apple's Compression
/// (COMPRESSION_ZLIB is raw DEFLATE). No ZIP64, no encryption: an .xlsx never needs them.
public struct ZipArchive {
    public struct Entry: Sendable {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }
    let data: Data
    public let entries: [Entry]
    /// The most one entry may inflate to, so a hostile file can't fill memory.
    public static let maxEntrySize = 64 << 20

    public init?(_ data: Data) {
        self.data = data
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 3 < b.count ? u16(i) | u16(i + 2) << 16 : 0 }
        // End of central directory: the last 0x06054b50, within the last 64 KiB + 22 bytes.
        guard b.count >= 22 else { return nil }
        var eocd = -1
        var i = b.count - 22
        let stop = max(0, b.count - 22 - 65_535)
        while i >= stop { if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var list: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014b50 else { return nil }
            let method = UInt16(u16(p + 10)), csize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nameLen <= b.count else { return nil }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            list.append(Entry(name: name, method: method, compressedSize: csize, size: size, localOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    public func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// The entry's bytes, or nil when it's missing, too big, or in a form this reader doesn't handle.
    public func read(_ name: String) -> Data? {
        guard let e = entry(name), e.size <= Self.maxEntrySize else { return nil }
        let b = data
        let lo = e.localOffset
        guard lo + 30 <= b.count, b[b.startIndex + lo] == 0x50, b[b.startIndex + lo + 1] == 0x4b else { return nil }
        let nameLen = Int(b[b.startIndex + lo + 26]) | Int(b[b.startIndex + lo + 27]) << 8
        let extraLen = Int(b[b.startIndex + lo + 28]) | Int(b[b.startIndex + lo + 29]) << 8
        let start = lo + 30 + nameLen + extraLen
        guard start + e.compressedSize <= b.count else { return nil }
        let raw = b.subdata(in: (b.startIndex + start)..<(b.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8:
            if e.size == 0 { return Data() }
            var out = Data(count: e.size)
            let n = out.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
            }
            return n == e.size ? out : nil
        default: return nil
        }
    }
}

/// An .xlsx workbook's sheets as rows of cell text: shared strings, inline strings, numbers (shortest form, so
/// 0.1 reads 0.1 and not 0.1000000000000000055), booleans. Formulas give their cached value. Empty cells keep their
/// column so rows line up.
public enum XLSXText {
    public struct Sheet: Sendable { public let name: String; public let rows: [[String]] }

    public static func sheets(_ data: Data) -> [Sheet]? {
        guard let zip = ZipArchive(data), zip.entry("xl/workbook.xml") != nil else { return nil }
        let shared = zip.read("xl/sharedStrings.xml").map(SharedStrings.parse) ?? []
        // Sheet order and names from workbook.xml, files from its relationships; any worksheet left over after them.
        let book = zip.read("xl/workbook.xml").map(Workbook.parse) ?? []
        let rels = zip.read("xl/_rels/workbook.xml.rels").map(Rels.parse) ?? [:]
        var files: [(String, String)] = book.compactMap { s in
            guard let t = rels[s.rid] else { return nil }
            let path = t.hasPrefix("/") ? String(t.dropFirst()) : (t.hasPrefix("xl/") ? t : "xl/" + t)
            return (s.name, path)
        }
        if files.isEmpty {
            files = zip.entries.map(\.name).filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }.map { (String($0.dropFirst("xl/worksheets/".count).dropLast(4)), $0) }
        }
        return files.compactMap { name, path in zip.read(path).map { Sheet(name: name, rows: SheetRows.parse($0, shared: shared)) } }
    }

    /// Rows as CSV lines (cells with commas or quotes quoted), trailing empty cells dropped.
    public static func csv(_ rows: [[String]]) -> [String] {
        rows.map { r in
            var cells = r
            while cells.last?.isEmpty == true { cells.removeLast() }
            return cells.map { c in c.contains(",") || c.contains("\"") || c.contains("\n") ? "\"" + c.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : c }
                .joined(separator: ",")
        }.filter { !$0.isEmpty }
    }

    // MARK: XML

    final class SharedStrings: NSObject, XMLParserDelegate {
        var out: [String] = [], cur = "", inT = false, inSI = false, inRPh = false
        static func parse(_ d: Data) -> [String] { let s = SharedStrings(); let p = XMLParser(data: d); p.delegate = s; p.parse(); return s.out }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(e) { case "si": inSI = true; cur = ""; case "t": inT = true; case "rPh": inRPh = true; default: break }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inSI && inT && !inRPh { cur += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(e) { case "si": inSI = false; out.append(cur); case "t": inT = false; case "rPh": inRPh = false; default: break }
        }
    }

    final class Workbook: NSObject, XMLParserDelegate {
        var out: [(name: String, rid: String)] = []
        static func parse(_ d: Data) -> [(name: String, rid: String)] { let s = Workbook(); let p = XMLParser(data: d); p.delegate = s; p.parse(); return s.out }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            guard local(e) == "sheet", let name = a["name"], let rid = a.first(where: { local($0.key) == "id" })?.value else { return }
            out.append((name, rid))
        }
    }

    final class Rels: NSObject, XMLParserDelegate {
        var out: [String: String] = [:]
        static func parse(_ d: Data) -> [String: String] { let s = Rels(); let p = XMLParser(data: d); p.delegate = s; p.parse(); return s.out }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if local(e) == "Relationship", let id = a["Id"], let t = a["Target"] { out[id] = t }
        }
    }

    final class SheetRows: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = [], row: [String] = []
        var col = 0, type = "", value = "", inV = false, inIS = false, inT = false
        /// Stop after this many rows: the text is cut for the model anyway, and a 1M-row sheet shouldn't stall the phone.
        static let maxRows = 5000
        init(shared: [String]) { self.shared = shared }
        static func parse(_ d: Data, shared: [String]) -> [[String]] {
            let s = SheetRows(shared: shared); let p = XMLParser(data: d); p.delegate = s; p.parse(); return s.rows
        }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch local(e) {
            case "row": row = []
            case "c":
                type = a["t"] ?? ""; value = ""
                col = a["r"].map(Self.column) ?? row.count
            case "v": inV = true
            case "is": inIS = true
            case "t": inT = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inV || (inIS && inT) { value += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(e) {
            case "v": inV = false
            case "t": inT = false
            case "is": inIS = false
            case "c":
                let text: String
                switch type {
                case "s": text = Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                case "b": text = value == "1" ? "TRUE" : "FALSE"
                case "inlineStr", "str", "e": text = value
                default: text = Self.number(value)
                }
                if col >= 0, col < 16_384 {
                    while row.count < col { row.append("") }
                    if row.count == col { row.append(text) } else { row[col] = text }
                }
            case "row":
                rows.append(row)
                if rows.count >= Self.maxRows { p.abortParsing() }
            default: break
            }
        }
        /// "B12" -> 1.
        static func column(_ ref: String) -> Int {
            var n = 0
            for ch in ref.uppercased() { guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }; n = n * 26 + Int(a - 64) }
            return n - 1
        }
        static func number(_ v: String) -> String {
            guard v.contains(".") || v.contains("E") || v.contains("e"), let d = Double(v), d.isFinite else { return v }
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return d.description
        }
    }
}

private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

/// Fits a file's text to the model's budget at a line boundary, saying how much was kept.
public enum FileBudget {
    /// (text, note) where note is nil when nothing was cut, else "the first 140 of 600 lines".
    public static func cut(_ text: String, limit: Int = Attachment.maxChars, unit: String = "lines") -> (String, String?) {
        guard text.count > limit else { return (text, nil) }
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = [], used = 0
        for l in lines {
            if used + l.count + 1 > limit { break }
            kept.append(l); used += l.count + 1
        }
        if kept.isEmpty { return (String(text.prefix(limit)), "the first \(limit) characters") }
        return (kept.joined(separator: "\n"), "the first \(kept.count) of \(lines.count) \(unit)")
    }
}
