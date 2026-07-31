import Foundation

enum GitHubError: LocalizedError, Sendable {
    case noToken
    case badURL(String)
    case unauthorized
    case forbidden(String)
    case rateLimited(Date?)
    case notFound(String)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Chưa cấu hình GitHub token."
        case .badURL(let path):
            return "URL không hợp lệ: \(path)"
        case .unauthorized:
            return "Token không hợp lệ hoặc đã hết hạn (401)."
        case .forbidden(let message):
            return "Bị từ chối (403): \(message)"
        case .rateLimited(let reset):
            guard let reset else { return "Đã chạm rate limit của GitHub." }
            return "Chạm rate limit, thử lại sau \(Fmt.duration(reset.timeIntervalSinceNow))."
        case .notFound(let what):
            return "Không tìm thấy \(what) (404) — kiểm tra tên repo hoặc quyền của token."
        case .http(let code, let message):
            return "Lỗi HTTP \(code): \(message)"
        case .decoding(let message):
            return "Không đọc được phản hồi: \(message)"
        }
    }
}

/// Rate limit snapshot from the most recent response headers.
struct RateLimitInfo: Sendable, Equatable {
    var limit: Int?
    var remaining: Int?
    var reset: Date?
}

/// Serialised GitHub REST client with per-path ETag caching.
///
/// Conditional requests that come back `304 Not Modified` are not charged against
/// the REST rate limit, which is what keeps a 10-second poll affordable.
actor GitHubClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let tokenProvider: @Sendable (String?) -> String?

    private var etags: [String: String] = [:]
    private var bodies: [String: Data] = [:]

    private(set) var rateLimit = RateLimitInfo()

    init(tokenProvider: @escaping @Sendable (String?) -> String? = { AppSettings.token(for: $0) }) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.tokenProvider = tokenProvider

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func currentRateLimit() -> RateLimitInfo { rateLimit }

    /// Drops all cached ETags — used after the token changes so nothing leaks across accounts.
    func resetCache() {
        etags.removeAll()
        bodies.removeAll()
    }

    // MARK: - Endpoints

    func viewer(accountId: String) async throws -> GHUser {
        try await fetch(GHUser.self, path: "/user", accountId: accountId)
    }

    func repositories(accountId: String) async throws -> [GHRepository] {
        try await fetch([GHRepository].self,
                        path: "/user/repos?per_page=100&sort=full_name&direction=asc",
                        accountId: accountId)
    }

    func workflows(owner: String, repo: String, accountId: String?) async throws -> [GHWorkflow] {
        let list = try await fetch(GHWorkflowList.self,
                                   path: "/repos/\(owner)/\(repo)/actions/workflows?per_page=100",
                                   accountId: accountId)
        return list.workflows
    }

    func runs(owner: String, repo: String, perPage: Int, branch: String, accountId: String?) async throws -> [GHRun] {
        var path = "/repos/\(owner)/\(repo)/actions/runs?per_page=\(perPage)&exclude_pull_requests=true"
        if !branch.isEmpty {
            path += "&branch=\(Fmt.query(branch))"
        }
        let list = try await fetch(GHRunList.self, path: path, accountId: accountId)
        return list.workflowRuns
    }

    func jobs(owner: String, repo: String, runId: Int, accountId: String?) async throws -> [GHJob] {
        let list = try await fetch(GHJobList.self,
                                   path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/jobs?per_page=100",
                                   accountId: accountId)
        return list.jobs
    }

    // MARK: - Transport

    private func fetch<T: Decodable>(_ type: T.Type, path: String, accountId: String?, allowRetry: Bool = true) async throws -> T {
        guard let token = tokenProvider(accountId), !token.isEmpty else { throw GitHubError.noToken }
        guard let url = URL(string: "https://api.github.com" + path) else { throw GitHubError.badURL(path) }
        let cacheKey = "\(accountId ?? "none"):\(path)"

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CIDeck/1.0", forHTTPHeaderField: "User-Agent")
        if let etag = etags[cacheKey] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(-1, "Phản hồi không hợp lệ")
        }
        captureRateLimit(from: http)

        switch http.statusCode {
        case 200:
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                etags[cacheKey] = etag
                bodies[cacheKey] = data
            }
            return try decode(type, from: data)

        case 304:
            guard let cached = bodies[cacheKey] else {
                // ETag without a cached body (e.g. after a decode failure). Retry unconditionally.
                etags.removeValue(forKey: cacheKey)
                guard allowRetry else { throw GitHubError.http(304, "Không có bản cache") }
                return try await fetch(type, path: path, accountId: accountId, allowRetry: false)
            }
            return try decode(type, from: cached)

        case 401:
            throw GitHubError.unauthorized

        case 403, 429:
            if rateLimit.remaining == 0 {
                throw GitHubError.rateLimited(rateLimit.reset)
            }
            throw GitHubError.forbidden(message(from: data))

        case 404:
            throw GitHubError.notFound(path)

        default:
            throw GitHubError.http(http.statusCode, message(from: data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GitHubError.decoding(error.localizedDescription)
        }
    }

    private func captureRateLimit(from response: HTTPURLResponse) {
        func intHeader(_ name: String) -> Int? {
            (response.value(forHTTPHeaderField: name)).flatMap(Int.init)
        }
        rateLimit.limit = intHeader("x-ratelimit-limit") ?? rateLimit.limit
        rateLimit.remaining = intHeader("x-ratelimit-remaining") ?? rateLimit.remaining
        if let reset = intHeader("x-ratelimit-reset") {
            rateLimit.reset = Date(timeIntervalSince1970: TimeInterval(reset))
        }
    }

    private func message(from data: Data) -> String {
        struct APIError: Decodable { let message: String? }
        if let parsed = try? JSONDecoder().decode(APIError.self, from: data), let text = parsed.message {
            return text
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? "unknown"
    }
}
