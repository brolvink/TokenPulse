import AppKit
import SwiftUI
import TokenPulseCore

@main
struct TokenPulseMain {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--capture-antigravity-quota"] {
            try? AntigravityQuotaFeed.capture(FileHandle.standardInput.readDataToEndOfFile())
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var viewModel: UsageMonitorViewModel?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vm = UsageMonitorViewModel()
        self.viewModel = vm
        self.statusBarController = StatusBarController(viewModel: vm)
        vm.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.stopMonitoring()
    }
}
