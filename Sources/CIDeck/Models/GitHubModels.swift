import Foundation
import SwiftUI

// MARK: - Raw API payloads
//
// Every field name here maps to GitHub's snake_case via
// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` (see GitHubClient).

struct GHUser: Codable, Hashable, Sendable {
    let login: String
    let avatarUrl: String?
}

struct GHCommit: Codable, Hashable, Sendable {
    let message: String?
}

struct GHWorkflow: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let path: String
    let state: String

    /// `.github/workflows/deploy.yml` -> `deploy.yml`
    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var isActive: Bool { state == "active" }
}

struct GHWorkflowList: Codable, Sendable {
    let totalCount: Int
    let workflows: [GHWorkflow]
}

struct GHRun: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String?
    let workflowId: Int
    let runNumber: Int
    let runAttempt: Int?
    let event: String
    let status: String?
    let conclusion: String?
    let headBranch: String?
    let headSha: String
    let htmlUrl: String
    let createdAt: Date
    let updatedAt: Date
    let runStartedAt: Date?
    let actor: GHUser?
    let headCommit: GHCommit?
}

struct GHRunList: Codable, Sendable {
    let totalCount: Int
    let workflowRuns: [GHRun]
}

struct GHStep: Codable, Hashable, Sendable {
    let name: String
    let status: String
    let conclusion: String?
    let number: Int
}

struct GHJob: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    let steps: [GHStep]?
}

struct GHJobList: Codable, Sendable {
    let totalCount: Int
    let jobs: [GHJob]
}

// MARK: - Derived state

/// Normalised lifecycle of a run, collapsing GitHub's `status` + `conclusion` pair.
enum RunState: String, Sendable {
    case queued
    case waiting      // waiting on a deployment approval / environment gate
    case running
    case success
    case failure
    case cancelled
    case skipped
    case neutral

    var isActive: Bool {
        self == .queued || self == .running || self == .waiting
    }

    var symbol: String {
        switch self {
        case .queued:    return "clock"
        case .waiting:   return "pause.circle"
        case .running:   return "arrow.triangle.2.circlepath"
        case .success:   return "checkmark.circle.fill"
        case .failure:   return "xmark.octagon.fill"
        case .cancelled: return "slash.circle"
        case .skipped:   return "minus.circle"
        case .neutral:   return "circle"
        }
    }

    var tint: Color {
        switch self {
        case .queued, .waiting: return .orange
        case .running:          return .blue
        case .success:          return .green
        case .failure:          return .red
        case .cancelled:        return .secondary
        case .skipped:          return .secondary
        case .neutral:          return .secondary
        }
    }

    var label: String {
        switch self {
        case .queued:    return "Queued"
        case .waiting:   return "Waiting"
        case .running:   return "Running"
        case .success:   return "Success"
        case .failure:   return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped:   return "Skipped"
        case .neutral:   return "Neutral"
        }
    }

    static func from(status: String?, conclusion: String?) -> RunState {
        // A completed run is described by its conclusion; anything else by its status.
        if let conclusion {
            switch conclusion {
            case "success":                       return .success
            case "failure", "timed_out",
                 "startup_failure":               return .failure
            case "cancelled":                     return .cancelled
            case "skipped":                       return .skipped
            case "action_required":               return .waiting
            default:                              return .neutral
            }
        }
        switch status {
        case "in_progress":                       return .running
        case "queued", "requested", "pending":    return .queued
        case "waiting":                           return .waiting
        default:                                  return .queued
        }
    }
}

extension GHRun {
    var state: RunState { RunState.from(status: status, conclusion: conclusion) }

    /// When the run actually began executing (falls back to creation time for queued runs).
    var startedAt: Date { runStartedAt ?? createdAt }

    /// Wall-clock duration for finished runs; `nil` while still active.
    var finishedDuration: TimeInterval? {
        guard !state.isActive else { return nil }
        return max(0, updatedAt.timeIntervalSince(startedAt))
    }

    var shortSha: String { String(headSha.prefix(7)) }

    var commitTitle: String {
        guard let message = headCommit?.message, !message.isEmpty else { return shortSha }
        return message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? shortSha
    }
}

// MARK: - View models

/// One run as shown in the popover, enriched with job-level progress.
struct RunItem: Identifiable, Hashable, Sendable {
    let run: GHRun
    var workflowName: String
    /// 0...1 for active runs, `nil` when jobs could not be fetched.
    var progress: Double?
    var jobsDone: Int?
    var jobsTotal: Int?
    /// Name of the step currently executing, if any.
    var currentStep: String?
    /// Rough remaining seconds, derived from previous successful runs of the same workflow.
    var etaSeconds: TimeInterval?
    /// When this snapshot was taken, so the ETA can keep counting down between polls.
    var fetchedAt: Date = Date()

    var id: Int { run.id }
    var state: RunState { run.state }
}

/// Per-repository slice of the popover list.
struct RepoRuns: Identifiable, Sendable {
    let id: String          // "owner/name"
    var repo: RepoConfig
    var runs: [RunItem]
    var error: String?

    var hasActive: Bool { runs.contains { $0.state.isActive } }
}

/// What the menu bar icon should communicate at a glance.
enum AggregateStatus: Equatable, Sendable {
    case needsSetup
    case error
    case running(Int)
    case failure(Int)
    case success
    case idle

    var symbol: String {
        switch self {
        case .needsSetup:  return "gearshape"
        case .error:       return "exclamationmark.triangle.fill"
        case .running:     return "arrow.triangle.2.circlepath"
        case .failure:     return "xmark.octagon.fill"
        case .success:     return "checkmark.circle"
        case .idle:        return "circle.dashed"
        }
    }

    var badge: String? {
        switch self {
        case .running(let n): return n > 1 ? "\(n)" : nil
        case .failure(let n): return n > 1 ? "\(n)" : nil
        default:              return nil
        }
    }

    var tint: Color {
        switch self {
        case .needsSetup, .idle: return .secondary
        case .error:             return .orange
        case .running:           return .blue
        case .failure:           return .red
        case .success:           return .green
        }
    }
}
