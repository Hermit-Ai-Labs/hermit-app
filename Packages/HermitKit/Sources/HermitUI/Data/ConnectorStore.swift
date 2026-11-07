import SwiftUI
import Observation
import HermitCore

/// What's connected on this phone: Binance (API key in the Keychain) and remote MCP servers (URL here, token in the
/// Keychain). Tools from MCP servers are cached after the first listing.
@MainActor @Observable
final class ConnectorStore {
    static let shared = ConnectorStore()

    struct MCPServer: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var url: String
        var hasToken: Bool
        var tokenKey: String { "mcp.\(id.uuidString)" }
    }

    private(set) var servers: [MCPServer] = LocalJSON.load("mcp-servers.json", as: [MCPServer].self) ?? []
    var tools: [UUID: [MCPTool]] = [:]
    private(set) var binanceConnected = Binance.saved != nil
    var binanceAccount: Binance.Account?
    var binanceError: String?

    // MARK: Binance

    func connectBinance(key: String, secret: String) async throws {
        let b = Binance(key: key.trimmingCharacters(in: .whitespacesAndNewlines), secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
        let acct = try await b.account()   // proves the key works before saving it
        b.save()
        binanceAccount = acct; binanceConnected = true; binanceError = nil
    }

    func disconnectBinance() {
        Binance.save(key: nil, secret: nil)
        binanceConnected = false; binanceAccount = nil
    }

    func refreshBinance() async {
        guard let b = Binance.saved else { return }
        do { binanceAccount = try await b.account(); binanceError = nil }
        catch { binanceError = error.localizedDescription }
    }

    // MARK: MCP

    func client(_ s: MCPServer) -> MCPClient? {
        URL(string: s.url).map { MCPClient(url: $0, token: s.hasToken ? Secrets.get(s.tokenKey) : nil) }
    }

    /// Connects once to check the server and read its name and tools, then saves it.
    func addServer(url: String, token: String) async throws -> MCPServer {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme == "https" else {
            throw MCPError.server("Enter the server's https:// address.")
        }
        let c = MCPClient(url: u, token: token)
        let info = try await c.connect()
        let list = try await c.tools()
        var s = MCPServer(name: info.name, url: u.absoluteString, hasToken: !token.isEmpty)
        if servers.contains(where: { $0.url == s.url }) { s.id = servers.first { $0.url == s.url }!.id; servers.removeAll { $0.url == s.url } }
        Secrets.set(token.isEmpty ? nil : token, for: s.tokenKey)
        servers.append(s); tools[s.id] = list
        save()
        return s
    }

    func removeServer(_ s: MCPServer) {
        Secrets.set(nil, for: s.tokenKey)
        servers.removeAll { $0.id == s.id }; tools[s.id] = nil
        save()
    }

    func loadTools(_ s: MCPServer) async throws {
        guard let c = client(s) else { return }
        tools[s.id] = try await c.tools()
    }

    private func save() { LocalJSON.save(servers, "mcp-servers.json") }
}
