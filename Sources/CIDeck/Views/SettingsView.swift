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
                .tabItem { Label("Chung", systemImage: "slider.horizontal.3") }
        }
        .padding(14)
        .frame(width: 680, height: 500)
    }
}

// MARK: - GitHub account

@MainActor
private struct AccountSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunsStore

    @State private var token = ""
    @State private var status: Status = .idle

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

            Text("Chỉ cần nhập token; CIDeck sẽ tự lấy username từ GitHub. Thêm một token cho mỗi account hoặc organization scope. Token được lưu tách biệt trong macOS Keychain; mỗi repo có thể chọn token riêng ở tab Repositories.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(settings.accounts) { account in
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName).font(.system(size: 12, weight: .medium))
                            Text("@\(account.login)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.removeAccount(id: account.id)
                            store.resetAndRefresh()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Xoá account và token")
                    }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 150)

            Text("Thêm account").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                SecureField("ghp_… hoặc github_pat_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                Button("Thêm & kiểm tra") { save() }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || status == .checking)
            }

            statusLine

            Link("Tạo token trên GitHub →",
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
                Text("Đang kiểm tra…").font(.system(size: 11))
            }
        case .ok(let login):
            Label("Đã kết nối với @\(login).", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        let value = token
        status = .checking
        let account: AccountConfig
        do {
            account = try settings.addAccount(token: value)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        Task {
            do {
                let user = try await store.validateToken(accountId: account.id)
                var verified = account
                verified.login = user.login
                try settings.updateAccount(verified)
                status = .ok(user.login)
                token = ""
                store.resetAndRefresh()
            } catch {
                settings.removeAccount(id: account.id)
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = .failed(message)
            }
        }
    }
}

// MARK: - Repositories

@MainActor
private struct RepositoriesSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunsStore

    @State private var newRepo = ""
    @State private var selection: String?
    @State private var addError: String?
    @State private var discoveryAccountId: String?
    @State private var discoveredRepos: [GHRepository] = []
    @State private var isDiscovering = false

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
                .help("Tải repository token có thể truy cập")
            }

            List(selection: $selection) {
                Section("Đang theo dõi") {
                    ForEach(settings.repos) { repo in
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

                if !availableRepos.isEmpty {
                    Section("Có thể thêm") {
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
                Button("Thêm") { add() }
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
                    Label("Xoá repo đang chọn", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
    }

    private var availableRepos: [GHRepository] {
        discoveredRepos.filter { candidate in
            !settings.repos.contains { $0.id.caseInsensitiveCompare(candidate.slug) == .orderedSame }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let repo = settings.repos.first(where: { $0.id == selection }) {
            RepoDetailView(repo: repo)
        } else {
            VStack {
                Spacer()
                Text("Chọn một repo để cấu hình workflow.")
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
            addError = "Định dạng phải là owner/repo hoặc URL GitHub."
            return
        }
        config.accountId = settings.accounts.first?.id
        guard settings.addRepo(config) else {
            addError = "Repo này đã có trong danh sách."
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
                .help("Tải lại danh sách workflow")
            }

            HStack(spacing: 6) {
                Text("Account:").font(.system(size: 11))
                Picker("", selection: accountBinding) {
                    ForEach(settings.accounts) { account in
                        Text(account.displayName).tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                Text("Branch:").font(.system(size: 11))
                TextField("để trống = tất cả", text: branchBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Divider()

            HStack {
                Text("Workflows theo dõi").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(watchAll ? "Đang theo dõi tất cả" : "Chọn tất cả") {
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
                Text("Chưa tải được workflow nào. Bấm nút refresh phía trên.")
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
                 ? "Không chọn gì = theo dõi mọi workflow của repo."
                 : "Đang theo dõi \(repo.watchedWorkflowIds.count) workflow.")
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
            loadError = "Cần thêm account ở tab GitHub trước."
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
                Toggle("Khởi động cùng macOS", isOn: $settings.launchAtLogin)
                Toggle("Thông báo khi có CI/CD mới", isOn: notificationBinding)
                Toggle("Chỉ hiện run mới nhất của mỗi workflow", isOn: $settings.latestPerWorkflowOnly)
                Toggle("Hiện các CI/CD gần đây", isOn: $settings.showRecentRuns)
            }

            Section("Tần suất cập nhật") {
                LabeledContent("Khi có run đang chạy") {
                    HStack {
                        Slider(value: $settings.activeInterval, in: 2...5, step: 1)
                            .frame(width: 220)
                        Text("\(Int(settings.activeInterval))s").monospacedDigit().frame(width: 36)
                    }
                }
                LabeledContent("Khi rảnh") {
                    HStack {
                        Slider(value: $settings.idleInterval, in: 2...5, step: 1)
                            .frame(width: 220)
                        Text("\(Int(settings.idleInterval))s").monospacedDigit().frame(width: 36)
                    }
                }
            }

            Section("Hiển thị") {
                LabeledContent("Số run tải mỗi repo") {
                    Stepper("\(settings.runsPerRepo)",
                            value: $settings.runsPerRepo, in: 10...100, step: 10)
                        .frame(width: 120)
                }
                LabeledContent("Số run hiện trong popover") {
                    Stepper("\(settings.visibleRunsPerRepo)",
                            value: $settings.visibleRunsPerRepo, in: 1...20)
                        .frame(width: 120)
                }
            }

            Section {
                Text(settings.showRecentRuns
                     ? "Popover hiện cả các run thành công, bị huỷ và bỏ qua gần đây."
                     : "Mặc định chỉ hiện CI/CD đang chạy, đang chờ hoặc bị lỗi.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Requests dùng ETag nên phần lớn lần poll trả về 304 và không bị tính vào rate limit "
                     + "(5.000 request/giờ cho token cá nhân). App tự tạm dừng khi máy sleep.")
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
