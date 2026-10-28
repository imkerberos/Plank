import Foundation

struct CodexUsageResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: RateLimit?
    let rateLimitResetCredits: ResetCredits?

    struct ResetCredits: Decodable, Sendable {
        let availableCount: Int?
    }

    struct RateLimit: Decodable, Sendable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAt: Double?
        let resetAfterSeconds: Double?

        var remaining: Double { min(100, max(0, 100 - usedPercent)) }
        func resetDate(receivedAt: Date) -> Date? {
            if let resetAt, resetAt.isFinite { return Date(timeIntervalSince1970: resetAt) }
            if let resetAfterSeconds, resetAfterSeconds.isFinite {
                return receivedAt.addingTimeInterval(resetAfterSeconds)
            }
            return nil
        }
        var title: String {
            guard let seconds = limitWindowSeconds, seconds > 0 else { return "Usage window" }
            return seconds % 86400 == 0 ? "\(seconds / 86400)d" : "\(seconds / 3600)h"
        }
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Self.self, from: data)
        guard response.rateLimit?.primaryWindow != nil || response.rateLimit?.secondaryWindow != nil else {
            throw CodexUsageError.unavailable
        }
        return response
    }
}

enum CodexUsageError: Error, LocalizedError {
    case credentials, authentication, forbidden, throttled, server, unavailable, network
    var errorDescription: String? {
        switch self {
        case .credentials: "No Codex OAuth credentials found. Sign in with Codex CLI or Desktop. File-based auth.json is required; Keychain-only storage is not supported."
        case .authentication: "Codex sign-in expired. Sign in again with Codex CLI or Desktop, then refresh."
        case .forbidden: "Access denied by Codex. Check your account and subscription."
        case .throttled: "Too many requests. Automatic refresh will retry later."
        case .server: "Codex service is temporarily unavailable."
        case .unavailable: "The Codex usage response has no supported quota windows."
        case .network: "Unable to fetch Codex usage. Check your connection and try again."
        }
    }
}

struct CodexUsageClient: Sendable {
    let session: URLSession
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
    init(session: URLSession? = nil) { self.session = session ?? Self.defaultSession }

    func fetch(homePath: String?) async throws -> CodexUsageResponse {
        struct Auth: Decodable {
            let tokens: Tokens?
            struct Tokens: Decodable {
                let access_token: String
                let account_id: String?
            }
        }
        let environment = ProcessInfo.processInfo.environment
        let root = homePath.flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let tokens = (try? JSONDecoder().decode(Auth.self, from: data))?.tokens,
              !tokens.access_token.isEmpty else { throw CodexUsageError.credentials }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(tokens.access_token)", forHTTPHeaderField: "Authorization")
        if let account = tokens.account_id, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: Data
        let response: URLResponse
        do { (body, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw CodexUsageError.network }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            do { return try CodexUsageResponse.decode(body) }
            catch { throw CodexUsageError.unavailable }
        case 401: throw CodexUsageError.authentication
        case 403: throw CodexUsageError.forbidden
        case 429: throw CodexUsageError.throttled
        case 500...599: throw CodexUsageError.server
        default: throw CodexUsageError.network
        }
    }
}
