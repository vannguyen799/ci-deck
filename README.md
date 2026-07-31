# CIDeck

Menu bar app cho macOS để theo dõi GitHub Actions. Click icon ở góc phải trên → popover nhỏ hiển thị danh sách CI/CD runs kèm tiến trình đang chạy.

```
┌─────────────────────────────────────────────┐
│ ⚡ CI/CD                    ⟳   ⚙   ⋯       │
├─────────────────────────────────────────────┤
│ 📦 vt/zynalgo-prod            2 đang chạy   │
│  ⟳  Deploy Production            01:24      │
│     ⑂ main  push  fix: cache header  @vt    │
│     ▓▓▓▓▓▓▓░░░░  4/9 jobs · build › npm ci  │
│                          · ≈ còn 1m 20s     │
│  ✓  Unit Tests            2m 03s · 8m ago   │
│     ⑂ main  push  chore: bump deps   @vt    │
│ 📦 vt/storefront                            │
│  ✕  E2E                   4m 11s · 1h ago   │
├─────────────────────────────────────────────┤
│ Cập nhật 6s ago                 API 4812/5000│
└─────────────────────────────────────────────┘
```

## Có gì

- **Menu bar extra** (`LSUIElement`, không chiếm Dock). Icon đổi theo trạng thái tổng: đang chạy / đỏ / xanh, kèm badge số lượng.
- **Cấu hình repo**: thêm `owner/repo` (dán URL GitHub cũng được), bật/tắt từng repo, lọc theo branch.
- **Chọn workflow**: tick từng workflow muốn theo dõi trong mỗi repo; không tick gì = theo dõi tất cả.
- **Tiến trình thật**: với run đang chạy, app gọi endpoint jobs để tính `x/y jobs`, step hiện tại, và ETA suy ra từ thời lượng các lần chạy thành công trước đó.
- **Polling thích ứng**: 10s khi có run đang chạy, 60s khi rảnh (chỉnh được). Dùng ETag nên phần lớn request trả `304` và **không bị tính vào rate limit**. Tự dừng khi máy sleep, refresh ngay khi wake. Tự lùi về 120s khi rate limit còn dưới 100.
- **Token trong Keychain**, không ghi ra file cấu hình.
- Click một run → mở thẳng trang run trên GitHub. Chuột phải → copy link / SHA.

## Yêu cầu

- macOS 13 Ventura trở lên (dùng `MenuBarExtra`).
- Xcode hoặc Xcode Command Line Tools (`xcode-select --install`).

## Build

```bash
cd CIDeck
chmod +x scripts/build-app.sh
./scripts/build-app.sh            # → build/CIDeck.app
./scripts/build-app.sh --install  # → /Applications/CIDeck.app
open build/CIDeck.app
```

Dev nhanh (không đóng bundle, vẫn chạy được trên menu bar nhưng không có "Khởi động cùng macOS"):

```bash
swift run
```

App ký ad-hoc, nên lần đầu mở có thể phải vào **System Settings → Privacy & Security → Open Anyway**.

## Cấu hình

1. Mở app → click icon trên menu bar → ⚙.
2. Tab **GitHub**: dán Personal Access Token, bấm *Lưu & kiểm tra*.
   - Fine-grained token: chọn repo cần theo dõi, quyền **Actions: Read-only** + **Metadata: Read-only**.
   - Classic token: scope `repo` (repo private) hoặc `public_repo` (repo public).
3. Tab **Repositories**: gõ `owner/repo` → *Thêm*. Chọn repo trong danh sách để tick các workflow và đặt branch filter.
4. Tab **Chung**: tần suất poll, số run hiển thị, khởi động cùng macOS.

## Cấu trúc

```
Sources/CIDeck/
  CIDeckApp.swift            @main — MenuBarExtra + Window cấu hình
  Models/
    GitHubModels.swift       payload API + RunState/RunItem/AggregateStatus
    AppSettings.swift        repo config, interval, persist UserDefaults
  Services/
    Keychain.swift           lưu/đọc/xoá token
    GitHubClient.swift       actor, URLSession + ETag cache + rate limit
    RunsStore.swift          vòng poll thích ứng, tính progress & ETA
  Views/
    PopoverView.swift        modal nhỏ khi click icon
    RunRowView.swift         một run + progress bar
    SettingsView.swift       3 tab cấu hình
    MenuBarLabel.swift       icon trên menu bar
    Components.swift         StatusIcon, RunProgressBar, Chip, …
  Utils/Formatters.swift
Resources/Info.plist         LSUIElement = true
scripts/build-app.sh
```

## API GitHub được dùng

| Mục đích | Endpoint | Tần suất |
|---|---|---|
| Danh sách workflow (tên + picker) | `GET /repos/{o}/{r}/actions/workflows` | 1 lần/repo, cache |
| Danh sách run | `GET /repos/{o}/{r}/actions/runs` | mỗi lần poll, có ETag |
| Jobs để tính tiến trình | `GET /repos/{o}/{r}/actions/runs/{id}/jobs` | chỉ cho run đang chạy |
| Kiểm tra token | `GET /user` | khi bấm *Lưu & kiểm tra* |

Ước tính chi phí: 3 repo, 10s/lần, tất cả đều idle → ~1.080 request/giờ, gần như toàn bộ là `304` (miễn phí). Hạn mức token cá nhân là 5.000 request/giờ.

## Giới hạn đã biết

- ETA là ước lượng: lấy median thời lượng của tối đa 5 run thành công gần nhất cùng workflow, hoặc ngoại suy từ % jobs đã xong khi đã chạy được >15%.
- Chỉ đọc, không có nút re-run/cancel (token chỉ cần quyền read).
- macOS vẽ icon menu bar dạng template nên màu có thể bị bỏ qua; mỗi trạng thái vì vậy dùng một SF Symbol có hình dạng khác nhau.
