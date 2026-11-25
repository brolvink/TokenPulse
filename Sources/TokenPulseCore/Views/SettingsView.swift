import SwiftUI

public struct SettingsView: View {
    @ObservedObject var viewModel: UsageMonitorViewModel

    public init(viewModel: UsageMonitorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("General") {
                Picker("Refresh interval", selection: $viewModel.preferences.refreshIntervalMinutes) {
                    Text("Every 1 minute").tag(1)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 10 minutes").tag(10)
                    Text("Every 15 minutes").tag(15)
                }

                Toggle("Menu bar percentages", isOn: $viewModel.preferences.showPercentagesInMenuBar)
                Toggle("Menu bar quota fill", isOn: $viewModel.preferences.showMiniBarsInMenuBar)
                Toggle("Demo mode", isOn: $viewModel.preferences.demoMode)
            }

            Section("Alerts") {
                Toggle("Unused quota", isOn: $viewModel.preferences.enableSurplusAlerts)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Surplus threshold")
                        Spacer()
                        Text("\(Int(viewModel.preferences.surplusThresholdPercent))% remaining")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $viewModel.preferences.surplusThresholdPercent, in: 35...90, step: 5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Lead time")
                        Spacer()
                        Text("\(Int(viewModel.preferences.surplusLeadHours))h")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $viewModel.preferences.surplusLeadHours, in: 4...48, step: 2)
                }

                Toggle("Suggest switching providers", isOn: $viewModel.preferences.enableImbalanceAlerts)
                Toggle("Low quota", isOn: $viewModel.preferences.enableLowQuotaAlerts)

                Picker("Alert cooldown", selection: $viewModel.preferences.alertCooldownHours) {
                    Text("1 hour").tag(1.0)
                    Text("4 hours").tag(4.0)
                    Text("8 hours").tag(8.0)
                    Text("12 hours").tag(12.0)
                }

                HStack {
                    Button("Test Alert") {
                        viewModel.sendTestNotification()
                    }
                    Spacer()
                    if viewModel.isSnoozed {
                        Button("Resume Alerts") {
                            viewModel.clearSnoozeAndRecheck()
                        }
                    }
                }
            }


        }
        .formStyle(.grouped)
        .frame(width: 470, height: 520)
    }
}
