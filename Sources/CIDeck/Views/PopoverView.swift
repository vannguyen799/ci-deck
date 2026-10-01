import AppKit
import SwiftUI

/// The small window shown when the menu bar icon is clicked.
@MainActor
struct PopoverView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunsStore
    @Environment(\.openWindow) private var openWindow
    @State private var collapsedRepoIds = Set<String>()
    /// "owner/name@branch" of every branch box the user has folded away.
    @State private var collapsedBranchIds = Set<String>()

    private var visibleRepoStates: [RepoRuns] {
        store.repoStates.filter { !$0.runs.isEmpty || $0.error != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = store.actionError {
                Divider()
                actionErrorBanner(error)
            }
            Divider()
            footer
        }
        .frame(width: 400)
        .frame(height: popoverHeight)
        .onAppear { store.popoverDidAppear() }
        .onDisappear { store.popoverDidDisappear() }
    }

    /// 70% of the previously enlarged (2.5x) height, capped to the current screen.
    private var popoverHeight: CGFloat {
        if DemoMode.isEnabled { return DemoMode.popoverHeight }
        let desired: CGFloat = 540 * 2.5 * 0.7
        let available = (NSScreen.main?.visibleFrame.height ?? desired) - 24
        return min(desired, max(540, available))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
            Text("CI/CD")
                .font(.system(size: 13, weight: .semibold))

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }

            Spacer()

            IconButton(systemImage: "arrow.clockwise", help: "Refresh now") {
                store.refreshNow()
            }
            IconButton(systemImage: "gearshape", help: "Configure repositories & workflows") {
                openSettings()
            }
            Menu {
                Button("Settings…") { openSettings() }
                Button("Refresh") { store.refreshNow() }
                Divider()
                Button("Quit CIDeck") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !settings.hasToken {
            EmptyStateView(
                systemImage: "key.horizontal",
                title: "GitHub not connected",
                message: "Add a Personal Access Token with Actions read permission (plus write to re-run workflows) so CIDeck can load workflow runs.",
                actionTitle: "Open Settings",
                action: { openSettings() }
            )
        } else if settings.repos.filter(\.enabled).isEmpty {
            EmptyStateView(
                systemImage: "folder.badge.plus",
                title: "No repositories selected",
                message: "Add a repository as owner/repo, then choose workflows to monitor.",
                actionTitle: "Add Repository",
                action: { openSettings() }
            )
        } else if store.repoStates.isEmpty && store.lastRefresh == nil {
            EmptyStateView(
                systemImage: "clock.arrow.circlepath",
                title: "Loading…",
                message: "Loading workflow runs from GitHub."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if visibleRepoStates.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle",
                title: "No CI/CD needs attention",
                message: settings.showRecentRuns
                    ? "No run matches the current configuration."
                    : "The latest workflows all succeeded and were seen more than 5 minutes ago."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(visibleRepoStates) { state in
                        Section {
                            if !collapsedRepoIds.contains(state.id) {
                                if let error = state.error {
                                    errorRow(error)
                                } else {
                                    repoBody(state)
                                }
                            }
                        } header: {
                            repoHeader(state)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
        }
    }

    /// A single branch needs no box around it; several get one apiece so each can
    /// be folded away without hiding the rest of the repository.
    @ViewBuilder
    private func repoBody(_ state: RepoRuns) -> some View {
        let groups = state.branchGroups
        if groups.count > 1 {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    branchHeader(group)
                    if !collapsedBranchIds.contains(group.id) {
                        ForEach(group.runs) { item in
                            LiveRunRowView(item: item, repo: state.repo)
                        }
                    }
                }
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
                .padding(.bottom, 3)
            }
        } else {
            ForEach(state.runs) { item in
                LiveRunRowView(item: item, repo: state.repo)
            }
        }
    }

    private func branchHeader(_ group: BranchRuns) -> some View {
        let isCollapsed = collapsedBranchIds.contains(group.id)
        return HStack(spacing: 5) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 9)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(group.branch)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if group.activeCount > 0 {
                Text("\(group.activeCount) running")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            } else if group.hasFailure {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            }
            // Collapsed boxes still say how much they are hiding.
            if isCollapsed {
                Text("\(group.runs.count)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { toggleBranch(group.id) }
        .help(isCollapsed ? "Expand branch" : "Collapse branch")
    }

    private func toggleBranch(_ id: String) {
        if collapsedBranchIds.contains(id) {
            collapsedBranchIds.remove(id)
        } else {
            collapsedBranchIds.insert(id)
        }
    }

    private func repoHeader(_ state: RepoRuns) -> some View {
        HStack(spacing: 5) {
            Image(systemName: collapsedRepoIds.contains(state.id) ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 9)
            Image(systemName: "shippingbox")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(state.repo.slug)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if !state.repo.branchFilter.isEmpty {
                Chip(text: state.repo.branchFilter, systemImage: "arrow.triangle.branch")
            }
            Spacer()
            if state.hasActive {
                Text("\(state.runs.filter { $0.state.isActive }.count) running")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture { toggleRepo(state.id) }
        .help(collapsedRepoIds.contains(state.id) ? "Expand repository" : "Collapse repository")
    }

    private func toggleRepo(_ id: String) {
        if collapsedRepoIds.contains(id) {
            collapsedRepoIds.remove(id)
        } else {
            collapsedRepoIds.insert(id)
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Re-run failures land here rather than in the per-repo error slot, which
    /// belongs to the polling loop.
    private func actionErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            IconButton(systemImage: "xmark", help: "Dismiss", size: 18) {
                store.actionError = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let last = store.lastRefresh {
                Text("Updated \(Fmt.relative(last))")
            } else {
                Text("Not updated yet")
            }

            Spacer()

            if let remaining = store.rateLimit.remaining, let limit = store.rateLimit.limit {
                Text("API \(remaining)/\(limit)")
                    .monospacedDigit()
                    .foregroundStyle(remaining < 100 ? Color.orange : Color.secondary)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func openSettings() {
        // The menu bar panel steals key window status; close it so the settings
        // window can come forward.
        NSApplication.shared.keyWindow?.close()
        openWindow(id: SettingsWindow.id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
