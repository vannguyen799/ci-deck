import Foundation
import SwiftUI

/// Runtime switches for the documentation build.
///
/// `CIDECK_DEMO=1` replaces GitHub with the fixture in `DemoData`, so the app can
/// be launched — and screenshotted — without a token, a network, or a real repo.
enum DemoMode {
    static let isEnabled = ProcessInfo.processInfo.environment["CIDECK_DEMO"] == "1"

    /// Directory the screenshot runner writes PNGs into, then quits.
    static let screenshotDirectory = ProcessInfo.processInfo.environment["CIDECK_SHOTS"]

    /// The real popover sizes itself to the screen; the docs want one fixed frame.
    static let popoverHeight: CGFloat = 600
}

/// A believable snapshot of three repositories mid-deploy.
///
/// Every date is derived from `epoch`, captured once at launch, so elapsed timers
/// keep counting up between polls instead of resetting on every fake refresh.
enum DemoData {
    static let epoch = Date()

    private static func ago(_ seconds: TimeInterval) -> Date {
        epoch.addingTimeInterval(-seconds)
    }

    // MARK: - Settings fixture

    static let accounts: [AccountConfig] = [
        AccountConfig(id: "demo-org", login: "octocat", label: "",
                      owners: ["octolab"], fineGrained: true),
        AccountConfig(id: "demo-personal", login: "octocat", label: "",
                      owners: ["octocat"], fineGrained: false),
    ]

    static let repos: [RepoConfig] = [
        RepoConfig(owner: "octolab", name: "payments-api",
                   branchFilter: "main", accountId: "demo-org"),
        RepoConfig(owner: "octolab", name: "web-storefront",
                   accountId: "demo-org"),
        RepoConfig(owner: "octocat", name: "ml-pipeline",
                   watchedWorkflowIds: [301, 302], accountId: "demo-personal"),
    ]

    static let workflowCatalog: [String: [GHWorkflow]] = [
        "octolab/payments-api": [
            GHWorkflow(id: 101, name: "Deploy Production", path: ".github/workflows/deploy.yml", state: "active"),
            GHWorkflow(id: 102, name: "Unit Tests", path: ".github/workflows/test.yml", state: "active"),
            GHWorkflow(id: 103, name: "Lint", path: ".github/workflows/lint.yml", state: "active"),
            GHWorkflow(id: 104, name: "Security Scan", path: ".github/workflows/codeql.yml", state: "active"),
            GHWorkflow(id: 105, name: "Nightly Backup", path: ".github/workflows/backup.yml", state: "disabled_manually"),
        ],
        "octolab/web-storefront": [
            GHWorkflow(id: 201, name: "Build & Deploy", path: ".github/workflows/build.yml", state: "active"),
            GHWorkflow(id: 202, name: "E2E", path: ".github/workflows/e2e.yml", state: "active"),
            GHWorkflow(id: 203, name: "Lighthouse", path: ".github/workflows/lighthouse.yml", state: "active"),
        ],
        "octocat/ml-pipeline": [
            GHWorkflow(id: 301, name: "Train & Evaluate", path: ".github/workflows/train.yml", state: "active"),
            GHWorkflow(id: 302, name: "Publish Model", path: ".github/workflows/publish.yml", state: "active"),
            GHWorkflow(id: 303, name: "Dataset Sync", path: ".github/workflows/dataset.yml", state: "active"),
        ],
    ]

    static let discoverableRepositories: [GHRepository] = [
        GHRepository(id: 1, name: "payments-api", owner: .init(login: "octolab"), isPrivate: true, archived: false),
        GHRepository(id: 2, name: "web-storefront", owner: .init(login: "octolab"), isPrivate: true, archived: false),
        GHRepository(id: 3, name: "design-tokens", owner: .init(login: "octolab"), isPrivate: false, archived: false),
        GHRepository(id: 4, name: "infra-terraform", owner: .init(login: "octolab"), isPrivate: true, archived: false),
        GHRepository(id: 5, name: "docs-site", owner: .init(login: "octolab"), isPrivate: false, archived: false),
    ]

    static let rateLimit = RateLimitInfo(limit: 5000, remaining: 4861,
                                         reset: DemoData.epoch.addingTimeInterval(1_800))

    // MARK: - Runs fixture

    static func repoStates() -> [RepoRuns] {
        [paymentsAPI(), storefront(), mlPipeline()]
    }

    private static func paymentsAPI() -> RepoRuns {
        let deploy = RunItem(
            run: run(id: 9_310_441, workflow: 101, number: 812, event: "push",
                     branch: "main", sha: "4f21ac9e0d3b71c",
                     message: "feat(payments): retry 3DS webhooks with backoff",
                     actor: "octocat", status: "in_progress", startedAgo: 96),
            workflowName: "Deploy Production",
            progress: 0.52, jobsDone: 4, jobsTotal: 9,
            currentStep: "build › docker buildx bake",
            etaSeconds: 88,
            tracks: [
                RunTrack(id: 1, caption: "build › docker buildx bake", progress: 0.66,
                         state: .running,
                         segments: steps(done: 6, running: 1, total: 9)),
                RunTrack(id: 2, caption: "test (node 20) › jest --ci --shard 2/4", progress: 0.4,
                         state: .running,
                         segments: steps(done: 4, running: 1, total: 10)),
                RunTrack(id: 3, caption: "migrate › waiting for runner", progress: nil,
                         state: .queued, segments: []),
            ],
            segments: jobs(success: 4, running: 2, queued: 3)
        )

        let unitTests = RunItem(
            run: run(id: 9_310_402, workflow: 102, number: 1_477, event: "push",
                     branch: "main", sha: "4f21ac9e0d3b71c",
                     message: "feat(payments): retry 3DS webhooks with backoff",
                     actor: "octocat", status: "completed", conclusion: "success",
                     startedAgo: 610, duration: 123),
            workflowName: "Unit Tests")

        let scan = RunItem(
            run: run(id: 9_310_398, workflow: 104, number: 233, event: "schedule",
                     branch: "main", sha: "b70e5518af4c2d0",
                     message: "chore(deps): bump stripe-node to 16.2.0",
                     actor: "github-actions", status: "queued", startedAgo: 21),
            workflowName: "Security Scan",
            currentStep: nil,
            segments: [])

        return RepoRuns(id: "octolab/payments-api", repo: repos[0],
                        runs: [deploy, unitTests, scan],
                        detectedRuns: [deploy, unitTests, scan])
    }

    private static func storefront() -> RepoRuns {
        let e2e = RunItem(
            run: run(id: 9_309_877, workflow: 202, number: 640, event: "pull_request",
                     branch: "feat/checkout-v2", sha: "0c88ba4712fe93a",
                     message: "fix(cart): keep promo code across sessions",
                     actor: "hubot", status: "completed", conclusion: "failure",
                     startedAgo: 1_540, duration: 251),
            workflowName: "E2E")

        let build = RunItem(
            run: run(id: 9_310_455, workflow: 201, number: 2_051, event: "push",
                     branch: "feat/checkout-v2", sha: "0c88ba4712fe93a",
                     message: "fix(cart): keep promo code across sessions",
                     actor: "hubot", status: "in_progress", startedAgo: 34),
            workflowName: "Build & Deploy",
            progress: 0.22, jobsDone: 1, jobsTotal: 5,
            currentStep: "npm ci",
            etaSeconds: 140,
            tracks: [
                RunTrack(id: 4, caption: "npm ci", progress: 0.25, state: .running,
                         segments: steps(done: 2, running: 1, total: 8)),
            ],
            segments: jobs(success: 1, running: 1, queued: 3))

        let lighthouse = RunItem(
            run: run(id: 9_309_612, workflow: 203, number: 188, event: "workflow_dispatch",
                     branch: "main", sha: "ee1904cb52d7f88",
                     message: "perf(images): serve AVIF above the fold",
                     actor: "octocat", status: "completed", conclusion: "success",
                     startedAgo: 3_320, duration: 96),
            workflowName: "Lighthouse")

        return RepoRuns(id: "octolab/web-storefront", repo: repos[1],
                        runs: [build, e2e, lighthouse],
                        detectedRuns: [build, e2e, lighthouse])
    }

    private static func mlPipeline() -> RepoRuns {
        let train = RunItem(
            run: run(id: 9_308_120, workflow: 301, number: 74, event: "schedule",
                     branch: "main", sha: "1a2ffc60b9e4d55",
                     message: "data: refresh feature store snapshot",
                     actor: "github-actions", status: "completed", conclusion: "success",
                     startedAgo: 5_100, duration: 2_640),
            workflowName: "Train & Evaluate")

        return RepoRuns(id: "octocat/ml-pipeline", repo: repos[2],
                        runs: [train], detectedRuns: [train])
    }

    // MARK: - Builders

    private static func run(id: Int, workflow: Int, number: Int, event: String,
                            branch: String, sha: String, message: String, actor: String,
                            status: String, conclusion: String? = nil,
                            startedAgo: TimeInterval, duration: TimeInterval = 0) -> GHRun {
        let started = ago(startedAgo)
        return GHRun(id: id, name: nil, workflowId: workflow, runNumber: number,
                     runAttempt: 1, event: event, status: status, conclusion: conclusion,
                     headBranch: branch, headSha: sha,
                     htmlUrl: "https://github.com/octolab/demo/actions/runs/\(id)",
                     createdAt: started.addingTimeInterval(-4),
                     updatedAt: started.addingTimeInterval(duration),
                     runStartedAt: started,
                     actor: GHUser(login: actor, avatarUrl: nil),
                     headCommit: GHCommit(message: message))
    }

    /// One cell per step of a job: finished, the one executing, then the rest queued.
    private static func steps(done: Int, running: Int, total: Int) -> [ProgressSegment] {
        (1...total).map { index in
            if index <= done { return ProgressSegment(id: index, state: .success) }
            if index <= done + running { return ProgressSegment(id: index, state: .running) }
            return ProgressSegment(id: index, state: .queued)
        }
    }

    /// Run-level fallback bar: one cell per job.
    private static func jobs(success: Int, running: Int, queued: Int) -> [ProgressSegment] {
        steps(done: success, running: running, total: success + running + queued)
    }
}
