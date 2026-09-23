import AppKit
import Foundation

/// Finds the port's working copy — the checkout whose scripts produced this build — and opens its
/// update script in Terminal.
///
/// It never runs git or the compiler itself. The rebuild takes minutes and prints a lot, so it
/// belongs in a window the user can watch rather than behind a spinner, and it must survive this
/// app being replaced while it runs.
///
/// A folder only qualifies when it holds both `update.sh` and a `.git` checkout, so a directory that
/// merely happens to sit at a scanned path is never executed.
@MainActor
enum LocalUpdateLauncher {
    static let scriptName = "update.sh"
    private static let defaultsKey = "port.workingCopyPath"

    // MARK: - Locating

    static func isWorkingCopy(_ url: URL) -> Bool {
        guard url.isFileURL, url.path != "/" else { return false }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return manager.fileExists(atPath: url.appendingPathComponent(scriptName).path)
            && manager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// A remembered folder wins, but it is re-validated every time: the checkout may have moved since.
    static func locate() -> URL? {
        if let remembered = remembered(), isWorkingCopy(remembered) { return remembered }
        for candidate in candidates() where isWorkingCopy(candidate) {
            remember(candidate)
            return candidate
        }
        return nil
    }

    private static func remembered() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
    }

    /// Where this port is laid out in practice: a session folder inside `~/WorkBuddy` holding a
    /// `Compositor-macos15` checkout. Deliberately does not scan Documents or Desktop — those are
    /// protected, and probing them would raise a permission prompt for a feature that should be quiet.
    private static func candidates() -> [URL] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        let workspace = home.appendingPathComponent("WorkBuddy")
        if let sessions = try? manager.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) {
            for session in sessions.sorted(by: { $0.path > $1.path }) {
                candidates.append(session.appendingPathComponent("Compositor-macos15"))
                candidates.append(session.appendingPathComponent("Compositor"))
            }
        }
        for folder in ["Compositor-macos15", "Compositor",
                       "Developer/Compositor-macos15", "Code/Compositor-macos15",
                       "Projects/Compositor-macos15", "src/Compositor-macos15",
                       "repos/Compositor-macos15"] {
            candidates.append(home.appendingPathComponent(folder))
        }
        return candidates
    }

    /// Last resort: ask. The picker reopens rather than silently accepting a folder the launcher
    /// cannot use — an ignored choice would look like the feature is broken.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L10n.text("Choose")
        panel.message = L10n.text("Choose the folder that holds update.sh and its .git checkout.")
        // Bounded: a picker that never accepts anything is worse than one that gives up.
        for _ in 0..<8 {
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            if isWorkingCopy(url) { remember(url); return url }
            let alert = NSAlert()
            alert.messageText = L10n.text("That Folder Isn’t a Working Copy")
            alert.informativeText = L10n.text("Choose the folder that holds update.sh and its .git checkout.")
            alert.addButton(withTitle: L10n.text("Choose Again"))
            alert.addButton(withTitle: L10n.text("Cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return nil }
        }
        return nil
    }

    // MARK: - Running

    /// Opens Terminal on the working copy's update script. Terminal runs an executable text file the
    /// way it runs a `.command`, and the script's own `cd` keeps the rebuild inside the checkout.
    @discardableResult
    static func run(in workingCopy: URL) -> Bool {
        let script = workingCopy.appendingPathComponent(scriptName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", script.path]
        do { try process.run() } catch { return false }
        return true
    }
}
