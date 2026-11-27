import Foundation

enum Config {
    static let bundleID = "com.github.zunkelty.co2bar"
    static let scope = "mcp:read"

    static let callbackPort: UInt16 = 53682
    static var redirectURI: String { "http://127.0.0.1:\(callbackPort)/callback" }

    static let pollInterval: TimeInterval = 60
    static let staleAfter: TimeInterval = 5 * 60

    static let fairFrom = 750
    static let poorAbove = 1000
}
