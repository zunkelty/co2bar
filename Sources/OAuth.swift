import AppKit
import CryptoKit
import Foundation
import Network

struct Tokens: Codable {
    var clientID: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

struct OAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum OAuth {
    static func signIn(board: Board) async throws -> Tokens {
        let clientID = try await registeredClientID(board: board)
        let verifier = randomURLSafeString(byteCount: 48)
        let state = randomURLSafeString(byteCount: 16)

        var components = URLComponents(url: board.authServer.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "scope", value: Config.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: board.mcpEndpoint.absoluteString),
        ]

        let authorizeURL = components.url!
        let receiver = try CallbackReceiver(port: Config.callbackPort)
        await MainActor.run { _ = NSWorkspace.shared.open(authorizeURL) }
        let params = try await receiver.waitForCallback(timeout: 300)

        guard params["state"] == state else { throw OAuthError(message: "Sign-in state mismatch") }
        if let error = params["error"] {
            throw OAuthError(message: "Sign-in failed: \(params["error_description"] ?? error)")
        }
        guard let code = params["code"] else { throw OAuthError(message: "Sign-in returned no code") }

        return try await requestTokens(board: board, clientID: clientID, previousRefreshToken: nil, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.redirectURI,
            "code_verifier": verifier,
        ])
    }

    static func refresh(_ tokens: Tokens, board: Board) async throws -> Tokens {
        guard let refreshToken = tokens.refreshToken else { throw OAuthError(message: "No refresh token") }
        return try await requestTokens(board: board, clientID: tokens.clientID, previousRefreshToken: refreshToken, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
    }

    private static func registeredClientID(board: Board) async throws -> String {
        let clientIDKey = "oauthClientID.\(board.host)"
        if let existing = UserDefaults.standard.string(forKey: clientIDKey) { return existing }
        let body: [String: Any] = [
            "client_name": "CO2 Bar",
            "redirect_uris": [Config.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": Config.scope,
        ]
        var request = URLRequest(url: board.authServer.appendingPathComponent("oauth/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await sendForJSON(request)
        guard let clientID = json["client_id"] as? String else { throw OAuthError(message: "Client registration returned no client_id") }
        UserDefaults.standard.set(clientID, forKey: clientIDKey)
        return clientID
    }

    private static func requestTokens(board: Board, clientID: String, previousRefreshToken: String?, form: [String: String]) async throws -> Tokens {
        var fields = form
        fields["client_id"] = clientID
        fields["resource"] = board.mcpEndpoint.absoluteString

        var request = URLRequest(url: board.authServer.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(fields).data(using: .utf8)

        let json = try await sendForJSON(request)
        guard let accessToken = json["access_token"] as? String else { throw OAuthError(message: "Token response had no access_token") }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return Tokens(
            clientID: clientID,
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? previousRefreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private static func sendForJSON(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OAuthError(message: "HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError(message: "Unexpected response from \(request.url?.path ?? "")")
        }
        return json
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// All mutable state is touched only on `queue`.
final class CallbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "co2bar.oauth-callback")
    private var continuation: CheckedContinuation<[String: String], Error>?

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.listener.stateUpdateHandler = { state in
                    if case .failed(let error) = state { self.finish(.failure(error)) }
                }
                self.listener.newConnectionHandler = { connection in self.handle(connection) }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(OAuthError(message: "Sign-in timed out")))
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard target.hasPrefix("/callback"), let components = URLComponents(string: "http://127.0.0.1" + target) else {
                Self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var params: [String: String] = [:]
            for item in components.queryItems ?? [] { params[item.name] = item.value }
            let succeeded = params["code"] != nil
            Self.respond(connection, status: "200 OK", body: succeeded
                ? "Signed in to Honeycomb. You can close this tab."
                : "Sign-in failed. You can close this tab and try again from the menu bar.")
            self.finish(.success(params))
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        continuation.resume(with: result)
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>CO2 Bar</title><body style=\"font:16px -apple-system;padding:3em\">\(body)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
