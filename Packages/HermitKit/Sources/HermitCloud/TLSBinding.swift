import Foundation
import CryptoKit
import Security

/// One HTTPS connection to cloud-api.near.ai, watched: the SHA-256 of the server certificate's SubjectPublicKeyInfo at
/// every TLS handshake, and which TCP connection each request used (URLSessionTaskMetrics). The attestation report is
/// fetched with `include_tls_fingerprint=true` on this session, and the prompt is sent on it too, so the phone can check
/// that the connection it sends on ends at the key the gateway's quote binds (docs: cloud-api/tls).
public final class GatewayConnection: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public struct Use: Sendable, Equatable { public let connection: String; public let reused: Bool }

    private let lock = NSLock()
    private var _handshakes: [String] = []
    public private(set) lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 1
        c.urlCache = nil
        c.httpCookieStorage = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// SPKI hashes (hex) seen at each TLS handshake on this session, in order.
    public var handshakes: [String] { lock.withLock { _handshakes } }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
           let spki = try? X509Lite.spki(SecCertificateCopyData(leaf) as Data) {
            let h = Data(SHA256.hash(data: spki)).hex
            lock.withLock { _handshakes.append(h) }
        }
        // Normal certificate validation still applies; this only records what was presented.
        completionHandler(.performDefaultHandling, nil)
    }

    /// Runs a request and returns its body and the TCP connection it used (metrics can trail the response briefly).
    func data(for req: URLRequest) async throws -> (Data, URLResponse, Use?) {
        let probe = MetricsProbe()
        let (data, resp) = try await session.data(for: req, delegate: probe)
        var u = probe.use
        for _ in 0..<10 where u == nil { try? await Task.sleep(for: .milliseconds(20)); u = probe.use }
        return (data, resp, u)
    }

    public func invalidate() { session.finishTasksAndInvalidate() }
}

/// Per-request delegate: records which connection the request went over. Challenges fall through to the session.
private final class MetricsProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _use: GatewayConnection.Use?
    var use: GatewayConnection.Use? { lock.withLock { _use } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let t = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }) else { return }
        let key = "\(t.localAddress ?? "?"):\(t.localPort.map(String.init) ?? "?")>\(t.remoteAddress ?? "?"):\(t.remotePort.map(String.init) ?? "?")"
        lock.withLock { _use = GatewayConnection.Use(connection: key, reused: t.isReusedConnection) }
    }
}

extension X509Lite {
    /// The DER SubjectPublicKeyInfo of a certificate, whatever its key type.
    static func spki(_ der: Data) throws -> Data {
        let cert = try DER.read(der, at: 0)
        let top = try DER.children(cert.body)
        guard let tbs = top.first else { throw DER.Failure.malformed("certificate") }
        var f = try DER.children(tbs.body)
        if f.first?.tag == 0xA0 { f.removeFirst() }
        guard f.count >= 6 else { throw DER.Failure.malformed("tbsCertificate") }
        return f[5].raw
    }
}
