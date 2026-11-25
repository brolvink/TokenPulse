import AppKit
import Combine
import SwiftUI
import OSLog

@MainActor
public final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: UsageMonitorViewModel
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitor: Any?
    private let logger = Logger(subsystem: "com.bramrolvink.TokenPulse", category: "MenuBar")

    public init(viewModel: UsageMonitorViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        statusItem.autosaveName = "TokenPulse"
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                viewModel: viewModel,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
        }

        viewModel.$snapshots
            .combineLatest(viewModel.$activeAlerts, viewModel.$preferences)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots, alerts, prefs in
                self?.updateStatusButton(snapshots: snapshots, alerts: alerts, preferences: prefs)
            }
            .store(in: &cancellables)

        updateStatusButton(snapshots: viewModel.snapshots, alerts: viewModel.activeAlerts, preferences: viewModel.preferences)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            let frame = button.window?.frame ?? .zero
            self.logger.notice("Status item visible=\(self.statusItem.isVisible) windowVisible=\(button.window?.isVisible ?? false) screen=\(button.window?.screen != nil) frame=\(String(describing: frame), privacy: .public) image=\(button.image != nil)")
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startEventMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        stopEventMonitor()
    }

    public func popoverDidShow(_ notification: Notification) {
        guard let button = statusItem.button,
              let anchorWindow = button.window,
              let screen = anchorWindow.screen,
              let popoverWindow = popover.contentViewController?.view.window else { return }

        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = popoverWindow.frame
        let top = min(anchor.minY - 4, screen.visibleFrame.maxY)
        let bottom = top - frame.height
        if frame.maxY < top - 8, bottom >= screen.visibleFrame.minY {
            popoverWindow.setFrameOrigin(NSPoint(x: frame.minX, y: bottom))
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        stopEventMonitor()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover.isShown == true {
                self?.closePopover()
            }
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    public func openSettings() {
        closePopover()
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: controller)
        window.title = "TokenPulse Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusButton(
        snapshots: [ProviderSnapshot],
        alerts: [SurplusAlert],
        preferences: AppPreferences
    ) {
        guard let button = statusItem.button else { return }

        let providers = AIProviderKind.allCases.map { kind in
            snapshots.first { $0.provider == kind }
        }
        let windows = providers.map { $0?.menuBarWindow }
        let opportunity = alerts.first(where: \.isSpendingOpportunity)
        button.image = renderRing(
            providers: providers,
            opportunity: opportunity?.provider,
            showProgress: preferences.showMiniBarsInMenuBar,
            appearance: button.effectiveAppearance
        )
        button.title = preferences.showPercentagesInMenuBar && !snapshots.isEmpty
            ? " " + windows.map { $0.map { Formatters.formatPercent($0.remainingPercent) } ?? "—" }.joined(separator: " · ")
            : ""
        button.toolTip = buildTooltip(snapshots: snapshots, alerts: alerts)
        button.setAccessibilityLabel("TokenPulse. " + (button.toolTip ?? ""))
    }

    private func renderRing(
        providers: [ProviderSnapshot?],
        opportunity: AIProviderKind?,
        showProgress: Bool,
        appearance: NSAppearance
    ) -> NSImage {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = dark
            ? [0xFFAC91, 0x67DED7, 0x9FAEFF]
            : [0xA24230, 0x087975, 0x4E59AB]
        let colors = palette.map { rgb in
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        let center = NSPoint(x: 10, y: 10)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            for (index, provider) in providers.enumerated() {
                let start = CGFloat(137 - index * 120)
                let color = colors[index]
                for (window, radius, thickness) in [
                    (provider?.shortWindow, CGFloat(4.5), CGFloat(1.55)),
                    (provider?.weeklyWindow, CGFloat(7.65), CGFloat(1.72))
                ] {
                    guard let window else {
                        Self.strokeArc(center: center, radius: radius, start: start - 40,
                                       sweep: 13, thickness: 1.3, color: color.withAlphaComponent(0.32))
                        continue
                    }
                    Self.strokeArc(center: center, radius: radius, start: start,
                                   sweep: 94, thickness: 1.55, color: color.withAlphaComponent(0.27))
                    if showProgress, window.remainingPercent > 0 {
                        let alpha: CGFloat = window.isEstimated || provider?.isCached == true ? 0.6 : 1
                        Self.strokeArc(center: center, radius: radius, start: start,
                                       sweep: 94 * window.remainingPercent / 100,
                                       thickness: thickness, color: color.withAlphaComponent(alpha))
                    }
                }
            }
            if let opportunity, let index = AIProviderKind.allCases.firstIndex(of: opportunity) {
                colors[index].setFill()
                NSBezierPath(ovalIn: NSRect(x: 8.3, y: 8.3, width: 3.4, height: 3.4)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func strokeArc(
        center: NSPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat, thickness: CGFloat, color: NSColor
    ) {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
        arc.lineWidth = thickness
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    private func buildTooltip(snapshots: [ProviderSnapshot], alerts: [SurplusAlert]) -> String {
        guard !snapshots.isEmpty else { return "Loading TokenPulse usage…" }
        var lines = snapshots.map { snap -> String in
            guard let window = snap.menuBarWindow else {
                return "\(snap.provider.displayName): \(snap.status.badgeText)"
            }
            let value = Formatters.formatPercent(window.remainingPercent)
            let reset = window.resetsAt.map { " · " + Formatters.formatCountdown(until: $0) } ?? ""
            let source = snap.status == .demo ? " · Demo" : ""
            let cached = snap.isCached ? " · Cached" : ""
            let blocked = snap.shortLimitBlocksWeekly ? " · Short-term limit reached" : ""
            return "\(snap.provider.displayName): \(value) left · \(window.label)\(reset)\(source)\(cached)\(blocked)"
        }
        if let first = alerts.first(where: \.isSpendingOpportunity) ?? alerts.first {
            lines.append(first.body)
        }
        return lines.joined(separator: "\n")
    }
}
