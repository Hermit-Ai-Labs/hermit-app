import Foundation

/// Cleans the raw stream: drops a <think>…</think> block if the model writes one, trims leading blank
/// lines, and turns middle-dot separators into commas.
public struct OutputFilter {
    public init() {}
    private var buffer = ""
    private var started = false
    private var inThink = false
    /// True once the reply should end: the model wrote a turn marker, or repeated a whole sentence.
    public private(set) var finished = false
    public static let stopMarkers = ["<|im_start|>", "<|im_end|>", "<|endoftext|>", "</s>"]

    public mutating func push(_ chunk: String) -> String {
        guard !finished else { return "" }
        buffer += chunk
        if let cut = Self.stopMarkers.compactMap({ buffer.range(of: $0)?.lowerBound }).min() {
            buffer = String(buffer[..<cut]); finished = true
        }
        var out = ""
        while !buffer.isEmpty {
            if inThink {
                guard let end = buffer.range(of: "</think>") else { return out }
                buffer = String(buffer[end.upperBound...]); inThink = false; continue
            }
            if let stray = buffer.range(of: "</think>") {   // reasoning that never opened a tag: drop it
                buffer = String(buffer[stray.upperBound...]); pending = ""; releasedTail = 0; continue
            }
            if let open = buffer.range(of: "<think>") {
                out += buffer[..<open.lowerBound]; buffer = String(buffer[open.upperBound...]); inThink = true; continue
            }
            // Hold back a possible partial "<think" at the end.
            if let lt = buffer.lastIndex(of: "<"), "<think>".hasPrefix(buffer[lt...]) {
                out += buffer[..<lt]; buffer = String(buffer[lt...]); break
            }
            out += buffer; buffer = ""
        }
        if !started {
            out = String(out.drop { $0.isWhitespace })
            if !out.isEmpty { started = true }
        }
        out = out.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "·", with: ",")
        return guardRepeats(out)
    }

    // MARK: Repetition guard
    // Text is released a sentence (or line) at a time. A sentence or line that already appeared ends the reply before
    // it is shown. A long unfinished sentence is released early unless it is the start of one we've already shown.

    private var pending = ""
    private var seen = Set<String>()
    private var releasedTail = 0   // characters of `pending` already shown while its sentence was still open
    private var repeated = false

    private mutating func guardRepeats(_ text: String) -> String {
        pending += text
        var out = ""
        while let end = pending.firstIndex(where: { ".!?\n".contains($0) }) {
            let cut = pending.index(after: end)
            let piece = String(pending[..<cut])
            let key = Self.key(piece)
            if key.count >= 18 {
                if seen.contains(key) { finished = true; repeated = true; pending = ""; return out }
                seen.insert(key)
            }
            out += piece.dropFirst(releasedTail)
            releasedTail = 0
            pending = String(pending[cut...])
        }
        // Open sentence: show it once it's clearly new, so long sentences still stream.
        let tailKey = Self.key(pending)
        if pending.count - releasedTail > 0, tailKey.count >= 40, !seen.contains(where: { $0.hasPrefix(tailKey) }) {
            out += pending.dropFirst(releasedTail)
            releasedTail = pending.count
        }
        return out
    }

    private static func key(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "*" || $0 == "#" }).joined(separator: " ")
    }

    /// A new assistant turn in the same reply (after tool results): its leading blank lines are trimmed again.
    /// Sentences already shown still count for the repeat guard.
    public mutating func newTurn() -> String {
        let rest = flush()
        buffer = ""; inThink = false; started = false
        return rest
    }

    /// Whatever is still held back when the reply ends normally.
    public mutating func flush() -> String {
        guard !repeated else { return "" }
        let rest = String(pending.dropFirst(releasedTail))
        pending = ""; releasedTail = 0
        return rest
    }
}
