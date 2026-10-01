import AppKit
import SwiftUI

/// A single workflow run: status, identity, and live progress when it is running.
@MainActor
struct RunRowView: View {
    let item: RunItem
    /// Owning repository, needed to address the re-run endpoint.
    let repo: RepoConfig
    /// Reference time for elapsed/relative labels; ticks once a second for active runs.
    var now: Date = Date()

    @EnvironmentObject private var store: RunsStore
    @State private var isHovering = false

    private var run: GHRun { item.run }
    private var isRerunning: Bool { store.rerunningIds.contains(run.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                StatusIcon(state: item.state)
                    .frame(width: 15)

                Text(item.workflowName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 6)

                retryButton

                Text(timingText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // An in-flight run is reduced to progress bars — one per live job, so
            // two parallel nodes read as two bars. Everything else is in the tooltip.
            if item.state.isActive {
                VStack(alignment: .leading, spacing: 7) {
                    if item.tracks.isEmpty {
                        progressTrack(caption: fallbackCaption,
                                      value: item.progress,
                                      segments: item.segments,
                                      tint: item.state.tint)
                    } else {
                        ForEach(item.tracks) { track in
                            progressTrack(caption: track.caption,
                                          value: track.progress,
                                          segments: track.segments,
                                          tint: track.state.tint)
                        }
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 1)
            } else {
                HStack(spacing: 4) {
                    Chip(text: run.headBranch ?? "—", systemImage: "arrow.triangle.branch")
                    Chip(text: run.event)
                    Text(Fmt.clip(run.commitTitle, max: 34))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let login = run.actor?.login {
                        Text("@\(login)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { open() }
        .contextMenu {
            if item.canRerun {
                Button("Re-run workflow") { store.rerun(item, in: repo) }
                if item.canRerunFailedJobs {
                    Button("Re-run failed jobs") { store.rerun(item, in: repo, failedJobsOnly: true) }
                }
                Divider()
            }
            Button("Open in GitHub") { open() }
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.htmlUrl, forType: .string)
            }
            Button("Copy commit SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.headSha, forType: .string)
            }
        }
        .help(tooltip)
    }

    /// Only shown on hover, so a resting row stays as quiet as it was before.
    /// The slot keeps its width either way to avoid the timing label jumping.
    @ViewBuilder
    private var retryButton: some View {
        if item.canRerun {
            Group {
                if isRerunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 18, height: 18)
                } else {
                    IconButton(systemImage: "arrow.clockwise",
                               help: item.canRerunFailedJobs
                                   ? "Re-run (hold Option: failed jobs only)"
                                   : "Re-run workflow",
                               size: 18) {
                        store.rerun(item, in: repo,
                                    failedJobsOnly: item.canRerunFailedJobs && NSEvent.modifierFlags.contains(.option))
                    }
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                }
            }
            .frame(width: 18, height: 18)
        }
    }

    /// Elapsed time for active runs; total duration + age for finished ones.
    private var timingText: String {
        if item.state.isActive {
            return Fmt.duration(now.timeIntervalSince(run.startedAt))
        }
        if let duration = run.finishedDuration {
            return "\(Fmt.duration(duration)) · \(Fmt.relative(run.updatedAt, now: now))"
        }
        return Fmt.relative(run.updatedAt, now: now)
    }

    /// Name of what is running, above its bar.
    private func progressTrack(caption: String, value: Double?,
                               segments: [ProgressSegment], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Fmt.clip(caption, max: 42))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            RunProgressBar(value: value, segments: segments, tint: tint)
        }
    }

    /// Used before the first job payload arrives, when there is nothing to name yet.
    private var fallbackCaption: String {
        if let step = item.currentStep { return step }
        return item.state == .queued ? "Waiting for runner" : item.state.label
    }

    /// Jobs, steps and the ETA moved off the row; they stay one hover away.
    private var tooltip: String {
        var parts = ["#\(run.runNumber)", run.shortSha, item.state.label]
        if let branch = run.headBranch { parts.append(branch) }
        if let done = item.jobsDone, let total = item.jobsTotal {
            parts.append("\(done)/\(total) jobs")
        }
        if let eta = item.etaSeconds {
            // The estimate was made at fetch time; keep it counting down until the next poll.
            let remaining = eta - now.timeIntervalSince(item.fetchedAt)
            if remaining > 5 { parts.append("≈ \(Fmt.duration(remaining)) left") }
        }
        return parts.joined(separator: " · ")
    }

    private func open() {
        guard let url = URL(string: run.htmlUrl) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Wraps `RunRowView` so active runs get a once-a-second elapsed timer without
/// re-rendering the whole popover.
@MainActor
struct LiveRunRowView: View {
    let item: RunItem
    let repo: RepoConfig

    var body: some View {
        if item.state.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RunRowView(item: item, repo: repo, now: context.date)
            }
        } else {
            RunRowView(item: item, repo: repo)
        }
    }
}
