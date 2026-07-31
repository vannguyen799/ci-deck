import AppKit
import SwiftUI

/// The small window shown when the menu bar icon is clicked.
@MainActor
struct PopoverView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 400)
        .frame(maxHeight: 540)
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
        } else if store.repoStates.isEmpty {
            EmptyStateView(
                systemImage: "clock.arrow.circlepath",
                title: "Đang tải…",
                message: "Đang lấy workflow runs từ GitHub."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.repoStates) { state in
                        Section {
                            if let error = state.error {
                                errorRow(error)
                            } else if state.runs.isEmpty {
                                Text("Không có run nào khớp bộ lọc.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(state.runs) { item in
                                    LiveRunRowView(item: item)
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
