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

/// User preferences, persisted to `UserDefaults`. The GitHub token lives in the
/// Keychain instead and is only surfaced here as `hasToken`.
@MainActor
final class AppSettings: ObservableObject {
    private static let storageKey = "cideck.settings.v1"

    @Published var repos: [RepoConfig] = []                { didSet { save() } }
    /// Poll interval while at least one run is queued or in progress.
    @Published var activeInterval: Double = 10             { didSet { save() } }
    /// Poll interval when everything is idle.
    @Published var idleInterval: Double = 60               { didSet { save() } }
    /// How many runs to request per repository.
    @Published var runsPerRepo: Int = 30                   { didSet { save() } }
    /// How many runs to actually render per repository.
    @Published var visibleRunsPerRepo: Int = 6             { didSet { save() } }
    /// Collapse to only the newest run of each workflow.
    @Published var latestPerWorkflowOnly: Bool = true      { didSet { save() } }
    @Published var launchAtLogin: Bool = false             { didSet { save(); syncLoginItem() } }

    @Published private(set) var hasToken: Bool = false

    private var isLoading = false

    init() {
        load()
        hasToken = Keychain.read()?.isEmpty == false
    }

    // MARK: Token

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsError.emptyToken }
        try Keychain.save(trimmed)
        hasToken = true
    }

    func clearToken() {
        Keychain.delete()
        hasToken = false
    }

    /// Read by `GitHubClient` from a background context, so it must not touch actor state.
    nonisolated static func currentToken() -> String? {
        guard let token = Keychain.read(), !token.isEmpty else { return nil }
        return token
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
        var activeInterval: Double
        var idleInterval: Double
        var runsPerRepo: Int
        var visibleRunsPerRepo: Int
        var latestPerWorkflowOnly: Bool
        var launchAtLogin: Bool
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }

        isLoading = true
        repos = payload.repos
        activeInterval = payload.activeInterval
        idleInterval = payload.idleInterval
        runsPerRepo = payload.runsPerRepo
        visibleRunsPerRepo = payload.visibleRunsPerRepo
        latestPerWorkflowOnly = payload.latestPerWorkflowOnly
        launchAtLogin = payload.launchAtLogin
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let payload = Payload(
            repos: repos,
            activeInterval: activeInterval,
            idleInterval: idleInterval,
            runsPerRepo: runsPerRepo,
            visibleRunsPerRepo: visibleRunsPerRepo,
            latestPerWorkflowOnly: latestPerWorkflowOnly,
            launchAtLogin: launchAtLogin
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
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
