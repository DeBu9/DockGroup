import AppKit
import Foundation

/// A single binary plays two roles. When it is launched from DockGroup.app it is
/// the settings host; when launched from a generated stub .app it shows that
/// group's panel immediately and exits when the panel closes.
enum LaunchMode {
    static let stubBundlePrefix = "local.dockgroup.stub."
    static let hostBundleID = "local.dockgroup.main"

    static var isStub: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasPrefix(stubBundlePrefix)
    }

    /// The group UUID is stored as a plain resource inside the stub bundle.
    static var stubGroupID: UUID? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("group.id"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Locate the settings host via LaunchServices so moving the .app is harmless.
    static var hostAppURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostBundleID) {
            return url
        }
        if let resourceDir = Bundle.main.resourceURL {
            let file = resourceDir.appendingPathComponent("host.path")
            if let raw = try? String(contentsOf: file, encoding: .utf8) {
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }
}

enum MenuBarPreference {
    static let key = "DockGroupShowMenuBar"

    /// Defaults to hidden: the menu bar icon is optional and off by default.
    static var isVisible: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Shared between the settings host and every generated stub. A plain suite
/// domain is used instead of `UserDefaults.standard`, which is scoped to each
/// stub's own bundle identifier and therefore invisible to the settings app.
enum ResidentPreference {
    static let suiteName = "local.dockgroup.shared"
    static let key = "DockGroupKeepAliveAfterClose"

    /// Off by default: the panel process exits as soon as the panel closes.
    static var isEnabled: Bool {
        get { UserDefaults(suiteName: suiteName)?.bool(forKey: key) ?? false }
        set { UserDefaults(suiteName: suiteName)?.set(newValue, forKey: key) }
    }
}
