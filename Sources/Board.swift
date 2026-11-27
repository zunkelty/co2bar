import Foundation

struct Board: Codable, Equatable {
    let url: URL
    let host: String
    let environment: String
    let boardID: String
    var dataset: String?
    var co2Column: String?

    var authServer: URL { URL(string: "https://\(host)")! }
    var mcpEndpoint: URL { URL(string: "https://mcp.\(host.dropFirst("ui.".count))/mcp")! }

    static func parse(_ text: String) -> Board? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https",
              let host = url.host, host.hasPrefix("ui."), host.hasSuffix("honeycomb.io") else { return nil }
        let path = url.pathComponents
        guard let environmentIndex = path.firstIndex(of: "environments"), environmentIndex + 1 < path.count,
              let boardIndex = path.firstIndex(of: "board"), boardIndex + 1 < path.count else { return nil }
        return Board(url: url, host: host, environment: path[environmentIndex + 1], boardID: path[boardIndex + 1])
    }

    static func load() -> Board? {
        Keychain.load(Board.self, account: "board")
    }

    func save() {
        Keychain.save(self, account: "board")
    }
}
