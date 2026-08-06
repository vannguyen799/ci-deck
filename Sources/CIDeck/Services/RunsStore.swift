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
    /// The pending inter-poll sleep, kept separate from `loop` so it can be cut
    /// short without touching a poll that is already in flight.
    private var sleeper: Task<Void, Never>?
    /// Set by `refreshNow()`; consumed by the next `refresh()`.
    private var wantsImmediateRefresh = false
    private var isAsleep = false
    private var cancellables = Set<AnyCancellable>()
    /// workflowId -> typical successful duration, used for the ETA hint.
    private var baselines: [Int: TimeInterval] = [:]
    private var knownRunIds = Set<Int>()
    private var hasSeededRunIds = false
    /// runId -> the moment a succeeded run was first on screen. A success the user
    /// has never seen keeps its place indefinitely; this stamp starts its countdown.
    private var firstViewedAt: [Int: Date] = [:]
    private var isPopoverOpen = false

    init(settings: AppSettings, client: GitHubClient = GitHubClient()) {
        self.settings = settings
        self.client = client
        observeSystemSleep()
        observeSettings()
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        guard !DemoMode.isEnabled else {
            loadDemoSnapshot()
            loop = Task { [weak self] in
                // Still ticks, so elapsed timers and the spinner stay alive.
                while !Task.isCancelled {
                    guard let self else { return }
                    self.loadDemoSnapshot()
                    await self.waitForNextTick()
                }
            }
            return
        }
        Task { await backfillAccountIdentities() }
        if settings.notificationsEnabled {
            Task {
                let granted = await NotificationService.shared.requestAuthorization()
                if !granted { settings.notificationsEnabled = false }
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                await self.waitForNextTick()
            }
        }
    }

    func stop() {
        sleeper?.cancel()
        sleeper = nil
        loop?.cancel()
        loop = nil
    }

    /// Waits out the poll interval in a task of its own, so cancelling the wait is
    /// not the same thing as cancelling the poll.
    private func waitForNextTick() async {
        // A refresh requested while the previous poll was still running has no sleep
        // left to interrupt, so it is honoured here instead.
        guard !wantsImmediateRefresh else { return }
        let seconds = nextInterval()
        let sleeper = Task {
            // Cancellation is the normal way out of this wait, not an error.
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch {}
        }
        self.sleeper = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        self.sleeper = nil
    }

    // MARK: - Viewed tracking

    /// The popover became visible: everything green on screen right now starts its
    /// `recentSuccessWindow` countdown.
    func popoverDidAppear() {
        isPopoverOpen = true
        stampVisibleSuccessesAsViewed()
    }

    func popoverDidDisappear() {
        isPopoverOpen = false
    }

    private func stampVisibleSuccessesAsViewed() {
        let now = Date()
        for state in repoStates {
            for item in state.runs where item.state == .success {
                if firstViewedAt[item.run.id] == nil { firstViewedAt[item.run.id] = now }
            }
        }
    }

    /// A stamp is only useful while GitHub still lists the run; dropping it any
    /// earlier would make an expired success look unseen and pop back into the list.
    private func pruneViewedStamps(against states: [RepoRuns]) {
        guard states.allSatisfy({ $0.error == nil }) else { return }
        let live = Set(states.flatMap { $0.detectedRuns.map(\.run.id) })
        firstViewedAt = firstViewedAt.filter { live.contains($0.key) }
    }

    /// Cuts the pending sleep short so the next poll starts immediately.
    ///
    /// Deliberately does *not* tear the loop down: cancelling it would abort the
    /// HTTP requests of a poll already in flight, and every repo would come back
    /// with a "cancelled" transport error — a full screen of bogus error rows.
    func refreshNow() {
        guard loop != nil else {
            start()
            return
        }
        wantsImmediateRefresh = true
        sleeper?.cancel()
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
        return min(5, max(2, base))
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
        wantsImmediateRefresh = false
        guard !DemoMode.isEnabled else {
            loadDemoSnapshot()
            return
        }
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
            latestPerWorkflowOnly: settings.latestPerWorkflowOnly,
            showRecentRuns: settings.showRecentRuns,
            viewedAt: firstViewedAt
        )
        let names = workflowNameMap()
        let currentBaselines = baselines
        let client = self.client
        let accountIds = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, settings.resolvedAccountId(for: $0)) })

        var results: [String: RepoRuns] = [:]
        var wasAborted = false
        await withTaskGroup(of: RepoRuns?.self) { group in
            for repo in repos {
                group.addTask {
                    await Self.load(repo: repo,
                                    client: client,
                                    options: options,
                                    workflowNames: names,
                                    baselines: currentBaselines,
                                    accountId: accountIds[repo.id] ?? nil)
                }
            }
            for await state in group {
                if let state { results[state.id] = state } else { wasAborted = true }
            }
        }

        // An aborted poll knows nothing; keep the previous snapshot on screen
        // instead of replacing it with empty or error rows.
        guard !wasAborted, !Task.isCancelled else { return }

        // Preserve the order the user configured rather than completion order.
        let refreshedStates = repos.compactMap { results[$0.id] }
        notifyAboutNewRuns(in: refreshedStates)
        repoStates = refreshedStates
        pruneViewedStamps(against: refreshedStates)
        // A run that goes green while the popover is already open counts as seen
        // from the refresh that put it there.
        if isPopoverOpen { stampVisibleSuccessesAsViewed() }
        updateBaselines(from: repoStates)
        rateLimit = await client.currentRateLimit()
        lastRefresh = Date()
        globalError = repoStates.allSatisfy { $0.error != nil } ? repoStates.first?.error : nil
    }

    private func notifyAboutNewRuns(in states: [RepoRuns]) {
        let previousRefresh = lastRefresh
        let current = states.flatMap { state in
            state.detectedRuns.map { (repository: state.repo.slug, item: $0) }
        }
        let currentIds = Set(current.map { $0.item.run.id })

        // The first successful refresh establishes a baseline. Existing history
        // is not "new" merely because the app has just launched.
        guard hasSeededRunIds else {
            knownRunIds.formUnion(currentIds)
            hasSeededRunIds = true
            return
        }

        if settings.notificationsEnabled {
            let newRuns = current.filter { entry in
                guard !knownRunIds.contains(entry.item.run.id) else { return false }
                guard let previousRefresh else { return true }
                return entry.item.run.createdAt > previousRefresh
            }.sorted { $0.item.run.createdAt < $1.item.run.createdAt }
            for entry in newRuns {
                NotificationService.shared.notifyNewRun(entry.item, repository: entry.repository)
            }
        }
        knownRunIds.formUnion(currentIds)
    }

    /// Publishes the documentation fixture instead of polling GitHub.
    private func loadDemoSnapshot() {
        repoStates = DemoData.repoStates()
        workflowCatalog = DemoData.workflowCatalog
        rateLimit = DemoData.rateLimit
        lastRefresh = Date()
        globalError = nil
    }

    private func loadMissingCatalogs(for repos: [RepoConfig]) async {
        let missing = repos.filter { workflowCatalog[$0.id] == nil }
        guard !missing.isEmpty else { return }
        for repo in missing {
            let accountId = settings.resolvedAccountId(for: repo)
            if let list = try? await client.workflows(owner: repo.owner, repo: repo.name, accountId: accountId) {
                workflowCatalog[repo.id] = list.sorted { $0.name < $1.name }
            }
        }
    }

    /// Forces a catalog reload — used by the settings screen's refresh button.
    func reloadWorkflows(for repo: RepoConfig) async throws {
        if DemoMode.isEnabled {
            workflowCatalog[repo.id] = DemoData.workflowCatalog[repo.id] ?? []
            return
        }
        let list = try await client.workflows(owner: repo.owner, repo: repo.name,
                                              accountId: settings.resolvedAccountId(for: repo))
        workflowCatalog[repo.id] = list.sorted { $0.name < $1.name }
    }

    func clearWorkflowCatalog(for repoId: String) {
        workflowCatalog.removeValue(forKey: repoId)
    }

    /// Accounts stored before scope detection existed carry no owners, so they all
    /// read as the token's user. Fill them in once, quietly, at launch.
    private func backfillAccountIdentities() async {
        for account in settings.accounts where account.scopeOwners.isEmpty {
            guard let identity = try? await client.identity(accountId: account.id) else { continue }
            settings.applyIdentity(identity, to: account.id)
        }
    }

    /// Checks the token and works out which owner it really reads.
    @discardableResult
    func validateToken(accountId: String) async throws -> TokenIdentity {
        await client.resetCache()
        let identity = try await client.identity(accountId: accountId)
        settings.applyIdentity(identity, to: accountId)
        return identity
    }

    func discoverRepositories(accountId: String) async throws -> [GHRepository] {
        if DemoMode.isEnabled { return DemoData.discoverableRepositories }
        return try await client.accessibleRepositories(accountId: accountId)
            .filter { !$0.archived }
            .sorted { $0.slug.localizedCaseInsensitiveCompare($1.slug) == .orderedAscending }
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

    /// How long a succeeded run keeps its place in the default (active + failed)
    /// list once the user has actually seen it.
    nonisolated static let recentSuccessWindow: TimeInterval = 5 * 60

    private struct LoadOptions: Sendable {
        let runsPerRepo: Int
        let visibleRunsPerRepo: Int
        let latestPerWorkflowOnly: Bool
        let showRecentRuns: Bool
        /// runId -> first time the run was on screen; absent means never seen.
        let viewedAt: [Int: Date]
    }

    /// Returns `nil` when the poll was aborted rather than answered, so the caller
    /// can tell "no verdict" apart from "the repo really is in this state".
    nonisolated private static func load(repo: RepoConfig,
                                         client: GitHubClient,
                                         options: LoadOptions,
                                         workflowNames: [Int: String],
                                         baselines: [Int: TimeInterval],
                                         accountId: String?) async -> RepoRuns? {
        do {
            let runs = try await client.runs(owner: repo.owner,
                                             repo: repo.name,
                                             perPage: options.runsPerRepo,
                                             branch: repo.branchFilter,
                                             accountId: accountId)

            // Do not rely on the server's incidental ordering: all filtering and
            // rendering below starts with the newest run.
            var filtered = runs.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id > rhs.id }
                return lhs.createdAt > rhs.createdAt
            }
            if !repo.watchedWorkflowIds.isEmpty {
                filtered = filtered.filter { repo.watchedWorkflowIds.contains($0.workflowId) }
            }
            // Cancelled runs say nothing about a workflow's health — they are usually
            // a push superseding an earlier one. Drop them before the latest-per-workflow
            // pass so a cancellation cannot mask the last result that did mean something.
            filtered = filtered.filter { $0.state != .cancelled }
            let detectedItems = filtered.map { run in
                RunItem(run: run,
                        workflowName: workflowNames[run.workflowId] ?? run.name ?? "Workflow",
                        progress: nil,
                        jobsDone: nil,
                        jobsTotal: nil,
                        currentStep: nil,
                        etaSeconds: nil)
            }
            if !options.showRecentRuns {
                // Only the actual latest run matters. Do this before filtering by state so
                // an old failure is hidden once a newer run succeeds.
                var seen = Set<Int>()
                filtered = filtered.filter { seen.insert($0.workflowId).inserted }
                let now = Date()
                filtered = filtered.filter { run in
                    if run.state.isActive || run.state == .failure { return true }
                    guard run.state == .success else { return false }
                    // A success the user has never had on screen waits for them however
                    // long that takes; only once seen does it linger for the window and
                    // then drop off, so a quick green is never missed entirely.
                    guard let seenAt = options.viewedAt[run.id] else { return true }
                    return now.timeIntervalSince(seenAt) < Self.recentSuccessWindow
                }
            } else if options.latestPerWorkflowOnly {
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
                            let jobs = try? await client.jobs(owner: repo.owner, repo: repo.name,
                                                             runId: runId, accountId: accountId)
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
                    items[index].tracks = summary.tracks
                    items[index].segments = summary.segments
                    items[index].etaSeconds = eta(elapsed: Date().timeIntervalSince(items[index].run.startedAt),
                                                  progress: summary.fraction,
                                                  baseline: baselines[items[index].run.workflowId])
                }
            }

            return RepoRuns(id: repo.id, repo: repo, runs: items,
                            detectedRuns: detectedItems, error: nil)
        } catch {
            guard !isAbort(error) else { return nil }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return RepoRuns(id: repo.id, repo: repo, runs: [], detectedRuns: [], error: message)
        }
    }

    /// A request torn down by us (refresh, quit, sleep) is not a failure worth
    /// reporting; `URLError.cancelled` reads as "cancelled" and would otherwise
    /// render as an error row for every repo at once.
    nonisolated private static func isAbort(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        return false
    }

    private struct ProgressSummary {
        let fraction: Double
        let done: Int
        let total: Int
        let currentStep: String?
        let tracks: [RunTrack]
        let segments: [ProgressSegment]
    }

    /// Averages per-job completion, using step counts to smooth out long-running jobs.
    /// Every job that is still moving also gets its own track so parallel jobs can
    /// be rendered as separate progress bars, split into one cell per step.
    nonisolated private static func progressSummary(for jobs: [GHJob]) -> ProgressSummary {
        var accumulated = 0.0
        var done = 0
        var currentStep: String?
        var tracks: [RunTrack] = []
        // Run-level fallback bar: one cell per job of the run.
        let runSegments = jobs.map {
            ProgressSegment(id: $0.id, state: RunState.from(status: $0.status, conclusion: $0.conclusion))
        }
        // Only qualify captions when the run really is fanning out.
        let liveJobs = jobs.filter { $0.status != "completed" }.count

        for job in jobs {
            let state = RunState.from(status: job.status, conclusion: job.conclusion)
            var jobProgress: Double?
            var caption = job.name
            let jobSegments = (job.steps ?? []).map {
                ProgressSegment(id: $0.number, state: RunState.from(status: $0.status, conclusion: $0.conclusion))
            }

            switch job.status {
            case "completed":
                accumulated += 1
                done += 1
            case "in_progress":
                if let steps = job.steps, !steps.isEmpty {
                    let finished = steps.filter { $0.status == "completed" }.count
                    let fraction = Double(finished) / Double(steps.count)
                    accumulated += fraction
                    jobProgress = fraction
                    if let running = steps.first(where: { $0.status == "in_progress" }) {
                        caption = liveJobs > 1 ? "\(job.name) › \(running.name)" : running.name
                    }
                } else {
                    accumulated += 0.5
                }
            default:
                break // queued / waiting contributes nothing
            }

            guard state.isActive else { continue }
            if currentStep == nil, state == .running { currentStep = caption }
            tracks.append(RunTrack(id: job.id, caption: caption, progress: jobProgress,
                                   state: state, segments: jobSegments))
        }

        let fraction = min(1, max(0, accumulated / Double(jobs.count)))
        return ProgressSummary(fraction: fraction, done: done, total: jobs.count,
                               currentStep: currentStep, tracks: tracks, segments: runSegments)
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
