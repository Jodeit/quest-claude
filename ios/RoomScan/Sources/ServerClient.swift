import Foundation

/// Talks to a roomscan server (spatial/ in quest-claude): POST /scans, PUT /scans/<id>, GET /scans.
struct ServerClient {
    let base: URL
    let token: String

    /// Nil until both an http(s) address and a token are set. Takes the address with or without a
    /// trailing /mcp, since that's the URL the server prints.
    init?(urlString: String, token: String) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/mcp") { s.removeLast(4) }
        guard !token.isEmpty, let url = URL(string: s), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()), url.host != nil else { return nil }
        base = url
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        case badReply

        var errorDescription: String? {
            switch self {
            case .http(401, _): return "The server refused the token."
            case let .http(code, message): return "Server said \(code): \(message)"
            case .badReply: return "The server's reply didn't make sense."
            }
        }
    }

    private func request(_ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw Failure.http(code, json["error"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return json
    }

    /// How many scans the server holds. Needs the token, so it checks both address and token.
    func scanCount() async throws -> Int {
        let json = try await send(request("scans", method: "GET"))
        guard let scans = json["scans"] as? [Any] else { throw Failure.badReply }
        return scans.count
    }

    /// Store a new scan; returns its id on the server.
    func create(_ capture: Data, name: String, live: Bool) async throws -> String {
        var q = [URLQueryItem(name: "name", value: name)]
        if live { q.append(URLQueryItem(name: "stage", value: "live")) }
        let json = try await send(request("scans", method: "POST", query: q, body: capture))
        guard let id = json["scan_id"] as? String else { throw Failure.badReply }
        return id
    }

    /// Replace a scan's capture with a newer one of the same room.
    func update(_ scanID: String, _ capture: Data, live: Bool) async throws {
        let q = live ? [URLQueryItem(name: "stage", value: "live")] : []
        _ = try await send(request("scans/\(scanID)", method: "PUT", query: q, body: capture))
    }
}
