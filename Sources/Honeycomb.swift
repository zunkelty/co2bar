import Foundation

struct Reading {
    let ppm: Int
    let time: Date
}

struct CO2Snapshot {
    let latest: Reading
    let readingPeriod: TimeInterval?
}

enum HoneycombError: LocalizedError {
    case signedOut
    case noRecentReading
    case noCO2Query

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Not signed in to Honeycomb"
        case .noRecentReading: return "No reading in the last 10 minutes"
        case .noCO2Query: return "No CO₂ query found on this board"
        }
    }
}

final class Honeycomb {
    private static let tokensAccount = "honeycomb-mcp"

    private(set) var board: Board
    private let mcp: MCPClient

    init(board: Board) {
        self.board = board
        mcp = MCPClient(endpoint: board.mcpEndpoint)
    }

    var isSignedIn: Bool { Keychain.load(Tokens.self, account: Self.tokensAccount) != nil }

    func signIn() async throws {
        Keychain.save(try await OAuth.signIn(board: board), account: Self.tokensAccount)
        mcp.reset()
    }

    func signOut() {
        Self.forgetTokens()
        mcp.reset()
    }

    static func forgetTokens() {
        Keychain.delete(account: tokensAccount)
    }

    func latestCO2() async throws -> CO2Snapshot {
        let (dataset, column) = try await co2Source()
        let text = try await callTool("run_query", [
            "environment_slug": board.environment,
            "dataset_slug": dataset,
            "query_spec": ["from": "-10m"],
            "raw_row_columns": [column],
            "results_limit": 30,
        ])
        let readings = Self.readings(inRawRows: text)
        guard let latest = readings.last else { throw HoneycombError.noRecentReading }
        return CO2Snapshot(latest: latest, readingPeriod: Self.typicalGap(between: readings))
    }

    private func co2Source() async throws -> (dataset: String, column: String) {
        if let dataset = board.dataset, let column = board.co2Column { return (dataset, column) }
        let boardText = try await callTool("list_boards", [
            "environment_slug": board.environment,
            "board_id": board.boardID,
        ])
        for queryID in Self.co2QueryIDs(inBoard: boardText) {
            guard let result = try? await callTool("get_query_results", [
                "query_id": queryID,
                "environment_slug": board.environment,
                "include_markers": false,
            ]), let source = Self.co2Source(inQueryResult: result) else { continue }
            board.dataset = source.dataset
            board.co2Column = source.column
            board.save()
            return source
        }
        throw HoneycombError.noCO2Query
    }

    private func callTool(_ name: String, _ arguments: [String: Any]) async throws -> String {
        guard var tokens = Keychain.load(Tokens.self, account: Self.tokensAccount) else { throw HoneycombError.signedOut }
        if tokens.expiresAt < Date().addingTimeInterval(60) {
            tokens = try await refreshed(tokens)
        }
        do {
            return try await mcp.callTool(name, arguments: arguments, accessToken: tokens.accessToken)
        } catch MCPError.unauthorized {
            return try await mcp.callTool(name, arguments: arguments, accessToken: try await refreshed(tokens).accessToken)
        }
    }

    private func refreshed(_ tokens: Tokens) async throws -> Tokens {
        do {
            let fresh = try await OAuth.refresh(tokens, board: board)
            Keychain.save(fresh, account: Self.tokensAccount)
            return fresh
        } catch is OAuthError {
            signOut()
            throw HoneycombError.signedOut
        }
    }
}

extension Honeycomb {
    static func co2QueryIDs(inBoard markdown: String) -> [String] {
        let queriesTable = markdown.components(separatedBy: "\n\n").first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Queries:") } ?? ""
        return tableRows(queriesTable).dropFirst().compactMap { cells in
            guard cells.count >= 2, mentionsCO2(cells[1]) else { return nil }
            return cells[0]
        }
    }

    static func co2Source(inQueryResult markdown: String) -> (dataset: String, column: String)? {
        guard let dataset = metadataValue("dataset", in: markdown),
              let specJSON = markdown.components(separatedBy: "```json").dropFirst().last?.components(separatedBy: "```").first,
              let spec = try? JSONSerialization.jsonObject(with: Data(specJSON.utf8)) as? [String: Any],
              let column = columns(in: spec).first(where: mentionsCO2) else { return nil }
        return (dataset, column)
    }

    // Raw rows come back as `| <column> | timestamp |` in no particular order.
    static func readings(inRawRows markdown: String) -> [Reading] {
        tableRows(markdown).compactMap { cells -> Reading? in
            guard cells.count == 2, let ppm = Double(cells[0]), let time = parseTimestamp(cells[1]) else { return nil }
            return Reading(ppm: Int(ppm.rounded()), time: time)
        }.sorted { $0.time < $1.time }
    }

    static func typicalGap(between readings: [Reading]) -> TimeInterval? {
        let gaps = zip(readings, readings.dropFirst())
            .map { $1.time.timeIntervalSince($0.time) }
            .filter { $0 > 0 }
            .sorted()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    private static func columns(in spec: [String: Any]) -> [String] {
        let calculatedFields = (spec["calculated_fields"] as? [[String: Any]]) ?? []
        let derivedNames = Set(calculatedFields.compactMap { $0["name"] as? String })
        let calculated = ((spec["calculations"] as? [[String: Any]]) ?? []).compactMap { $0["column"] as? String }
        let referenced = calculatedFields.compactMap { $0["expression"] as? String }.flatMap { expression in
            expression.matches(of: #/\$([A-Za-z0-9_.\-]+)/#).map { String($0.output.1) }
        }
        return (calculated + referenced).filter { !derivedNames.contains($0) }
    }

    private static func mentionsCO2(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("co2") || lowered.contains("co₂")
    }

    private static func metadataValue(_ key: String, in markdown: String) -> String? {
        markdown.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("\(key): ") }
            .map { String($0.dropFirst(key.count + 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
    }

    private static func tableRows(_ markdown: String) -> [[String]] {
        markdown.split(separator: "\n")
            .filter { $0.hasPrefix("|") && !$0.hasPrefix("| ---") }
            .map { line in
                line.split(separator: "|", omittingEmptySubsequences: false)
                    .dropFirst().dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter = ISO8601DateFormatter()

    private static func parseTimestamp(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
    }
}
