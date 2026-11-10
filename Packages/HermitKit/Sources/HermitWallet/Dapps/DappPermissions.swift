import Foundation
import Observation

/// A page's origin as WebKit reports it (scheme, host, port). Every web-app request is bound to one.
public struct DappOrigin: Hashable, Sendable, Codable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int?

    public init(scheme: String, host: String, port: Int?) {
        self.scheme = scheme.lowercased(); self.host = host.lowercased()
        let def = self.scheme == "https" ? 443 : self.scheme == "http" ? 80 : nil
        self.port = port == 0 || port == def ? nil : port
    }
    public init?(url: URL) {
        guard let s = url.scheme, let h = url.host(), !h.isEmpty else { return nil }
        self.init(scheme: s, host: h, port: url.port)
    }
    /// "https://app.uniswap.org", with the port when it isn't the default.
    public var description: String { "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "") }
    public var isSecure: Bool { scheme == "https" }
}

/// Sites the user connected a wallet to: which wallet, which network, when. Kept on this device only (UserDefaults).
/// Settings lists them with Disconnect; a disconnected site sees no accounts until the user connects it again.
@MainActor @Observable
public final class DappPermissions {
    public static let shared = DappPermissions()
    public static let disconnected = Notification.Name("hermit.dapps.disconnected")

    public struct Site: Codable, Identifiable, Hashable, Sendable {
        public var id: String { origin }
        public let origin: String
        public var walletID: UUID
        public var address: String
        public var chainID: UInt64
        public let connected: Date
        public var lastUsed: Date
    }

    public private(set) var sites: [Site] = []
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let key = "hermit.dapps.sites"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sites = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Site].self, from: $0) }) ?? []
    }

    public func site(_ origin: DappOrigin) -> Site? { sites.first { $0.origin == origin.description } }

    public func connect(_ origin: DappOrigin, walletID: UUID, address: String, chainID: UInt64) {
        let now = Date()
        if let i = sites.firstIndex(where: { $0.origin == origin.description }) {
            sites[i].walletID = walletID; sites[i].address = address; sites[i].chainID = chainID; sites[i].lastUsed = now
        } else {
            sites.insert(Site(origin: origin.description, walletID: walletID, address: address, chainID: chainID, connected: now, lastUsed: now), at: 0)
        }
        save()
    }

    public func setChain(_ origin: DappOrigin, chainID: UInt64) {
        guard let i = sites.firstIndex(where: { $0.origin == origin.description }) else { return }
        sites[i].chainID = chainID; save()
    }

    public func touch(_ origin: DappOrigin) {
        guard let i = sites.firstIndex(where: { $0.origin == origin.description }) else { return }
        sites[i].lastUsed = Date(); save()
    }

    public func disconnect(_ origin: String) {
        sites.removeAll { $0.origin == origin }
        save()
        NotificationCenter.default.post(name: Self.disconnected, object: origin)
    }

    public func disconnectAll() { for s in sites { disconnect(s.origin) } }

    private func save() { defaults.set(try? JSONEncoder().encode(sites), forKey: key) }
}
