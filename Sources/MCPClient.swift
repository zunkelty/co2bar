import Foundation

enum MCPError: LocalizedError {
    case unauthorized
    case sessionExpired
    case http(Int, String)
    case rpc(String)
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Not authorized"
        case .sessionExpired: return "MCP session expired"
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(200))"
        case .rpc(let message): return "MCP error: \(message)"
        case .tool(let message): return "Query failed: \(message.prefix(200))"
        }
    }
}

final class MCPClient {
    private static let protocolVersion = "2025-06-18"
    private let endpoint: URL
    private var sessionID: String?
    private var nextRequestID = 1

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    func callTool(_ name: String, arguments: [String: Any], accessToken: String) async throws -> String {
        do {
            return try await callToolInSession(name, arguments: arguments, accessToken: accessToken)
        } catch MCPError.sessionExpired {
            sessionID = nil
            return try await callToolInSession(name, arguments: arguments, accessToken: accessToken)
        }
    }

    func reset() {
        sessionID = nil
    }

    private func callToolInSession(_ name: String, arguments: [String: Any], accessToken: String) async throws -> String {
        if sessionID == nil { try await initialize(accessToken: accessToken) }
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments], accessToken: accessToken)
        let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if result["isError"] as? Bool == true { throw MCPError.tool(text) }
        return text
    }

    private func initialize(accessToken: String) async throws {
        _ = try await request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "co2bar", "version": "1.0"],
        ], accessToken: accessToken)
        try await notify("notifications/initialized", accessToken: accessToken)
    }

    private func request(_ method: String, params: [String: Any], accessToken: String) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        let data = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params], accessToken: accessToken)
        guard let message = try Self.decodeMessage(data) else { throw MCPError.rpc("Empty response to \(method)") }
        if let error = message["error"] as? [String: Any] {
            throw MCPError.rpc((error["message"] as? String) ?? "\(error)")
        }
        return (message["result"] as? [String: Any]) ?? [:]
    }

    private func notify(_ method: String, accessToken: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method], accessToken: accessToken)
    }

    private func post(_ message: [String: Any], accessToken: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        switch http.statusCode {
        case 200..<300:
            if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
            return data
        case 401:
            throw MCPError.unauthorized
        case 404 where sessionID != nil:
            throw MCPError.sessionExpired
        default:
            throw MCPError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func decodeMessage(_ data: Data) throws -> [String: Any]? {
        guard !data.isEmpty, let body = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("{") {
            json = trimmed
        } else {
            let events = trimmed.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
            guard let last = events.last else { return nil }
            json = String(last.dropFirst("data:".count))
        }
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }
}
