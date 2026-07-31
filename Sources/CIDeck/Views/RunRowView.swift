import AppKit
import SwiftUI

/// A single workflow run: status, identity, and live progress when it is running.
@MainActor
struct RunRowView: View {
    let item: RunItem
    /// Reference time for elapsed/relative labels; ticks once a second for active runs.
    var now: Date = Date()

    @State private var isHovering = false

    private var run: GHRun { item.run }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                StatusIcon(state: item.state)
                    .frame(width: 15)

                Text(item.workflowName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(timingText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

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

            if item.state.isActive {
                VStack(alignment: .leading, spacing: 3) {
                    RunProgressBar(value: item.progress, tint: item.state.tint)
                    Text(progressCaption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 22)
                .padding(.top, 1)
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
            Button("Mở trong GitHub") { open() }
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.htmlUrl, forType: .string)
            }
            Button("Copy commit SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.headSha, forType: .string)
            }
        }
        .help("#\(run.runNumber) · \(run.shortSha) · \(item.state.label)")
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

    private var progressCaption: String {
        var parts: [String] = []
        if let done = item.jobsDone, let total = item.jobsTotal {
            parts.append("\(done)/\(total) jobs")
        } else if item.state == .queued {
            parts.append("Đang chờ runner")
        }
        if let step = item.currentStep {
            parts.append(Fmt.clip(step, max: 38))
        }
        if let eta = item.etaSeconds {
            // The estimate was made at fetch time; keep it counting down until the next poll.
            let remaining = eta - now.timeIntervalSince(item.fetchedAt)
            if remaining > 5 {
                parts.append("≈ còn \(Fmt.duration(remaining))")
            }
        }
        return parts.isEmpty ? item.state.label : parts.joined(separator: " · ")
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

    var body: some View {
        if item.state.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RunRowView(item: item, now: context.date)
            }
        } else {
            RunRowView(item: item)
        }
    }
}
