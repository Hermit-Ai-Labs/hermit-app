import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import HermitCore

/// Turns a file the user attached into text for the model, on this device: CSV, text, Markdown and JSON as they are,
/// spreadsheets (.xlsx) cell by cell, PDFs through PDFKit (scanned pages through Vision), and images through Vision's
/// text recognition. Nothing is uploaded; the text goes into the prompt, and leaves the device only in Private Cloud
/// mode, like anything else typed in chat. Address and amount rows are kept from the whole file for batch sends.
enum AttachmentReader {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    static let sheetExtensions: Set<String> = ["xlsx", "xlsm"]
    /// The biggest file read whole (spreadsheets, PDFs, images, a CSV for its rows).
    static let maxBytes = 40 << 20
    /// Scanned PDFs: pages read with Vision when there's no text layer.
    static let maxOCRPages = 6

    /// Reads a picked or dropped file. Slow parts (PDF, OCR, unzip) run off the main thread.
    static func read(_ url: URL) async -> Attachment {
        await Task.detached(priority: .userInitiated) { readNow(url) }.value
    }

    /// Reads image bytes from the photo library.
    static func read(imageData: Data, name: String) async -> Attachment {
        await Task.detached(priority: .userInitiated) {
            var a = Attachment(name, kind: .chart, size: ByteCountFormatter.string(fromByteCount: Int64(imageData.count), countStyle: .file), source: "Photos")
            fill(&a, ocr: CGImageSourceCreateWithData(imageData as CFData, nil).flatMap(upright).map(recognize) ?? "")
            return a
        }.value
    }

    static func readNow(_ url: URL) -> Attachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let size = bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : ""
        var a = Attachment(url.lastPathComponent, size: size)
        guard bytes <= maxBytes else { a.detail = "too big to read here"; return a }

        if sheetExtensions.contains(ext) {
            guard let d = try? Data(contentsOf: url), let sheets = XLSXText.sheets(d) else { a.detail = "spreadsheet Hermit couldn't open"; return a }
            let rows = sheets.reduce(0) { $0 + $1.rows.count }
            var parts: [String] = []
            for s in sheets {
                let lines = XLSXText.csv(s.rows)
                guard !lines.isEmpty else { continue }
                parts.append((sheets.count > 1 ? "Sheet \(s.name):\n" : "") + lines.joined(separator: "\n"))
            }
            let all = parts.joined(separator: "\n\n")
            a.recipients = RecipientTable.parse(all)
            let (text, note) = FileBudget.cut(all, unit: "rows")
            a.text = text; a.cutNote = note; a.truncated = note != nil
            a.detail = sheets.count == 1 ? "spreadsheet, \(rows) rows" : "spreadsheet, \(sheets.count) sheets, \(rows) rows"
            return a
        }
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { a.detail = "PDF Hermit couldn't open"; return a }
            if doc.isLocked { a.detail = "locked PDF"; return a }
            var pages: [String] = []
            for i in 0..<doc.pageCount {
                let t = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !t.isEmpty { pages.append((doc.pageCount > 1 ? "Page \(i + 1)\n" : "") + t) }
            }
            var how = ""
            if pages.isEmpty {
                // A scan: no text layer. Read the first pages as images.
                for i in 0..<min(doc.pageCount, maxOCRPages) {
                    guard let page = doc.page(at: i), let img = render(page) else { continue }
                    let t = recognize(img)
                    if !t.isEmpty { pages.append((doc.pageCount > 1 ? "Page \(i + 1)\n" : "") + t) }
                }
                how = doc.pageCount > maxOCRPages ? ", scanned, first \(maxOCRPages) pages read on this device" : ", scanned, read on this device"
            }
            a.detail = "PDF, \(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")" + how
            guard !pages.isEmpty else { return a }
            let all = pages.joined(separator: "\n\n")
            a.recipients = RecipientTable.parse(all)
            let (text, note) = FileBudget.cut(all)
            a.text = text; a.cutNote = note; a.truncated = note != nil
            return a
        }
        if imageExtensions.contains(ext) {
            fill(&a, ocr: CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(upright).map(recognize) ?? "")
            return a
        }
        // Text files: the existing reader for the part the model sees, and the whole file for address rows.
        var t = Attachment.read(url)
        if t.text != nil {
            if ["csv", "tsv", "txt", "text", "md", "json"].contains(ext) || ext.isEmpty, bytes <= 4 << 20,
               let whole = try? String(contentsOf: url, encoding: .utf8) {
                t.recipients = RecipientTable.parse(whole)
                let (text, note) = FileBudget.cut(whole, unit: ext == "csv" || ext == "tsv" ? "rows" : "lines")
                t.text = text; t.cutNote = note; t.truncated = note != nil
            }
            if ext == "csv" || ext == "tsv" { t.detail = "table" }
        }
        return t
    }

    static func fill(_ a: inout Attachment, ocr: String) {
        a.detail = ocr.isEmpty ? "image, no text found" : "image, text read on this device"
        guard !ocr.isEmpty else { return }
        a.recipients = RecipientTable.parse(ocr)
        let (text, note) = FileBudget.cut(ocr)
        a.text = text; a.cutNote = note; a.truncated = note != nil
    }

    // MARK: Vision

    /// The image the right way up (EXIF orientation applied), at most 3,000 px on its long side.
    static func upright(_ src: CGImageSource) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 3000]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Text in an image, line by line in reading order (words on the same line joined, so table rows stay rows).
    static func recognize(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch { return "" }
        let obs = (req.results ?? []).compactMap { o -> (box: CGRect, text: String)? in
            o.topCandidates(1).first.map { (o.boundingBox, $0.string) }
        }.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(box: CGRect, text: String)]] = []
        for o in obs {
            if let last = lines.last?.first, abs(last.box.midY - o.box.midY) < max(last.box.height, o.box.height) * 0.5 {
                lines[lines.count - 1].append(o)
            } else { lines.append([o]) }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ") }.joined(separator: "\n")
    }

    /// A PDF page as an image for text recognition, about 2,000 px wide.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(4, 2000 / box.width)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}

extension Attachment {
    /// The chip's second line: size, and what Hermit read ("12 KB, spreadsheet, 48 rows").
    var chipLine: String { [size, detail ?? ""].filter { !$0.isEmpty }.joined(separator: ", ") }
}
