import Foundation

/// A remote MCP server over Streamable HTTP (modelcontextprotocol.io, transport 2025-06-18): JSON-RPC posted to one URL,
/// answered as JSON or as a short server-sent-events stream. Enough for initialize, tools/list and tools/call.
public struct MCPTool: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String?
    /// Top-level properties of the input schema: name → (type, description), and which are required.
    public let params: [Param]
    public struct Param: Codable, Hashable, Sendable {
        public let name: String, type: String, description: String?, required: Bool
    }
}

public actor MCPClient {
    public let url: URL
    private let token: String?
    private var session: String?
    private var nextID = 1
    private var ready = false

    public init(url: URL, token: String?) { self.url = url; self.token = token?.isEmpty == true ? nil : token }

    public struct Info: Sendable { public let name: String; public let version: String }

    @discardableResult
    public func connect() async throws -> Info {
        let r = try await request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Hermit", "version": "1.0"],
        ])
        try await notify("notifications/initialized")
        ready = true
        let si = r["serverInfo"] as? [String: Any]
        return Info(name: si?["name"] as? String ?? url.host() ?? "MCP server", version: si?["version"] as? String ?? "")
    }

    public func tools() async throws -> [MCPTool] {
        if !ready { try await connect() }
        var out: [MCPTool] = [], cursor: String?
        repeat {
            let r = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            for t in (r["tools"] as? [[String: Any]]) ?? [] {
                guard let name = t["name"] as? String else { continue }
                let schema = t["inputSchema"] as? [String: Any]
                let props = schema?["properties"] as? [String: [String: Any]] ?? [:]
                let req = Set(schema?["required"] as? [String] ?? [])
                let params = props.keys.sorted { (req.contains($0) ? 0 : 1, $0) < (req.contains($1) ? 0 : 1, $1) }.map { k in
                    MCPTool.Param(name: k, type: props[k]?["type"] as? String ?? "string", description: props[k]?["description"] as? String,
                                  required: req.contains(k))
                }
                out.append(MCPTool(name: name, description: t["description"] as? String, params: params))
            }
            cursor = r["nextCursor"] as? String
        } while cursor != nil && out.count < 500
        return out
    }

    /// Runs a tool and returns its text content (images and resources are summarised).
    public func call(_ tool: String, arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        if !ready { try await connect() }
        let r = try await request("tools/call", ["name": tool, "arguments": arguments])
        let parts = (r["content"] as? [[String: Any]] ?? []).map { c -> String in
            switch c["type"] as? String {
            case "text": return c["text"] as? String ?? ""
            case "image": return "[image]"
            case "resource", "resource_link": return "[resource \((c["resource"] as? [String: Any])?["uri"] as? String ?? c["uri"] as? String ?? "")]"
            default: return ""
            }
        }
        var text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        if text.isEmpty, let s = r["structuredContent"],
           let d = try? JSONSerialization.safeData(withJSONObject: s, options: [.prettyPrinted]) { text = String(decoding: d, as: UTF8.self) }
        return (text, r["isError"] as? Bool ?? false)
    }

    // MARK: Transport

    private func notify(_ method: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method])
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        guard let reply = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
            throw MCPError.server("No reply to \(method)")
        }
        if let e = reply["error"] as? [String: Any] { throw MCPError.server(e["message"] as? String ?? "Error \(e["code"] ?? "")") }
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any]? {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.safeData(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.server("No response") }
        if let s = http.value(forHTTPHeaderField: "Mcp-Session-Id") { session = s }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw MCPError.unauthorized
        case 404 where session != nil: session = nil; ready = false; throw MCPError.server("The server ended the session. Try again.")
        default: throw MCPError.server("HTTP \(http.statusCode): \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
        if data.isEmpty { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            // The reply is the last JSON-RPC message carrying an id in the stream's data lines.
            var found: [String: Any]?
            for event in String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n") {
                let payload = event.split(separator: "\n").filter { $0.hasPrefix("data:") }
                    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined()
                if let d = payload.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["id"] != nil {
                    found = o
                }
            }
            return found
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public enum MCPError: Error, LocalizedError, Sendable {
    case unauthorized, server(String)
    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The server wants a sign-in. Add an access token for it."
        case .server(let m): m
        }
    }
}
