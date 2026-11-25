import SwiftUI

public struct DashboardView: View {
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
                    .disabled(viewModel.isRefreshing || viewModel.preferences.demoMode)
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

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("Short-term")
                    Text("Weekly")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(AIProviderKind.allCases) { provider in
                    let snapshot = viewModel.snapshots.first { $0.provider == provider }
                    GridRow {
                        providerLabel(provider, snapshot: snapshot)
                        launchCell(snapshot?.shortWindow, blocked: snapshot?.shortLimitBlocksWeekly == true,
                                   provider: provider, useCLI: false)
                        launchCell(snapshot?.weeklyWindow, blocked: false, provider: provider, useCLI: true)
                    }
                }
            }

            if let alert = viewModel.activeAlerts.first(where: \.isSpendingOpportunity) ?? viewModel.activeAlerts.first {
                Divider()
                Label(alertSummary(alert), systemImage: "bell")
                    .foregroundStyle(alert.provider.accentColor)
                    .font(.caption)
                    .lineLimit(1)
                    .help(alert.body)
            }
        }
        .padding(16)
        .frame(width: 356, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func alertSummary(_ alert: SurplusAlert) -> String {
        guard alert.isSpendingOpportunity else { return alert.title }
        let reset = alert.resetsAt.map { " · " + Formatters.formatCountdown(until: $0) } ?? ""
        return "\(alert.provider.displayName) · \(Formatters.formatPercent(alert.remainingPercent)) left" + reset
    }

    private func providerLabel(_ provider: AIProviderKind, snapshot: ProviderSnapshot?) -> some View {
        let details = snapshot.map { sourceDetails($0) } ?? "Loading"
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: provider.symbolName)
                .foregroundStyle(provider.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    selectedProvider = selectedProvider == provider ? nil : provider
                    launchError = nil
                } label: {
                    Text(provider.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show ways to open \(provider.displayName)")
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
        let selected = selectedProvider == provider
        return quotaCell(window, blocked: blocked)
            .opacity(selected ? 0 : 1)
            .accessibilityHidden(selected)
            .overlay(alignment: .leading) {
                if selected {
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
                        Label(useCLI ? "CLI" : "App", systemImage: useCLI ? "terminal" : "macwindow")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(destination == nil)
                    .help(destination == nil ? "Not installed" : (useCLI ? "Open in Terminal" : "Open native app"))
                    .accessibilityLabel(useCLI ? "Open \(provider.displayName) in Terminal" : "Open \(provider.displayName) app")
                }
            }
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
        VStack(alignment: .leading, spacing: 2) {
            if let window {
                Text((window.isEstimated ? "≈" : "") + Formatters.formatPercent(window.remainingPercent))
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundStyle(blocked ? Color.orange : Color.primary)
                if let reset = window.resetsAt {
                    Text(Formatters.formatCountdown(until: reset).replacingOccurrences(of: "Resets in ", with: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 69, minHeight: 30, alignment: .topLeading)
        .help(blocked ? "Short-term limit reached" : (window?.label ?? "Quota unavailable"))
    }
}
