import AppKit
import SwiftUI

/// Renders the README images and quits.
///
///     CIDECK_DEMO=1 CIDECK_SHOTS=docs swift run
///
/// Each shot is hosted in a real off-screen `NSWindow` and captured with
/// `cacheDisplay`: `ImageRenderer` alone cannot draw the AppKit-backed parts of the
/// UI (scroll views, tab views, menus), and a screen capture would need the
/// screen-recording permission.
@MainActor
enum ScreenshotRunner {
    static func runIfNeeded() {
        guard DemoMode.isEnabled, let directory = DemoMode.screenshotDirectory else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let settings = AppSettings()
        let store = RunsStore(settings: settings)

        Task {
            await store.refresh()

            let popover = PopoverView()
                .environmentObject(settings)
                .environmentObject(store)
                .frame(width: 400, height: DemoMode.popoverHeight)
            let tabs: [(String, AnyView, CGFloat)] = [
                ("accounts", AnyView(SettingsTabs.account()), 470),
                ("repositories", AnyView(SettingsTabs.repositories(select: "octolab/payments-api")), 470),
                ("general", AnyView(SettingsTabs.general()), 610),
            ]

            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                await capture(card(popover, scheme: scheme),
                              size: CGSize(width: 456, height: DemoMode.popoverHeight + 56),
                              scheme: scheme,
                              to: folder.appendingPathComponent("popover-\(suffix).png"))
                for (name, tab, height) in tabs {
                    let view = tab
                        .environmentObject(settings)
                        .environmentObject(store)
                    await capture(card(view, scheme: scheme),
                                  size: CGSize(width: 680 + 56, height: height + 56),
                                  scheme: scheme,
                                  // The settings shots are the widest; 1.5× keeps them
                                  // crisp in the README at a third of the file size.
                                  maxPixelWidth: 1104,
                                  to: folder.appendingPathComponent("settings-\(name)-\(suffix).png"))
                }
            }

            await capture(card(MenuBarGallery(), scheme: .dark),
                          size: CGSize(width: 664, height: 152),
                          scheme: .dark,
                          to: folder.appendingPathComponent("menubar-states.png"))

            NSApp.terminate(nil)
        }
    }

    // MARK: - Capture

    private static func capture<V: View>(_ view: V, size: CGSize, scheme: ColorScheme,
                                         maxPixelWidth: Int? = nil, to url: URL) async {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.isOpaque = true
        window.backgroundColor = scheme == .dark ? .black : .white
        // Far enough off the visible desktop that nothing flashes, but still a real
        // on-screen window as far as AppKit's display machinery is concerned.
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()

        // Give SwiftUI a few runloop turns: lists, tab views and the progress bars'
        // `onAppear` state all settle asynchronously.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            NSLog("CIDeck: no bitmap rep for \(url.lastPathComponent)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let output = maxPixelWidth.flatMap { downscale(rep, toWidth: $0) } ?? rep
        guard let data = output.representation(using: .png, properties: [:]) else {
            NSLog("CIDeck: could not encode \(url.lastPathComponent)")
            return
        }
        try? data.write(to: url)
        NSLog("CIDeck: wrote \(url.path) (\(output.pixelsWide)×\(output.pixelsHigh))")
        window.orderOut(nil)
    }

    /// Resamples a captured bitmap, for shots whose 2× retina size buys the README
    /// nothing but megabytes.
    private static func downscale(_ rep: NSBitmapImageRep, toWidth width: Int) -> NSBitmapImageRep? {
        guard rep.pixelsWide > width else { return rep }
        let height = Int((Double(rep.pixelsHigh) * Double(width) / Double(rep.pixelsWide)).rounded())
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        target.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        return target
    }

    /// Drops the view on a tinted backdrop with a soft border, so the PNG reads as
    /// a floating window instead of a flat crop.
    private static func card<V: View>(_ content: V, scheme: ColorScheme) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.18 : 0.12), lineWidth: 1)
            )
            .padding(28)
            .background(backdrop(scheme))
            .environment(\.colorScheme, scheme)
    }

    private static func backdrop(_ scheme: ColorScheme) -> some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.10, green: 0.12, blue: 0.17), Color(red: 0.05, green: 0.06, blue: 0.09)]
                : [Color(red: 0.89, green: 0.92, blue: 0.98), Color(red: 0.97, green: 0.96, blue: 0.93)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Every menu bar state side by side, for the README's status legend.
@MainActor
private struct MenuBarGallery: View {
    private let states: [(AggregateStatus, String)] = [
        (.running(3), "3 runs in progress"),
        (.failure(2), "2 workflows red"),
        (.success, "All green"),
        (.idle, "Nothing new"),
        (.error, "Token / network error"),
        (.needsSetup, "Not configured"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: 10) {
                    MenuBarLabel(status: entry.0)
                        .frame(height: 18)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(entry.1)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 76)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.16))
    }
}
