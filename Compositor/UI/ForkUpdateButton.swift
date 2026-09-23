import AppKit
import SwiftUI

/// The toolbar's update indicator.
///
/// Muted and inert while this build is current, a red dot and a click away when the fork has a newer
/// release, a spinner while a check runs, and clickable again after a check that got no answer.
///
/// The offer is an `NSAlert` rather than a SwiftUI alert, matching the checker's own alerts: the
/// button can then stay a plain function of `ForkUpdateChecker.status` with no presentation state of
/// its own, and the two update surfaces read the same.
@MainActor
struct ForkUpdateButton: View {
    let updates: ForkUpdateChecker

    private var status: ForkUpdateStatus { updates.status }

    private var isActionable: Bool {
        switch status {
        case .available, .failed: return true
        case .checking, .current, .unchecked: return false
        }
    }

    private var iconOpacity: Double {
        switch status {
        case .available: return 1
        case .failed: return 0.55
        case .checking: return 1
        case .current, .unchecked: return 0.32
        }
    }

    var body: some View {
        Button(action: activate) {
            if case .checking = status {
                ProgressView().controlSize(.mini)
            } else {
                ZStack(alignment: .topTrailing) {
                    // The dot is drawn inside the image's own bounds: a toolbar item clips anything
                    // that reaches past them, and a half-visible dot reads as a rendering glitch.
                    Image(systemName: "arrow.down.circle")
                        .padding(.top, 1)
                        .padding(.trailing, 4)
                    if status.isAvailable {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                    }
                }
                .opacity(iconOpacity)
            }
        }
        .disabled(!isActionable)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("forkUpdateToolbar")
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var helpText: String {
        switch status {
        case .checking:
            return L10n.text("Checking for Updates…")
        case .available(let version):
            return L10n.format("Fork Update Available: %@", version)
        case .current:
            return L10n.format("You’re Up to Date (%@)", currentVersion)
        case .failed:
            return L10n.text("Update Check Failed. Click to Try Again.")
        case .unchecked:
            return L10n.text("Not Checked for Updates Yet")
        }
    }

    private func activate() {
        switch status {
        case .available: offerUpdate()
        case .failed: updates.checkForUpdates()
        case .checking, .current, .unchecked: break
        }
    }

    private func offerUpdate() {
        guard let version = status.availableVersion else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("Fork Update Available")
        alert.informativeText = L10n.format("You’re using %@. The fork’s newest release is %@.\n\nThis build targets macOS 15, so the release download can’t run here — rebuilding it locally is how to update. Quit and reopen the app when the rebuild finishes.", currentVersion, version)
        alert.addButton(withTitle: L10n.text("Rebuild Locally…"))
        alert.addButton(withTitle: L10n.text("Open Release Page"))
        alert.addButton(withTitle: L10n.text("Later"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            rebuild()
        case .alertSecondButtonReturn:
            if let url = updates.availableReleaseURL { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private func rebuild() {
        // A cancelled picker is a decision, not a failure: nothing to report.
        guard let workingCopy = LocalUpdateLauncher.locate() ?? LocalUpdateLauncher.choose() else { return }
        guard LocalUpdateLauncher.run(in: workingCopy) else {
            let alert = NSAlert()
            alert.messageText = L10n.text("Couldn’t Start the Rebuild")
            alert.informativeText = L10n.format("Open Terminal and run update.sh in %@ yourself.", workingCopy.path)
            alert.addButton(withTitle: L10n.text("OK"))
            alert.runModal()
            return
        }
    }
}
