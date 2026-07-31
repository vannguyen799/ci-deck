import Foundation
import ServiceManagement

/// One watched repository plus the workflow filter applied to it.
struct RepoConfig: Codable, Hashable, Identifiable, Sendable {
    var owner: String
    var name: String
    var enabled: Bool = true
    /// Empty means "watch every workflow in this repo".
    var watchedWorkflowIds: Set<Int> = []
    /// Empty means "any branch".
    var branchFilter: String = ""
    /// Account used to access this repo. Nil falls back to the first account.
    var accountId: String?

    var id: String { "\(owner)/\(name)" }
    var slug: String { "\(owner)/\(name)" }

    /// Parses `owner/repo`, a full GitHub URL, or a `git@github.com:owner/repo.git` remote.
    static func parse(_ raw: String) -> RepoConfig? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let range = text.range(of: "github.com") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/:@ "))
        if text.hasSuffix(".git") { text.removeLast(4) }

        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let name = parts[1]
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        return RepoConfig(owner: owner, name: name)
    }
}

struct AccountConfig: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var login: String
    var label: String

    var displayName: String { label.isEmpty ? "@\(login)" : label }
}

/// User preferences, persisted to `UserDefaults`. The GitHub token lives in the
/// Keychain instead and is only surfaced here as `hasToken`.
@MainActor
final class AppSettings: ObservableObject {
    private static let storageKey = "cideck.settings.v1"

    @Published var repos: [RepoConfig] = []                { didSet { save() } }
    @Published var accounts: [AccountConfig] = []          { didSet { save() } }
    /// Poll interval while at least one run is queued or in progress.
    @Published var activeInterval: Double = 2              { didSet { save() } }
    /// Poll interval when everything is idle.
    @Published var idleInterval: Double = 5                { didSet { save() } }
    /// Show a macOS notification when a previously unseen workflow run appears.
    @Published var notificationsEnabled: Bool = true       { didSet { save() } }
    /// How many runs to request per repository.
    @Published var runsPerRepo: Int = 30                   { didSet { save() } }
    /// How many runs to actually render per repository.
    @Published var visibleRunsPerRepo: Int = 6             { didSet { save() } }
    /// Collapse to only the newest run of each workflow.
    @Published var latestPerWorkflowOnly: Bool = true      { didSet { save() } }
    /// Include successful/cancelled recent runs; off keeps only active and failed runs.
    @Published var showRecentRuns: Bool = false            { didSet { save() } }
    @Published var launchAtLogin: Bool = false             { didSet { save(); syncLoginItem() } }

    var hasToken: Bool { !accounts.isEmpty }

    private var isLoading = false

    init() {
        load()
        migrateLegacyTokenIfNeeded()
    }

    // MARK: Token

    @discardableResult
    func addAccount(token: String, login: String = "GitHub", label: String = "") throws -> AccountConfig {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsError.emptyToken }
        let account = AccountConfig(id: UUID().uuidString, login: login, label: label)
        try Keychain.save(trimmed, account: account.id)
        accounts.append(account)
        return account
    }

    func updateAccount(_ account: AccountConfig, token: String? = nil) throws {
        if let token {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SettingsError.emptyToken }
            try Keychain.save(trimmed, account: account.id)
        }
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
    }

    func removeAccount(id: String) {
        Keychain.delete(account: id)
        accounts.removeAll { $0.id == id }
        let fallback = accounts.first?.id
        repos = repos.map { repo in
            var copy = repo
            if copy.accountId == id { copy.accountId = fallback }
            return copy
        }
    }

    nonisolated static func token(for accountId: String?) -> String? {
        guard let accountId, let token = Keychain.read(account: accountId), !token.isEmpty else { return nil }
        return token
    }

    func resolvedAccountId(for repo: RepoConfig) -> String? {
        if let id = repo.accountId, accounts.contains(where: { $0.id == id }) { return id }
        return accounts.first?.id
    }

    // MARK: Repo helpers

    /// Adds a repo, ignoring duplicates. Returns false when it was already present.
    @discardableResult
    func addRepo(_ config: RepoConfig) -> Bool {
        guard !repos.contains(where: { $0.id.lowercased() == config.id.lowercased() }) else {
            return false
        }
        repos.append(config)
        return true
    }

    func removeRepo(id: String) {
        repos.removeAll { $0.id == id }
    }

    func update(_ config: RepoConfig) {
        guard let index = repos.firstIndex(where: { $0.id == config.id }) else { return }
        repos[index] = config
    }

    func toggleWorkflow(repoId: String, workflowId: Int, watched: Bool) {
        guard let index = repos.firstIndex(where: { $0.id == repoId }) else { return }
        if watched {
            repos[index].watchedWorkflowIds.insert(workflowId)
        } else {
            repos[index].watchedWorkflowIds.remove(workflowId)
        }
    }

    func watchAllWorkflows(repoId: String) {
        guard let index = repos.firstIndex(where: { $0.id == repoId }) else { return }
        repos[index].watchedWorkflowIds.removeAll()
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var repos: [RepoConfig]
        var accounts: [AccountConfig]?
        var activeInterval: Double
        var idleInterval: Double
        var runsPerRepo: Int
        var visibleRunsPerRepo: Int
        var latestPerWorkflowOnly: Bool
        var showRecentRuns: Bool?
        var notificationsEnabled: Bool?
        var launchAtLogin: Bool
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }

        isLoading = true
        repos = payload.repos
        accounts = payload.accounts ?? []
        // Older versions allowed much slower values. Keep persisted settings in
        // the new fast-polling range so a newly started run is found promptly.
        activeInterval = min(5, max(2, payload.activeInterval))
        idleInterval = min(5, max(2, payload.idleInterval))
        runsPerRepo = payload.runsPerRepo
        visibleRunsPerRepo = payload.visibleRunsPerRepo
        latestPerWorkflowOnly = payload.latestPerWorkflowOnly
        showRecentRuns = payload.showRecentRuns ?? false
        notificationsEnabled = payload.notificationsEnabled ?? true
        launchAtLogin = payload.launchAtLogin
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let payload = Payload(
            repos: repos,
            accounts: accounts,
            activeInterval: activeInterval,
            idleInterval: idleInterval,
            runsPerRepo: runsPerRepo,
            visibleRunsPerRepo: visibleRunsPerRepo,
            latestPerWorkflowOnly: latestPerWorkflowOnly,
            showRecentRuns: showRecentRuns,
            notificationsEnabled: notificationsEnabled,
            launchAtLogin: launchAtLogin
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }


    private func migrateLegacyTokenIfNeeded() {
        guard accounts.isEmpty,
              let token = Keychain.read(account: Keychain.legacyAccount), !token.isEmpty else { return }
        let account = AccountConfig(id: UUID().uuidString, login: "GitHub", label: "Mặc định")
        guard (try? Keychain.save(token, account: account.id)) != nil else { return }
        accounts = [account]
        Keychain.delete(account: Keychain.legacyAccount)
    }

    private func syncLoginItem() {
        guard !isLoading else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registering only works from a signed .app bundle; ignore in dev builds.
            NSLog("CIDeck: login item update failed - \(error.localizedDescription)")
        }
    }
}

enum SettingsError: LocalizedError {
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .emptyToken: return "Token rỗng."
        }
    }
}
