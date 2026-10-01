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
            return "No GitHub token configured."
        case .badURL(let path):
            return "Invalid URL: \(path)"
        case .unauthorized:
            return "Token is invalid or expired (401)."
        case .forbidden(let message):
            return "Forbidden (403): \(message)"
        case .rateLimited(let reset):
            guard let reset else { return "GitHub rate limit reached." }
            return "Rate limit reached, retry in \(Fmt.duration(reset.timeIntervalSinceNow))."
        case .notFound(let what):
            return "\(what) not found (404) — check the repository name or the token's permissions."
        case .http(let code, let message):
            return "HTTP error \(code): \(message)"
        case .decoding(let message):
            return "Could not read the response: \(message)"
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

    private static let repositoryPageSize = 100
    /// Caps discovery at 1000 repositories so a huge account cannot burn the rate limit.
    private static let maxRepositoryPages = 10

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

    /// Organizations the token can see. Fine-grained tokens without the
    /// "Organization: members" permission answer 403 here, which is not fatal —
    /// callers treat a failure as "no organizations known from this endpoint".
    func organizations(accountId: String?) async throws -> [GHOrganization] {
        try await fetch([GHOrganization].self, path: "/user/orgs?per_page=100", accountId: accountId)
    }

    /// Repositories reachable through `/user/repos`.
    ///
    /// `/user/repos` returns at most 100 per page sorted by full name, so a single
    /// request silently drops everything past the first alphabetical page — which is
    /// exactly where org repos tend to sit for accounts with many personal repos.
    func repositories(accountId: String?, maxPages: Int = GitHubClient.maxRepositoryPages) async throws -> [GHRepository] {
        var all: [GHRepository] = []
        var seen = Set<Int>()
        for page in 1...max(1, maxPages) {
            let path = "/user/repos?per_page=\(Self.repositoryPageSize)&page=\(page)"
                + "&sort=full_name&direction=asc"
                + "&affiliation=owner,collaborator,organization_member"
            let batch = try await fetch([GHRepository].self, path: path, accountId: accountId)
            for repo in batch where seen.insert(repo.id).inserted {
                all.append(repo)
            }
            if batch.count < Self.repositoryPageSize { break }
        }
        return all
    }

    /// Repositories listed by an organization itself.
    ///
    /// An org-scoped fine-grained PAT is granted repositories by the org, not by
    /// the user's own affiliation, so `/user/repos` can come back short (or empty)
    /// for exactly the repos the token was created for. This endpoint is the one
    /// that reflects the grant.
    func organizationRepositories(org: String, accountId: String?) async throws -> [GHRepository] {
        var all: [GHRepository] = []
        var seen = Set<Int>()
        for page in 1...Self.maxRepositoryPages {
            let path = "/orgs/\(org)/repos?per_page=\(Self.repositoryPageSize)&page=\(page)"
                + "&sort=full_name&direction=asc&type=all"
            let batch = try await fetch([GHRepository].self, path: path, accountId: accountId)
            for repo in batch where seen.insert(repo.id).inserted {
                all.append(repo)
            }
            if batch.count < Self.repositoryPageSize { break }
        }
        return all
    }

    /// Every repository the token can reach: the user's own listing merged with
    /// each organization's. Per-owner failures are skipped rather than fatal, so
    /// one org the token cannot read does not hide all the others.
    func accessibleRepositories(accountId: String?) async throws -> [GHRepository] {
        var all: [GHRepository] = []
        var seen = Set<Int>()
        var userListingError: Error?

        do {
            for repo in try await repositories(accountId: accountId) where seen.insert(repo.id).inserted {
                all.append(repo)
            }
        } catch {
            userListingError = error
        }

        for org in await knownOrganizations(accountId: accountId, seedRepositories: all, viewerLogin: nil) {
            guard let batch = try? await organizationRepositories(org: org, accountId: accountId) else { continue }
            for repo in batch where seen.insert(repo.id).inserted {
                all.append(repo)
            }
        }

        if all.isEmpty, let userListingError { throw userListingError }
        return all
    }

    /// What the token can actually read, used to label the account.
    func identity(accountId: String) async throws -> TokenIdentity {
        let viewer = try await viewer(accountId: accountId)
        // Two pages are enough to spot the owners; the full sweep happens in discovery.
        let repos = (try? await repositories(accountId: accountId, maxPages: 2)) ?? []
        var owners = Set(repos.map(\.owner.login))
        owners.formUnion(await knownOrganizations(accountId: accountId,
                                                  seedRepositories: repos,
                                                  viewerLogin: viewer.login))

        // A token that lists nothing at all still belongs to its viewer.
        if owners.isEmpty { owners.insert(viewer.login) }

        let sorted = owners.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return TokenIdentity(viewer: viewer, owners: sorted)
    }

    /// Organizations from `/user/orgs`, plus any org that already shows up as a
    /// repository owner — the fallback that matters when `/user/orgs` is denied.
    private func knownOrganizations(accountId: String?,
                                    seedRepositories: [GHRepository],
                                    viewerLogin: String?) async -> [String] {
        var logins = Set(seedRepositories.map(\.owner.login))
        if let orgs = try? await organizations(accountId: accountId) {
            logins.formUnion(orgs.map(\.login))
        }
        var viewer = viewerLogin
        if viewer == nil, let accountId {
            viewer = try? await self.viewer(accountId: accountId).login
        }
        if let viewer { logins.remove(viewer) }
        return logins.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    /// Re-runs a finished run. `failedJobsOnly` keeps the jobs that already
    /// succeeded and only replays the failed ones.
    ///
    /// Needs a token with Actions **write** access; a read-only token gets a 403.
    func rerun(owner: String, repo: String, runId: Int, failedJobsOnly: Bool, accountId: String?) async throws {
        let endpoint = failedJobsOnly ? "rerun-failed-jobs" : "rerun"
        try await post(path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/\(endpoint)", accountId: accountId)
    }

    // MARK: - Transport

    private func fetch<T: Decodable>(_ type: T.Type, path: String, accountId: String?, allowRetry: Bool = true) async throws -> T {
        var request = try makeRequest(path: path, method: "GET", accountId: accountId)
        let cacheKey = "\(accountId ?? "none"):\(path)"
        if let etag = etags[cacheKey] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await send(request)

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
                guard allowRetry else { throw GitHubError.http(304, "No cached copy") }
                return try await fetch(type, path: path, accountId: accountId, allowRetry: false)
            }
            return try decode(type, from: cached)

        default:
            throw failure(status: http.statusCode, path: path, data: data)
        }
    }

    /// POST for the mutating endpoints; the responses carry no body worth reading.
    private func post(path: String, accountId: String?) async throws {
        let request = try makeRequest(path: path, method: "POST", accountId: accountId)
        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, path: path, data: data)
        }
    }

    private func makeRequest(path: String, method: String, accountId: String?) throws -> URLRequest {
        guard let token = tokenProvider(accountId), !token.isEmpty else { throw GitHubError.noToken }
        guard let url = URL(string: "https://api.github.com" + path) else { throw GitHubError.badURL(path) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CIDeck/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(-1, "Invalid response")
        }
        captureRateLimit(from: http)
        return (data, http)
    }

    private func failure(status: Int, path: String, data: Data) -> GitHubError {
        switch status {
        case 401:
            return .unauthorized
        case 403, 429:
            if rateLimit.remaining == 0 { return .rateLimited(rateLimit.reset) }
            return .forbidden(message(from: data))
        case 404:
            return .notFound(path)
        default:
            return .http(status, message(from: data))
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
