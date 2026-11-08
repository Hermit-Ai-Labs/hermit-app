import Foundation
import CryptoKit

/// An Intel TDX quote (version 4), read from its bytes. Layout from Intel's "TDX DCAP Quoting Library API" spec:
/// 48-byte header, 584-byte TD report body, then the ECDSA signature data (attestation key signature, the
/// Quoting Enclave's report and its signature, and the PCK certificate chain).
public struct TDXQuote: Sendable {
    public let raw: Data
    public let version: UInt16
    public let teeType: UInt32
    public let tdAttributes: Data
    public let mrTD: Data
    public let mrConfigID: Data
    /// RTMR0 to RTMR3.
    public let rtmr: [Data]
    public let reportData: Data

    // Signature data
    let quoteSignature: Data      // r || s over header + body
    let attestationKey: Data      // x || y, P-256
    let qeReport: Data            // 384-byte SGX report of the Quoting Enclave
    let qeReportSignature: Data   // r || s, by the PCK key
    let qeAuthData: Data
    let pckChainPEM: Data

    public enum Failure: Error, CustomStringConvertible {
        case malformed(String)
        public var description: String { switch self { case .malformed(let s): "Malformed quote: \(s)" } }
    }

    static let headerSize = 48, bodySize = 584

    public init(_ raw: Data) throws {
        let b = [UInt8](raw)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func slice(_ o: Int, _ n: Int) throws -> Data {
            guard o >= 0, n >= 0, o + n <= b.count else { throw Failure.malformed("field at \(o) runs past the end") }
            return Data(b[o..<(o + n)])
        }
        guard b.count > Self.headerSize + Self.bodySize + 4 else { throw Failure.malformed("too short (\(b.count) bytes)") }
        self.raw = raw
        version = u16(0)
        teeType = u32(4)
        let body = Self.headerSize
        tdAttributes = try slice(body + 120, 8)
        mrTD = try slice(body + 136, 48)
        mrConfigID = try slice(body + 184, 48)
        rtmr = try (0..<4).map { try slice(body + 328 + 48 * $0, 48) }
        reportData = try slice(body + 520, 64)

        var o = Self.headerSize + Self.bodySize + 4   // after the signature-data length
        quoteSignature = try slice(o, 64); o += 64
        attestationKey = try slice(o, 64); o += 64
        guard o + 6 <= b.count, u16(o) == 6 else { throw Failure.malformed("expected QE report certification data (type 6)") }
        o += 6
        qeReport = try slice(o, 384); o += 384
        qeReportSignature = try slice(o, 64); o += 64
        guard o + 2 <= b.count else { throw Failure.malformed("QE auth data") }
        let authLen = Int(u16(o)); o += 2
        qeAuthData = try slice(o, authLen); o += authLen
        guard o + 6 <= b.count, u16(o) == 5 else { throw Failure.malformed("expected PCK certificate chain (type 5)") }
        let chainLen = Int(u32(o + 2)); o += 6
        pckChainPEM = try slice(o, chainLen)
    }

    public var isTDXv4: Bool { version == 4 && teeType == 0x81 }
    /// Bit 0 of TD_ATTRIBUTES: the TD was launched in debug mode, so its memory is readable by the host.
    public var debug: Bool { tdAttributes.first.map { $0 & 1 == 1 } ?? true }

    /// The parts of Intel's DCAP signature chain this phone checks itself.
    public struct ChainResult: Sendable {
        public var quoteSigned = false        // attestation key signed header + TD report
        public var keyBoundToQE = false       // QE report data = SHA-256(attestation key || QE auth data)
        public var qeSignedByPCK = false      // PCK certificate's key signed the QE report
        public var chainToIntelRoot = false   // PCK -> Platform/Processor CA -> Intel SGX Root CA, root byte-identical
        public var certificatesInDate = false
        public var pckName = ""
        public var error: String?
        public var allPassed: Bool { quoteSigned && keyBoundToQE && qeSignedByPCK && chainToIntelRoot && certificatesInDate }
    }

    public func verifyChain(at date: Date = Date()) -> ChainResult {
        var r = ChainResult()
        do {
            let key = try P256.Signing.PublicKey(rawRepresentation: attestationKey)
            let sig = try P256.Signing.ECDSASignature(rawRepresentation: quoteSignature)
            r.quoteSigned = key.isValidSignature(sig, for: raw.prefix(Self.headerSize + Self.bodySize))
            // SGX report body: report data sits at offset 320 (64 bytes); the first 32 bind the attestation key.
            r.keyBoundToQE = qeReport.subdata(in: 320..<352) == Data(SHA256.hash(data: attestationKey + qeAuthData))
            let certs = try X509Lite.pemCertificates(pckChainPEM).map { try X509Lite(der: $0) }
            guard certs.count >= 2, let leaf = certs.first, let root = certs.last else { r.error = "PCK chain has \(certs.count) certificates"; return r }
            r.pckName = leaf.commonName
            let qeSig = try P256.Signing.ECDSASignature(rawRepresentation: qeReportSignature)
            r.qeSignedByPCK = leaf.publicKey.isValidSignature(qeSig, for: qeReport)
            let linked = zip(certs, certs.dropFirst()).allSatisfy { $0.isSigned(by: $1) }
            r.chainToIntelRoot = linked && root.der == IntelRoot.der && root.isSigned(by: root)
            r.certificatesInDate = certs.allSatisfy { $0.isValid(at: date) }
        } catch {
            r.error = "\(error)"
        }
        return r
    }
}

extension Data {
    init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let byte = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(byte); i = j
        }
        self = out
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
