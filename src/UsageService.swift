import Foundation
import Security

// MARK: - Datenmodell

struct UsageWindow: Decodable {
    let utilization: Double?   // Prozent 0–100
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try c.decodeIfPresent(Double.self, forKey: .utilization)
        if let s = try c.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = UsageWindow.parseDate(s)
        } else {
            resetsAt = nil
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? iso.date(from: s)
    }
}

struct UsageResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

enum UsageError: LocalizedError {
    case noCredentials
    case tokenExpired
    case http(Int, String)
    case noOrganization

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Keine Zugangsdaten. Melde dich in Claude Code an (claude → /login) oder trag in den Einstellungen deinen claude.ai sessionKey ein."
        case .tokenExpired:
            return "Claude-Code-Token abgelaufen. Starte kurz `claude` im Terminal, dann aktualisiert er sich."
        case .http(401, _), .http(403, _):
            return "Nicht autorisiert – in Claude Code neu einloggen bzw. sessionKey erneuern."
        case .http(429, _):
            return "Rate-Limit erreicht – versuche es gleich noch mal."
        case .http(let code, let body):
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return "HTTP \(code): \(msg)"
            }
            return "HTTP \(code)"
        case .noOrganization:
            return "Keine Organisation auf claude.ai gefunden."
        }
    }
}

// MARK: - Abruf

enum UsageService {

    /// Eigene Session ohne Cookie-Speicher und Disk-Cache: nichts von claude.ai landet dauerhaft auf der Platte.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    /// Quelle 1: OAuth-Token von Claude Code (Keychain oder ~/.claude/.credentials.json)
    /// Quelle 2: claude.ai sessionKey (manuell in den Einstellungen)
    static func fetch(sessionKey: String?) async throws -> UsageResponse {
        let key = sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if let token = try await TokenCache.shared.token() {
                do {
                    return try await fetchOAuth(token: token)
                } catch UsageError.http(401, _) {
                    // Token wurde evtl. von Claude Code erneuert → Cache verwerfen, einmal frisch lesen
                    await TokenCache.shared.invalidate()
                    if let fresh = try await TokenCache.shared.token(), fresh != token {
                        return try await fetchOAuth(token: fresh)
                    }
                    throw UsageError.http(401, "")
                }
            }
        } catch UsageError.tokenExpired where !key.isEmpty {
            // Claude-Code-Token abgelaufen, aber sessionKey vorhanden → Fallback nutzen
        }
        if !key.isEmpty {
            return try await fetchWeb(sessionKey: key)
        }
        throw UsageError.noCredentials
    }

    // MARK: OAuth (Claude Code)

    /// Hält den Token im Speicher, bis er abläuft – statt bei jedem Abruf `security` zu starten.
    actor TokenCache {
        static let shared = TokenCache()
        private var cached: (token: String, expires: Date?)?

        func invalidate() { cached = nil }

        func token() throws -> String? {
            if let c = cached {
                if let exp = c.expires, exp < Date() { cached = nil } else { return c.token }
            }
            guard let (token, expires) = Self.readCredentials() else { return nil }
            if let expires, expires < Date() {
                // Bewusst KEIN eigener Refresh: das würde den Refresh-Token rotieren und Claude Code ausloggen.
                throw UsageError.tokenExpired
            }
            cached = (token, expires)
            return token
        }

        private static func readCredentials() -> (String, Date?)? {
            var json: Data?

            // Keychain über das security-Tool (das gleiche, das Claude Code nutzt → keine ACL-Probleme)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                // Erst lesen, dann warten – sonst kann ein voller Pipe-Puffer blockieren
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { json = data }
            }

            // Fallback: Datei
            if json == nil {
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/.credentials.json")
                json = try? Data(contentsOf: url)
            }

            guard let data = json,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = obj["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String
            else { return nil }
            let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return (token, expires)
        }
    }

    private static func fetchOAuth(token: String) async throws -> UsageResponse {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-code/2.0 ClaudeUsageBar", forHTTPHeaderField: "User-Agent")
        return try await send(req)
    }

    // MARK: claude.ai Web (sessionKey)

    private static func fetchWeb(sessionKey: String) async throws -> UsageResponse {
        func request(_ path: String) -> URLRequest {
            var r = URLRequest(url: URL(string: "https://claude.ai\(path)")!)
            r.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.setValue("Mozilla/5.0 (Macintosh) ClaudeUsageBar", forHTTPHeaderField: "User-Agent")
            return r
        }

        let orgID: String
        if let cached = UserDefaults.standard.string(forKey: "orgID") {
            orgID = cached
        } else {
            let (data, resp) = try await session.data(for: request("/api/organizations"))
            try check(resp, data)
            guard let orgs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let id = (orgs.first(where: { ($0["capabilities"] as? [String])?.contains("chat") ?? false })
                            ?? orgs.first)?["uuid"] as? String
            else { throw UsageError.noOrganization }
            UserDefaults.standard.set(id, forKey: "orgID")
            orgID = id
        }
        return try await send(request("/api/organizations/\(orgID)/usage"))
    }

    // MARK: Helpers

    private static func send(_ req: URLRequest) async throws -> UsageResponse {
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - sessionKey im Schlüsselbund

enum SessionKeyStore {
    private static let service = "de.maxgerbeth.ClaudeUsageBar"
    private static let account = "sessionKey"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String {
        // Migration: alten Klartext-Wert aus UserDefaults in den Schlüsselbund verschieben
        if let legacy = UserDefaults.standard.string(forKey: "sessionKey") {
            UserDefaults.standard.removeObject(forKey: "sessionKey")
            if !legacy.isEmpty { save(legacy); return legacy }
        }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
