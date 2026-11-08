import Foundation
import CryptoKit

/// Just enough DER and X.509 to check Intel's PCK certificate chain on the phone: each certificate's ECDSA P-256
/// signature over its TBS bytes, issuer and subject names that chain, validity dates, and the root equal to Intel's.
enum DER {
    struct Node {
        let tag: UInt8
        /// The whole element, header included.
        let raw: Data
        /// Just the contents.
        let body: Data
    }

    enum Failure: Error { case malformed(String) }

    /// Reads one element at `offset`.
    static func read(_ d: Data, at offset: Int) throws -> Node {
        let b = [UInt8](d)
        guard offset + 2 <= b.count else { throw Failure.malformed("short element") }
        let tag = b[offset]
        var i = offset + 1
        var len = Int(b[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, i + n <= b.count else { throw Failure.malformed("bad length") }
            len = 0
            for _ in 0..<n { len = len << 8 | Int(b[i]); i += 1 }
        }
        guard i + len <= b.count else { throw Failure.malformed("element runs past the end") }
        let start = d.startIndex
        return Node(tag: tag, raw: d.subdata(in: (start + offset)..<(start + i + len)), body: d.subdata(in: (start + i)..<(start + i + len)))
    }

    /// The children of a constructed element, in order.
    static func children(_ body: Data) throws -> [Node] {
        var out: [Node] = [], at = 0
        while at < body.count {
            let n = try read(body, at: at)
            out.append(n); at += n.raw.count
        }
        return out
    }
}

struct X509Lite {
    let der: Data
    let tbs: Data
    let signature: Data       // DER ECDSA signature
    let issuer: Data
    let subject: Data
    let notBefore: Date
    let notAfter: Date
    let publicKey: P256.Signing.PublicKey
    let commonName: String

    init(der: Data) throws {
        self.der = der
        let cert = try DER.read(der, at: 0)
        let top = try DER.children(cert.body)
        guard top.count == 3, top[2].tag == 0x03 else { throw DER.Failure.malformed("certificate") }
        tbs = top[0].raw
        signature = top[2].body.dropFirst()   // BIT STRING: first byte is the unused-bit count (0)
        var f = try DER.children(top[0].body)
        if f.first?.tag == 0xA0 { f.removeFirst() }   // [0] version
        // serial, signature algorithm, issuer, validity, subject, subjectPublicKeyInfo
        guard f.count >= 6 else { throw DER.Failure.malformed("tbsCertificate") }
        issuer = f[2].raw
        subject = f[4].raw
        let validity = try DER.children(f[3].body)
        guard validity.count == 2 else { throw DER.Failure.malformed("validity") }
        notBefore = try Self.time(validity[0])
        notAfter = try Self.time(validity[1])
        let spki = try DER.children(f[5].body)
        guard spki.count == 2, spki[1].tag == 0x03 else { throw DER.Failure.malformed("public key") }
        publicKey = try P256.Signing.PublicKey(x963Representation: spki[1].body.dropFirst())
        commonName = Self.commonName(f[4].body)
    }

    /// True when `issuerCert` signed this certificate and the names chain.
    func isSigned(by issuerCert: X509Lite) -> Bool {
        guard issuer == issuerCert.subject, let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return issuerCert.publicKey.isValidSignature(sig, for: tbs)
    }

    func isValid(at date: Date) -> Bool { notBefore <= date && date <= notAfter }

    private static func time(_ n: DER.Node) throws -> Date {
        guard let s = String(data: n.body, encoding: .ascii) else { throw DER.Failure.malformed("time") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = n.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        guard let d = f.date(from: s) else { throw DER.Failure.malformed("time \(s)") }
        return d
    }

    /// CN (2.5.4.3) from a Name, for display.
    private static func commonName(_ name: Data) -> String {
        let cnOID = Data([0x06, 0x03, 0x55, 0x04, 0x03])
        guard let sets = try? DER.children(name) else { return "" }
        for set in sets {
            for atv in (try? DER.children(set.body)) ?? [] {
                let parts = (try? DER.children(atv.body)) ?? []
                if parts.count == 2, parts[0].raw == cnOID { return String(data: parts[1].body, encoding: .utf8) ?? "" }
            }
        }
        return ""
    }

    /// Splits a PEM bundle into DER certificates.
    static func pemCertificates(_ pem: Data) -> [Data] {
        let text = String(decoding: pem, as: UTF8.self)
        var out: [Data] = []
        for part in text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst() {
            guard let end = part.range(of: "-----END CERTIFICATE-----") else { continue }
            let b64 = part[..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
            if let d = Data(base64Encoded: b64) { out.append(d) }
        }
        return out
    }
}

/// Intel SGX Provisioning Certification Root CA, from certificates.trustedservices.intel.com
/// (Intel_SGX_Provisioning_Certification_RootCA.cer). Every TDX quote's PCK chain must end here.
enum IntelRoot {
    static let der = Data(base64Encoded: """
    MIICjzCCAjSgAwIBAgIUImUM1lqdNInzg7SVUr9QGzknBqwwCgYIKoZIzj0EAwIwaDEaMBgGA1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENvcnBvcmF0aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJBgNVBAYTAlVTMB4XDTE4MDUyMTEwNDUxMFoXDTQ5MTIzMTIzNTk1OVowaDEaMBgGA1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENvcnBvcmF0aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJBgNVBAYTAlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEC6nEwMDIYZOj/iPWsCzaEKi71OiOSLRFhWGjbnBVJfVnkY4u3IjkDYYL0MxO4mqsyYjlBalTVYxFP2sJBK5zlKOBuzCBuDAfBgNVHSMEGDAWgBQiZQzWWp00ifODtJVSv1AbOScGrDBSBgNVHR8ESzBJMEegRaBDhkFodHRwczovL2NlcnRpZmljYXRlcy50cnVzdGVkc2VydmljZXMuaW50ZWwuY29tL0ludGVsU0dYUm9vdENBLmRlcjAdBgNVHQ4EFgQUImUM1lqdNInzg7SVUr9QGzknBqwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQEwCgYIKoZIzj0EAwIDSQAwRgIhAOW/5QkR+S9CiSDcNoowLuPRLsWGf/Yi7GSX94BgwTwgAiEA4J0lrHoMs+Xo5o/sX6O9QWxHRAvZUGOdRQ7cvqRXaqI=
    """.components(separatedBy: .whitespacesAndNewlines).joined())!
}
