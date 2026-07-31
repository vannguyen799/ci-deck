import AppKit
import Combine
import Foundation

/// Owns the polling loop and the state rendered by the popover.
///
/// Polling is adaptive: it ticks at `activeInterval` while anything is queued or
/// running and drops to `idleInterval` once everything settles. The loop is
/// suspended while the machine sleeps and refreshes immediately on wake.
@MainActor
final class RunsStore: ObservableObject {
    @Published private(set) var repoStates: [RepoRuns] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var globalError: String?
    @Published private(set) var rateLimit = RateLimitInfo()
    /// Workflow catalog per repo id, used for names and the settings picker.
    @Published private(set) var workflowCatalog: [String: [GHWorkflow]] = [:]

    private let settings: AppSettings
    private let client: GitHubClient
    private var loop: Task<Void, Never>?
    private var isAsleep = false
    private var cancellables = Set<AnyCancellable>()
    /// workflowId -> typical successful duration, used for the ETA hint.
    private var baselines: [Int: TimeInterval] = [:]

    init(settings: AppSettings, client: GitHubClient = GitHubClient()) {
        self.settings = settings
        self.client = client
        observeSystemSleep()
        observeSettings()
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let seconds = await self.nextInterval()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Cancels the pending sleep and polls right away.
    func refreshNow() {
        stop()
        start()
    }

    /// Called after the token changes so cached ETags from the old identity are dropped.
    func resetAndRefresh() {
        Task {
            await client.resetCache()
            baselines.removeAll()
            workflowCatalog.removeAll()
            refreshNow()
        }
    }

    private func nextInterval() -> Double {
        let hasActive = repoStates.contains(where: \.hasActive)
        let base = hasActive ? settings.activeInterval : settings.idleInterval

        // Back off hard when the rate limit is nearly exhausted.
        if let remaining = rateLimit.remaining, remaining < 100 {
            return max(base, 120)
        }
        return max(5, base)
    }

    private func observeSystemSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isAsleep = true
                self?.stop()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isAsleep = false
                self?.refreshNow()
            }
        }
    }

    private func observeSettings() {
        settings.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isAsleep else { return }
                    self.refreshNow()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    func refresh() async {
        guard settings.hasToken else {
            repoStates = []
            globalError = nil
            return
        }
        let repos = settings.repos.filter(\.enabled)
        guard !repos.isEmpty else {
            repoStates = []
            globalError = nil
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        // Workflow names are needed to label runs; fetch the catalog once per repo.
        await loadMissingCatalogs(for: repos)

        let options = LoadOptions(
            runsPerRepo: settings.runsPerRepo,
            visibleRunsPerRepo: settings.visibleRunsPerRepo,
            latestPerWorkflowOnly: settings.latestPerWorkflowOnly
        )
        let names = workflowNameMap()
        let currentBaselines = baselines
        let client = self.client

        var results: [String: RepoRuns] = [:]
        await withTaskGroup(of: RepoRuns.self) { group in
            for repo in repos {
                group.addTask {
                    await Self.load(repo: repo,
                                    client: client,
                                    options: options,
                                    workflowNames: names,
                                    baselines: currentBaselines)
                }
            }
            for await state in group {
                results[state.id] = state
            }
        }

        // Preserve the order the user configured rather than completion order.
        repoStates = repos.compactMap { results[$0.id] }
        updateBaselines(from: repoStates)
        rateLimit = await client.currentRateLimit()
        lastRefresh = Date()
        globalError = repoStates.allSatisfy { $0.error != nil } ? repoStates.first?.error : nil
    }

    private func loadMissingCatalogs(for repos: [RepoConfig]) async {
        let missing = repos.filter { workflowCatalog[$0.id] == nil }
        guard !missing.isEmpty else { return }
        for repo in missing {
            if let list = try? await client.workflows(owner: repo.owner, repo: repo.name) {
                workflowCatalog[repo.id] = list.sorted { $0.name < $1.name }
            }
        }
    }

    /// Forces a catalog reload — used by the settings screen's refresh button.
    func reloadWorkflows(for repo: RepoConfig) async throws {
        let list = try await client.workflows(owner: repo.owner, repo: repo.name)
        workflowCatalog[repo.id] = list.sorted { $0.name < $1.name }
    }

    func validateToken() async throws -> GHUser {
        await client.resetCache()
        return try await client.viewer()
    }

    private func workflowNameMap() -> [Int: String] {
        var map: [Int: String] = [:]
        for list in workflowCatalog.values {
            for workflow in list { map[workflow.id] = workflow.name }
        }
        return map
    }

    private func updateBaselines(from states: [RepoRuns]) {
        var durations: [Int: [TimeInterval]] = [:]
        for state in states {
            for item in state.runs where item.state == .success {
                if let duration = item.run.finishedDuration, duration > 1 {
                    durations[item.run.workflowId, default: []].append(duration)
                }
            }
        }
        for (workflowId, values) in durations {
            let sample = Array(values.prefix(5)).sorted()
            guard !sample.isEmpty else { continue }
            baselines[workflowId] = sample[sample.count / 2]
        }
    }

    // MARK: - Aggregate

    var aggregate: AggregateStatus {
        guard settings.hasToken else { return .needsSetup }
        guard !settings.repos.filter(\.enabled).isEmpty else { return .needsSetup }
        if globalError != nil { return .error }

        let all = repoStates.flatMap(\.runs)
        guard !all.isEmpty else { return .idle }

        let active = all.filter { $0.state.isActive }
        if !active.isEmpty { return .running(active.count) }

        // Only the newest run of each workflow decides red vs green.
        var newest: [Int: RunItem] = [:]
        for item in all {
            let existing = newest[item.run.workflowId]
            if existing == nil || item.run.runNumber > existing!.run.runNumber {
                newest[item.run.workflowId] = item
            }
        }
        let failing = newest.values.filter { $0.state == .failure }
        if !failing.isEmpty { return .failure(failing.count) }
        return .success
    }

    var totalRuns: Int { repoStates.reduce(0) { $0 + $1.runs.count } }

    // MARK: - Per-repo loading (off the main actor)

    private struct LoadOptions: Sendable {
        let runsPerRepo: Int
        let visibleRunsPerRepo: Int
        let latestPerWorkflowOnly: Bool
    }

    nonisolated private static func load(repo: RepoConfig,
                                         client: GitHubClient,
                                         options: LoadOptions,
                                         workflowNames: [Int: String],
                                         baselines: [Int: TimeInterval]) async -> RepoRuns {
        do {
            let runs = try await client.runs(owner: repo.owner,
                                             repo: repo.name,
                                             perPage: options.runsPerRepo,
                                             branch: repo.branchFilter)

            var filtered = runs
            if !repo.watchedWorkflowIds.isEmpty {
                filtered = filtered.filter { repo.watchedWorkflowIds.contains($0.workflowId) }
            }
            if options.latestPerWorkflowOnly {
                var seen = Set<Int>()
                filtered = filtered.filter { seen.insert($0.workflowId).inserted }
            }
            let visible = Array(filtered.prefix(options.visibleRunsPerRepo))

            var items = visible.map { run in
                RunItem(run: run,
                        workflowName: workflowNames[run.workflowId] ?? run.name ?? "Workflow",
                        progress: nil,
                        jobsDone: nil,
                        jobsTotal: nil,
                        currentStep: nil,
                        etaSeconds: nil)
            }

            // Jobs are only fetched for runs that are actually moving.
            let activeIds = items.filter { $0.state.isActive }.map(\.run.id)
            if !activeIds.isEmpty {
                var jobsByRun: [Int: [GHJob]] = [:]
                await withTaskGroup(of: (Int, [GHJob]?).self) { group in
                    for runId in activeIds {
                        group.addTask {
                            let jobs = try? await client.jobs(owner: repo.owner, repo: repo.name, runId: runId)
                            return (runId, jobs)
                        }
                    }
                    for await (runId, jobs) in group {
                        if let jobs { jobsByRun[runId] = jobs }
                    }
                }

                for index in items.indices {
                    guard let jobs = jobsByRun[items[index].run.id], !jobs.isEmpty else { continue }
                    let summary = progressSummary(for: jobs)
                    items[index].progress = summary.fraction
                    items[index].jobsDone = summary.done
                    items[index].jobsTotal = summary.total
                    items[index].currentStep = summary.currentStep
                    items[index].etaSeconds = eta(elapsed: Date().timeIntervalSince(items[index].run.startedAt),
                                                  progress: summary.fraction,
                                                  baseline: baselines[items[index].run.workflowId])
                }
            }

            return RepoRuns(id: repo.id, repo: repo, runs: items, error: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return RepoRuns(id: repo.id, repo: repo, runs: [], error: message)
        }
    }

    private struct ProgressSummary {
        let fraction: Double
        let done: Int
        let total: Int
        let currentStep: String?
    }

    /// Averages per-job completion, using step counts to smooth out long-running jobs.
    nonisolated private static func progressSummary(for jobs: [GHJob]) -> ProgressSummary {
        var accumulated = 0.0
        var done = 0
        var currentStep: String?

        for job in jobs {
            switch job.status {
            case "completed":
                accumulated += 1
                done += 1
            case "in_progress":
                if let steps = job.steps, !steps.isEmpty {
                    let finished = steps.filter { $0.status == "completed" }.count
                    accumulated += Double(finished) / Double(steps.count)
                    if currentStep == nil, let running = steps.first(where: { $0.status == "in_progress" }) {
                        currentStep = jobs.count > 1 ? "\(job.name) › \(running.name)" : running.name
                    }
                } else {
                    accumulated += 0.5
                    if currentStep == nil { currentStep = job.name }
                }
            default:
                break // queued / waiting contributes nothing
            }
        }

        let fraction = min(1, max(0, accumulated / Double(jobs.count)))
        return ProgressSummary(fraction: fraction, done: done, total: jobs.count, currentStep: currentStep)
    }

    /// Prefers extrapolating from observed progress; falls back to the workflow's usual duration.
    nonisolated private static func eta(elapsed: TimeInterval, progress: Double, baseline: TimeInterval?) -> TimeInterval? {
        var estimate: TimeInterval?
        if progress > 0.15 {
            estimate = elapsed / progress - elapsed
        } else if let baseline {
            estimate = baseline - elapsed
        }
        guard let value = estimate, value > 5, value < 6 * 3600 else { return nil }
        return value
    }
}
