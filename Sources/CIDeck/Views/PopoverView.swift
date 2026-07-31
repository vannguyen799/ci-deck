import AppKit
import SwiftUI

/// The small window shown when the menu bar icon is clicked.
@MainActor
struct PopoverView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunsStore
    @Environment(\.openWindow) private var openWindow
    @State private var collapsedRepoIds = Set<String>()

    private var visibleRepoStates: [RepoRuns] {
        store.repoStates.filter { !$0.runs.isEmpty || $0.error != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 400)
        .frame(height: popoverHeight)
    }

    /// 70% of the previously enlarged (2.5x) height, capped to the current screen.
    private var popoverHeight: CGFloat {
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

            IconButton(systemImage: "arrow.clockwise", help: "Refresh ngay") {
                store.refreshNow()
            }
            IconButton(systemImage: "gearshape", help: "Cấu hình repo & workflow") {
                openSettings()
            }
            Menu {
                Button("Cấu hình…") { openSettings() }
                Button("Refresh") { store.refreshNow() }
                Divider()
                Button("Thoát CIDeck") { NSApplication.shared.terminate(nil) }
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
                title: "Chưa kết nối GitHub",
                message: "Thêm Personal Access Token (scope actions:read) để CIDeck đọc được workflow runs.",
                actionTitle: "Mở cấu hình",
                action: { openSettings() }
            )
        } else if settings.repos.filter(\.enabled).isEmpty {
            EmptyStateView(
                systemImage: "folder.badge.plus",
                title: "Chưa chọn repo nào",
                message: "Thêm repo dạng owner/repo rồi chọn các workflow muốn theo dõi.",
                actionTitle: "Thêm repo",
                action: { openSettings() }
            )
        } else if store.repoStates.isEmpty && store.lastRefresh == nil {
            EmptyStateView(
                systemImage: "clock.arrow.circlepath",
                title: "Đang tải…",
                message: "Đang lấy workflow runs từ GitHub."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if visibleRepoStates.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle",
                title: "Không có CI/CD cần chú ý",
                message: settings.showRecentRuns
                    ? "Không có run nào khớp cấu hình hiện tại."
                    : "Các workflow gần nhất đều thành công."
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
                                    ForEach(state.runs) { item in
                                        LiveRunRowView(item: item)
                                    }
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
                Text("\(state.runs.filter { $0.state.isActive }.count) đang chạy")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture { toggleRepo(state.id) }
        .help(collapsedRepoIds.contains(state.id) ? "Mở rộng repo" : "Thu gọn repo")
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let last = store.lastRefresh {
                Text("Cập nhật \(Fmt.relative(last))")
            } else {
                Text("Chưa cập nhật")
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
