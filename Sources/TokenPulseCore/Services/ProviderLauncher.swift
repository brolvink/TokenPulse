import AppKit

@MainActor
enum ProviderLauncher {
    static func nativeApp(for provider: AIProviderKind) -> URL? {
        let identifier = switch provider {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        case .antigravity: "com.google.antigravity"
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    static func cli(for provider: AIProviderKind) -> URL? {
        let name = switch provider {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [
            home.appendingPathComponent(".local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin")
        ]
        return directories.map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func openApp(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    static func openCLI(_ executable: URL) async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenPulse-\(UUID().uuidString).command")
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let contents = """
        #!/bin/sh
        /bin/rm -f -- "$0"
        cd "$HOME" || exit 1
        exec \(quoted)

        """
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        do {
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init())
        } catch {
            try? FileManager.default.removeItem(at: script)
            throw error
        }
    }
}
