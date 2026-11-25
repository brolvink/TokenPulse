import AppKit
import SwiftUI

public struct DashboardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedProvider: AIProviderKind?
    @State private var launchError: String?
    @ObservedObject var viewModel: UsageMonitorViewModel
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    public init(
        viewModel: UsageMonitorViewModel,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("TokenPulse").font(.headline)
                if viewModel.preferences.demoMode {
                    Text("Demo").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await viewModel.refreshAll(triggerNotifications: false) }
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRefreshing)
                .help("Refresh")

                Menu {
                    Button("Settings…", action: onOpenSettings)
                    Button("Connect Claude…") {
                        Task { await viewModel.refreshAll(triggerNotifications: false, connectClaude: true) }
                    }
                    .disabled(viewModel.preferences.demoMode)
                    if viewModel.isSnoozed {
                        Button("Resume Alerts") { viewModel.clearSnoozeAndRecheck() }
                    } else {
                        Button("Snooze Alerts") { viewModel.snoozeAlerts(hours: 4) }
                    }
                    Divider()
                    Button("Quit TokenPulse", action: onQuit)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options")
            }
            .buttonStyle(.borderless)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    columnHeading("Short-term")
                    columnHeading("Weekly")
                }
                .padding(.bottom, 6)
                .accessibilityHidden(true)

                ForEach(AIProviderKind.allCases) { provider in
                    if provider != AIProviderKind.allCases.first {
                        Divider()
                    }
                    providerRow(provider, snapshot: viewModel.snapshots.first { $0.provider == provider })
                }
            }

            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                if let forecast = viewModel.topWeeklyForecast(at: timeline.date) {
                    let reset = Formatters.formatCountdown(until: forecast.resetsAt, from: timeline.date)
                    footerRow(icon: "chart.line.uptrend.xyaxis",
                              title: "\(forecast.provider.displayName) · About \(forecast.projectedUnusedPercent)% may go unused",
                              subtitle: "Weekly · " + reset,
                              help: "Projected from your recent weekly quota readings.")
                } else if let alert = viewModel.activeAlerts.first(where: \.isSpendingOpportunity) ?? viewModel.activeAlerts.first {
                    alertRow(alert)
                }
            }

        }
        .padding(16)
        .frame(width: 356, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func columnHeading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 88, alignment: .leading)
            .padding(.leading, 8)
    }

    private func alertRow(_ alert: SurplusAlert) -> some View {
        footerRow(icon: "bell",
                  title: alert.isSpendingOpportunity
                    ? "\(alert.provider.displayName) · \(Formatters.formatPercent(alert.remainingPercent)) left"
                    : alert.title,
                  subtitle: alert.isSpendingOpportunity ? alert.resetsAt.map { Formatters.formatCountdown(until: $0) } : nil,
                  help: alert.body)
    }

    private func footerRow(icon: String, title: String, subtitle: String?, help: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .frame(width: 15)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .help(help)
    }

    private func select(_ provider: AIProviderKind) {
        selectedProvider = selectedProvider == provider ? nil : provider
        launchError = nil
    }

    private func providerRow(_ provider: AIProviderKind, snapshot: ProviderSnapshot?) -> some View {
        let selected = selectedProvider == provider
        return HStack(spacing: 0) {
            Button {
                select(provider)
            } label: {
                providerLabel(provider, snapshot: snapshot)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(selected ? "Show quota readings" : "Show launch options")

            launchCell(snapshot?.shortWindow, blocked: snapshot?.shortLimitBlocksWeekly == true,
                       provider: provider, useCLI: false)
            launchCell(snapshot?.weeklyWindow, blocked: false, provider: provider, useCLI: true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(selected ? 0.05 : 0))
                .padding(.horizontal, -6)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selected)
    }

    private func providerLabel(_ provider: AIProviderKind, snapshot: ProviderSnapshot?) -> some View {
        let details = snapshot.map { sourceDetails($0) } ?? "Loading"
        return HStack(alignment: .top, spacing: 7) {
            Group {
                if let app = ProviderLauncher.nativeApp(for: provider) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: provider.symbolName)
                        .foregroundStyle(provider.accentColor)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if selectedProvider == provider, let launchError {
                    Text(launchError)
                } else if let snapshot {
                    switch snapshot.status {
                    case .unavailable:
                        Text("Unavailable")
                    default:
                        Text(snapshot.isCached ? "Cached · " + snapshot.fetchedAt.formatted(date: .omitted, time: .shortened)
                             : snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .help(details)
        .accessibilityHint(details)
    }

    private func launchCell(
        _ window: QuotaWindow?, blocked: Bool, provider: AIProviderKind, useCLI: Bool
    ) -> some View {
        ZStack {
            if selectedProvider == provider {
                let destination = useCLI ? ProviderLauncher.cli(for: provider) : ProviderLauncher.nativeApp(for: provider)
                Button {
                    guard let destination else { return }
                    launch(provider: provider) {
                        if useCLI {
                            try await ProviderLauncher.openCLI(destination)
                        } else {
                            try await ProviderLauncher.openApp(destination)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: useCLI ? "terminal" : "macwindow")
                        Text(useCLI ? "CLI" : "App")
                    }
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(destination == nil)
                .help(destination == nil ? "Not installed" : (useCLI ? "Open in Terminal" : "Open native app"))
                .accessibilityLabel(useCLI ? "Open \(provider.displayName) in Terminal" : "Open \(provider.displayName) app")
                .padding(.leading, 8)
                .transition(.opacity)
            } else {
                Button {
                    select(provider)
                } label: {
                    quotaCell(window, blocked: blocked)
                        .accessibilityLabel(useCLI ? "Weekly quota" : "Short-term quota")
                        .accessibilityValue(window.map { "\(Formatters.formatPercent($0.remainingPercent)) left, \(Formatters.formatCountdown(until: $0.resetsAt))" } ?? "Unavailable")
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show launch options")
                .transition(.opacity)
            }
        }
        .frame(width: 96, height: 36)
    }

    private func launch(provider: AIProviderKind, _ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                if selectedProvider == provider {
                    selectedProvider = nil
                    launchError = nil
                }
            } catch {
                if selectedProvider == provider {
                    launchError = "Couldn’t open"
                }
            }
        }
    }

    private func sourceDetails(_ snapshot: ProviderSnapshot) -> String {
        if case .unavailable(let hint) = snapshot.status {
            return hint
        }
        let quotas = snapshot.windows.map { "\($0.label) · \(Formatters.formatPercent($0.remainingPercent)) left" }
        return ([snapshot.sourceDetail, snapshot.fetchedAt.formatted()] + quotas).joined(separator: "\n")
    }

    private func quotaCell(_ window: QuotaWindow?, blocked: Bool) -> some View {
        let reset = window?.resetsAt.map { Formatters.formatCountdown(until: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let window {
                    Text((window.isEstimated ? "≈" : "") + Formatters.formatPercent(window.remainingPercent))
                        .font(.system(.callout, design: .monospaced, weight: .medium))
                        .foregroundStyle(blocked ? Color.orange : Color.primary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            if let cached = window?.cachedAt {
                Text("Cached · " + cached.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let reset {
                Text(reset.replacingOccurrences(of: "Resets in ", with: ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .help(blocked ? "Short-term limit reached" : (reset ?? window?.label ?? "Quota unavailable"))
    }
}
