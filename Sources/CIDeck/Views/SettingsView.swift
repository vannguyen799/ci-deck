import AppKit
import SwiftUI

enum SettingsWindow {
    static let id = "cideck-settings"
}

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettingsTab()
                .tabItem { Label("GitHub", systemImage: "person.badge.key") }
            RepositoriesSettingsTab()
                .tabItem { Label("Repositories", systemImage: "shippingbox") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
        }
        .padding(14)
        .frame(width: 680, height: 500)
    }
}

/// The three tabs on their own, so the documentation screenshots can frame one at
/// a time instead of the whole `TabView`.
@MainActor
enum SettingsTabs {
    static func account() -> some View { AccountSettingsTab().settingsTabFrame() }
    static func repositories(select repoId: String? = nil) -> some View {
        RepositoriesSettingsTab(initialSelection: repoId).settingsTabFrame()
    }
    /// Taller than the real window so the whole form fits in one image instead of
    /// being cut off mid-row.
    static func general() -> some View { GeneralSettingsTab().settingsTabFrame(height: 610) }
}

private extension View {
    func settingsTabFrame(height: CGFloat = 470) -> some View {
        padding(14).frame(width: 680, height: height)
    }
}

// MARK: - GitHub account

@MainActor
private struct AccountSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunsStore

    @State private var token = ""
    @State private var label = ""
    @State private var status: Status = .idle
    @State private var refreshingAccountId: String?

    private enum Status: Equatable {
        case idle
        case checking
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub accounts")
                .font(.headline)

            Text("Just paste a token; CIDeck detects which owners it can read. A fine-grained token issued to an organization shows that org's name rather than the username that created it — GitHub always returns the username at /user, so that name alone cannot tell two tokens apart. Tokens are stored separately in the macOS Keychain; each repository can pick its own token in the Repositories tab.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(settings.accounts) { account in
                    HStack {
                        Image(systemName: account.isOrgScoped ? "building.2.fill" : "person.crop.circle.fill")
                            .foregroundStyle(account.isOrgScoped ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName).font(.system(size: 12, weight: .medium))
                            Text(account.scopeOwners.isEmpty
                                 ? "Scope not detected — click refresh"
                                 : account.scopeDescription)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            redetect(account)
                        } label: {
                            if refreshingAccountId == account.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(refreshingAccountId != nil)
                        .help("Re-detect the token's scope")
                        Button(role: .destructive) {
                            settings.removeAccount(id: account.id)
                            store.resetAndRefresh()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove the account and its token")
                    }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 150)

            Text("Add account").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                SecureField("ghp_… or github_pat_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                TextField("Display name (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button("Add & Verify") { save() }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || status == .checking)
            }

            statusLine

            Link("Create a token on GitHub →",
                 destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                .font(.system(size: 11))

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying…").font(.system(size: 11))
            }
        case .ok(let summary):
            Label("Connected: \(summary)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        let value = token
        let name = label.trimmingCharacters(in: .whitespaces)
        status = .checking
        let account: AccountConfig
        do {
            account = try settings.addAccount(token: value, label: name)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        Task {
            do {
                try await store.validateToken(accountId: account.id)
                status = .ok(summary(for: account.id))
                token = ""
                label = ""
                store.resetAndRefresh()
            } catch {
                settings.removeAccount(id: account.id)
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = .failed(message)
            }
        }
    }

    /// Re-runs scope detection for an account added before this build, or after
    /// the org changed what the token may read.
    private func redetect(_ account: AccountConfig) {
        refreshingAccountId = account.id
        status = .checking
        Task {
            do {
                try await store.validateToken(accountId: account.id)
                status = .ok(summary(for: account.id))
                store.resetAndRefresh()
            } catch {
                status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            refreshingAccountId = nil
        }
    }

    private func summary(for accountId: String) -> String {
        guard let updated = settings.accounts.first(where: { $0.id == accountId }) else { return "" }
        return "\(updated.displayName) — \(updated.scopeDescription)"
    }
}

// MARK: - Repositories

@MainActor
private struct RepositoriesSettingsTab: View {
    /// Repo to select on first appearance; only the screenshot runner passes one.
    var initialSelection: String?

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunsStore

    @State private var newRepo = ""
    @State private var selection: String?
    @State private var addError: String?
    @State private var discoveryAccountId: String?
    @State private var discoveredRepos: [GHRepository] = []
    @State private var isDiscovering = false
    @State private var repoFilter = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            repoList
                .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if discoveryAccountId == nil { discoveryAccountId = settings.accounts.first?.id }
            if selection == nil { selection = initialSelection }
            discover()
        }
        .onChange(of: discoveryAccountId) { _ in discover() }
    }

    private var repoList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Picker("", selection: $discoveryAccountId) {
                    ForEach(settings.accounts) { account in
                        Text(account.displayName).tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                Button { discover() } label: {
                    if isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(discoveryAccountId == nil || isDiscovering)
                .help("Load repositories the token can reach")
            }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Search owner/repo", text: $repoFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !repoFilter.isEmpty {
                    Button { repoFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))

            List(selection: $selection) {
                Section("Monitored") {
                    ForEach(trackedRepos) { repo in
                        HStack(spacing: 6) {
                            Toggle("", isOn: enabledBinding(for: repo))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(repo.name).font(.system(size: 12, weight: .medium))
                                Text(repo.owner).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !repo.watchedWorkflowIds.isEmpty {
                                Text("\(repo.watchedWorkflowIds.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(repo.id)
                    }
                }

                if availableRepos.isEmpty, !repoFilter.isEmpty, !discoveredRepos.isEmpty {
                    Section("Available") {
                        Text("No repository matches “\(repoFilter)”.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else if !availableRepos.isEmpty {
                    Section("Available (\(availableRepos.count))") {
                        ForEach(availableRepos) { repo in
                            Button { importRepo(repo) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(repo.name).font(.system(size: 12, weight: .medium))
                                        Text(repo.owner.login).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.bordered)

            HStack(spacing: 6) {
                TextField("owner/repo", text: $newRepo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let addError {
                Text(addError).font(.system(size: 10)).foregroundStyle(.red)
            }

            if let selection {
                Button(role: .destructive) {
                    settings.removeRepo(id: selection)
                    self.selection = nil
                } label: {
                    Label("Remove selected repository", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
    }

    /// Matches on the whole `owner/repo` slug so typing an org name also hits.
    private func matchesFilter(_ slug: String) -> Bool {
        let query = repoFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return slug.localizedCaseInsensitiveContains(query)
    }

    private var trackedRepos: [RepoConfig] {
        settings.repos.filter { matchesFilter($0.id) }
    }

    private var availableRepos: [GHRepository] {
        discoveredRepos.filter { candidate in
            matchesFilter(candidate.slug)
                && !settings.repos.contains { $0.id.caseInsensitiveCompare(candidate.slug) == .orderedSame }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let repo = settings.repos.first(where: { $0.id == selection }) {
            RepoDetailView(repo: repo)
        } else {
            VStack {
                Spacer()
                Text("Select a repository to configure workflows.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func enabledBinding(for repo: RepoConfig) -> Binding<Bool> {
        Binding(
            get: { settings.repos.first(where: { $0.id == repo.id })?.enabled ?? false },
            set: { newValue in
                var copy = repo
                copy.enabled = newValue
                settings.update(copy)
            }
        )
    }

    private func add() {
        guard var config = RepoConfig.parse(newRepo) else {
            addError = "Format must be owner/repo or a GitHub URL."
            return
        }
        // Prefer the token that actually reaches this owner over whichever
        // account happens to be first — an org repo needs the org's token.
        config.accountId = settings.accountId(reaching: config.owner)
            ?? discoveryAccountId
            ?? settings.accounts.first?.id
        guard settings.addRepo(config) else {
            addError = "This repository is already in the list."
            return
        }
        addError = nil
        newRepo = ""
        selection = config.id
    }

    private func discover() {
        guard let accountId = discoveryAccountId else {
            discoveredRepos = []
            return
        }
        isDiscovering = true
        addError = nil
        Task {
            do {
                discoveredRepos = try await store.discoverRepositories(accountId: accountId)
            } catch {
                addError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                discoveredRepos = []
            }
            isDiscovering = false
        }
    }

    private func importRepo(_ repository: GHRepository) {
        guard var config = RepoConfig.parse(repository.slug) else { return }
        config.accountId = discoveryAccountId
        guard settings.addRepo(config) else { return }
        selection = config.id
    }
}

@MainActor
private struct RepoDetailView: View {
    let repo: RepoConfig

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunsStore

    @State private var isLoading = false
    @State private var loadError: String?

    private var workflows: [GHWorkflow] { store.workflowCatalog[repo.id] ?? [] }
    private var watchAll: Bool { repo.watchedWorkflowIds.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(repo.slug).font(.headline)
                Spacer()
                Button {
                    load(force: true)
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Reload the workflow list")
            }

            HStack(spacing: 6) {
                // Without `fixedSize` the labels are the first thing AppKit squeezes
                // when the two 180pt controls do not fit, and they wrap letter by letter.
                Text("Account:").font(.system(size: 11)).fixedSize()
                Picker("", selection: accountBinding) {
                    ForEach(settings.accounts) { account in
                        Text(account.displayName).tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                Text("Branch:").font(.system(size: 11)).fixedSize()
                TextField("empty = all", text: branchBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, idealWidth: 180)
            }

            Divider()

            HStack {
                Text("Monitored workflows").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(watchAll ? "Monitoring all" : "Select all") {
                    settings.watchAllWorkflows(repoId: repo.id)
                }
                .controlSize(.small)
                .disabled(watchAll)
            }

            if let loadError {
                Text(loadError).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if workflows.isEmpty && !isLoading {
                Text("No workflows loaded. Click refresh above.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(workflows) { workflow in
                        Toggle(isOn: workflowBinding(workflow)) {
                            HStack(spacing: 5) {
                                Text(workflow.name).font(.system(size: 12))
                                Text(workflow.fileName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                if !workflow.isActive {
                                    Chip(text: "disabled")
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 2)
            }

            Text(watchAll
                 ? "Selecting nothing = monitor every workflow in the repository."
                 : "Monitoring \(repo.watchedWorkflowIds.count) workflows.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .onAppear { load(force: false) }
        .onChange(of: repo.id) { _ in load(force: false) }
    }

    private var branchBinding: Binding<String> {
        Binding(
            get: { settings.repos.first(where: { $0.id == repo.id })?.branchFilter ?? "" },
            set: { newValue in
                var copy = repo
                copy.branchFilter = newValue.trimmingCharacters(in: .whitespaces)
                settings.update(copy)
            }
        )
    }

    private var accountBinding: Binding<String?> {
        Binding(
            get: { settings.resolvedAccountId(for: repo) },
            set: { newValue in
                var copy = repo
                copy.accountId = newValue
                settings.update(copy)
                Task {
                    store.clearWorkflowCatalog(for: repo.id)
                    load(force: true)
                }
            }
        )
    }

    private func workflowBinding(_ workflow: GHWorkflow) -> Binding<Bool> {
        Binding(
            get: {
                guard let current = settings.repos.first(where: { $0.id == repo.id }) else { return false }
                return current.watchedWorkflowIds.isEmpty || current.watchedWorkflowIds.contains(workflow.id)
            },
            set: { isOn in
                guard let current = settings.repos.first(where: { $0.id == repo.id }) else { return }
                if current.watchedWorkflowIds.isEmpty {
                    // "All" is implicit; unchecking one means explicitly selecting the rest.
                    guard !isOn else { return }
                    var ids = Set(workflows.map(\.id))
                    ids.remove(workflow.id)
                    var copy = current
                    copy.watchedWorkflowIds = ids
                    settings.update(copy)
                } else {
                    settings.toggleWorkflow(repoId: repo.id, workflowId: workflow.id, watched: isOn)
                }
            }
        )
    }

    private func load(force: Bool) {
        guard force || store.workflowCatalog[repo.id] == nil else { return }
        guard settings.resolvedAccountId(for: repo) != nil else {
            loadError = "Add an account in the GitHub tab first."
            return
        }
        isLoading = true
        loadError = nil
        Task {
            do {
                try await store.reloadWorkflows(for: repo)
            } catch {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - General

@MainActor
private struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Notify when a new CI/CD run starts", isOn: notificationBinding)
                Toggle("Only show the latest run per workflow", isOn: $settings.latestPerWorkflowOnly)
                Toggle("Show recent CI/CD runs", isOn: $settings.showRecentRuns)
            }

            Section("Refresh frequency") {
                LabeledContent("While a run is active") {
                    HStack {
                        Slider(value: $settings.activeInterval, in: 2...5, step: 1)
                            .frame(width: 220)
                        Text("\(Int(settings.activeInterval))s").monospacedDigit().frame(width: 36)
                    }
                }
                LabeledContent("While idle") {
                    HStack {
                        Slider(value: $settings.idleInterval, in: 2...5, step: 1)
                            .frame(width: 220)
                        Text("\(Int(settings.idleInterval))s").monospacedDigit().frame(width: 36)
                    }
                }
            }

            Section("Display") {
                LabeledContent("Runs loaded per repository") {
                    Stepper("\(settings.runsPerRepo)",
                            value: $settings.runsPerRepo, in: 10...100, step: 10)
                        .frame(width: 120)
                }
                LabeledContent("Runs shown in popover") {
                    Stepper("\(settings.visibleRunsPerRepo)",
                            value: $settings.visibleRunsPerRepo, in: 1...20)
                        .frame(width: 120)
                }
            }

            Section {
                Text(settings.showRecentRuns
                     ? "The popover also lists recent successful and skipped runs. Cancelled runs stay hidden."
                     : "By default only running, queued and failed CI/CD show up, plus successful runs you "
                       + "have not seen — a successful run disappears 5 minutes after you first see it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Requests use ETags, so most polls return 304 and do not count against the rate limit "
                     + "(5,000 requests/hour for a personal token). The app pauses itself while the Mac sleeps.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { settings.notificationsEnabled },
            set: { enabled in
                settings.notificationsEnabled = enabled
                guard enabled else { return }
                Task {
                    let granted = await NotificationService.shared.requestAuthorization()
                    if !granted { settings.notificationsEnabled = false }
                }
            }
        )
    }
}
