import AppKit
import Foundation

/// Hands a command to the user's terminal.
///
/// This is how the app answers "let me actually talk to this model" without growing a chat UI:
/// `ollama run` already is a chat, in the tool built for it. We open it and get out of the way.
///
/// A `.command` file is used rather than AppleScript on purpose — scripting Terminal needs Apple
/// Events consent, while opening a file respects whatever terminal the user has set as default
/// and prompts for nothing.
enum TerminalLauncher {
    static func run(_ command: String) {
        cleanUpOldScripts()

        let directory = scriptDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: "ollama-bar-\(UUID().uuidString.prefix(8)).command")
        let script = """
        #!/bin/sh
        clear
        exec \(command)

        """

        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    /// `ollama run <model>` — an interactive session with the model, in the user's own shell.
    static func chat(with model: String) {
        run("ollama run \(shellQuoted(model))")
    }

    private static var scriptDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "ollama-bar")
    }

    /// The scripts are one-shot; anything from a previous session is litter.
    private static func cleanUpOldScripts() {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: scriptDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, Date.now.timeIntervalSince(modified) > 3600 {
                try? manager.removeItem(at: url)
            }
        }
    }

    /// Model names carry colons and slashes, and nothing stops one carrying a quote.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
