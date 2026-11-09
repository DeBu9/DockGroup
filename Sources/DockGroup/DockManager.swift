import Foundation
import AppKit

final class DockManager {
    private let store: Store
    private let fm = FileManager.default

    /// Overridable for self-tests; production uses the running host binary.
    var executableSource: URL?

    // Every stub lives below this path segment, used to identify our own Dock tiles.
    private static let marker = "/DockGroup/Stubs/"

    init(store: Store) {
        self.store = store
    }

    // MARK: - Process helper

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> (code: Int32, output: String) {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Signing

    /// codesign leaves `*.cstemp` files behind when provenance xattrs block its
    /// temp-file rename, and those files break the bundle seal on the next run.
    private func clearSigningTempFiles(_ app: URL) {
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: macos.path)) ?? []
        for name in names where name.contains(".cstemp") {
            try? fm.removeItem(at: macos.appendingPathComponent(name))
        }
    }

    @discardableResult
    private func resign(_ app: URL) -> Bool {
        clearSigningTempFiles(app)
        run("/usr/bin/xattr", ["-cr", app.path])
        run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        if run("/usr/bin/codesign", ["-v", app.path]).code != 0 {
            clearSigningTempFiles(app)
            run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        }
        return run("/usr/bin/codesign", ["-v", app.path]).code == 0
    }

    // MARK: - Stub apps

    func stubURL(for group: AppGroup) -> URL {
        store.stubsDir.appendingPathComponent("\(group.id.uuidString).app", isDirectory: true)
    }

    func makeStub(for group: AppGroup) {
        let app = stubURL(for: group)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        do {
            // Rebuild in place. macOS marks signed executables with a provenance
            // xattr and refuses to unlink them, so overwrite contents instead.
            try fm.createDirectory(at: macos, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)

            // The stub carries its own copy of the native binary, so clicking it
            // needs exactly one process launch and no URL-scheme round trip.
            guard let source = executableSource ?? Bundle.main.executableURL,
                  let binary = try? Data(contentsOf: source) else { return }
            let executable = macos.appendingPathComponent("DockGroup")
            try binary.write(to: executable)
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                 ofItemAtPath: executable.path)
            try? fm.removeItem(at: macos.appendingPathComponent("launcher"))

            try group.id.uuidString.write(to: resources.appendingPathComponent("group.id"),
                                          atomically: true, encoding: .utf8)
            // Fallback location for the settings host if LaunchServices can't find it.
            try Bundle.main.bundleURL.path.write(to: resources.appendingPathComponent("host.path"),
                                                 atomically: true, encoding: .utf8)

            let bundleID = "local.dockgroup.stub." + group.id.uuidString.replacingOccurrences(of: "-", with: "")
            let info: [String: Any] = [
                "CFBundleName": group.name,
                "CFBundleDisplayName": group.name,
                "CFBundleIdentifier": bundleID,
                "CFBundleExecutable": "DockGroup",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "3",
                "CFBundleIconFile": "AppIcon.icns",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": true,
                "NSHighResolutionCapable": true,
                // Declaring a low-priority viewer for everything lets the Dock
                // route file drops onto the tile to this app as an open-document
                // event. Alternate rank keeps it out of the default-handler slots.
                "CFBundleDocumentTypes": [
                    [
                        "CFBundleTypeName": "Any Item",
                        "CFBundleTypeRole": "Viewer",
                        "LSHandlerRank": "Alternate",
                        "LSItemContentTypes": ["public.item"]
                    ]
                ]
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plistData.write(to: contents.appendingPathComponent("Info.plist"))

            writeIcon(for: group, to: resources.appendingPathComponent("AppIcon.icns"))
            resign(app)

            let register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            if fm.isExecutableFile(atPath: register) {
                run(register, ["-f", app.path])
            }
        } catch {
            // A stub that fails to build simply will not appear; the main app stays usable.
        }
    }

    private func iconImage(for item: GroupItem) -> NSImage {
        switch item.kind {
        case .web:
            return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        case .subgroup:
            return NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil) ?? NSImage()
        default:
            if let url = item.resolveURL() {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
        }
    }

    private func writeIcon(for group: AppGroup, to dest: URL) {
        let icons = group.items.prefix(4).map { iconImage(for: $0) }
        IconRenderer.writeICNS(IconRenderer.groupImage(icons: icons), to: dest)
    }

    // MARK: - Dock plist

    private func exportDock(to url: URL) -> Bool {
        run("/usr/bin/defaults", ["export", "com.apple.dock", url.path]).code == 0
    }

    @discardableResult
    func backupDock() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = store.backupDir
            .appendingPathComponent("com.apple.dock.\(formatter.string(from: Date())).plist")
        return exportDock(to: url) ? url : nil
    }

    private func tile(for group: AppGroup) -> [String: Any] {
        let stub = stubURL(for: group)
        let encoded = stub.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stub.path
        return [
            "tile-type": "file-tile",
            "tile-data": [
                "file-label": group.name,
                "file-data": [
                    "_CFURLString": "file://\(encoded)/",
                    "_CFURLStringType": 15
                ]
            ] as [String: Any]
        ] as [String: Any]
    }

    private func isOurs(_ dict: [String: Any]) -> Bool {
        let fileData = (dict["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
        let url = fileData?["_CFURLString"] as? String ?? ""
        return url.contains(DockManager.marker)
    }

    private func rewriteDock(groups: [AppGroup]) -> String {
        let tmp = fm.temporaryDirectory.appendingPathComponent("dockgroup-\(UUID().uuidString).plist")
        guard exportDock(to: tmp),
              let data = try? Data(contentsOf: tmp),
              var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else {
            return "读取 Dock 配置失败"
        }

        var apps = plist["persistent-apps"] as? [[String: Any]] ?? []
        apps.removeAll(where: isOurs)
        apps.append(contentsOf: groups.map(tile))
        plist["persistent-apps"] = apps

        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return "序列化 Dock 配置失败"
        }
        do {
            try out.write(to: tmp)
        } catch {
            return "写入临时配置失败"
        }

        let result = run("/usr/bin/defaults", ["import", "com.apple.dock", tmp.path])
        try? fm.removeItem(at: tmp)
        run("/usr/bin/killall", ["Dock"])

        if result.code != 0 {
            return "写入 Dock 配置失败：\(result.output)"
        }
        return groups.isEmpty
            ? "已从 Dock 移除所有组"
            : "已同步 \(groups.count) 个组到 Dock（Dock 已重启）"
    }

    func syncToDock() -> String {
        _ = backupDock()
        for group in store.config.groups {
            makeStub(for: group)
        }
        return rewriteDock(groups: store.config.groups)
    }

    /// A group can gain items from a drop on its Dock tile, which changes the
    /// icon preview. Rebuilding a stub from inside that stub would rewrite the
    /// running executable under itself, so the rebuild happens here in the
    /// settings host, and only when the config is newer than the stub.
    /// The Dock still has to be restarted before the new preview shows.
    @discardableResult
    func refreshStubsIfStale() -> Int {
        guard let configDate = store.configModificationDate else { return 0 }
        var rebuilt = 0
        for group in store.config.groups {
            let plist = stubURL(for: group).appendingPathComponent("Contents/Info.plist")
            guard let attrs = try? fm.attributesOfItem(atPath: plist.path),
                  let stubDate = attrs[.modificationDate] as? Date else { continue }
            guard configDate > stubDate else { continue }
            makeStub(for: group)
            rebuilt += 1
        }
        return rebuilt
    }

    func removeFromDock() -> String {
        _ = backupDock()
        return rewriteDock(groups: [])
    }

    func restoreLastBackup() -> String {
        let files = (try? fm.contentsOfDirectory(at: store.backupDir, includingPropertiesForKeys: nil)) ?? []
        guard let latest = files.filter({ $0.pathExtension == "plist" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last else {
            return "没有找到备份"
        }
        let result = run("/usr/bin/defaults", ["import", "com.apple.dock", latest.path])
        run("/usr/bin/killall", ["Dock"])
        return result.code == 0 ? "已从备份恢复：\(latest.lastPathComponent)" : "恢复失败"
    }

    /// Each stub carries a copy of the host binary. After an upgrade, silently
    /// refresh those copies so the user does not have to re-sync the Dock.
    @discardableResult
    func refreshStubBinariesIfNeeded() -> Int {
        guard let source = executableSource ?? Bundle.main.executableURL,
              let fresh = try? Data(contentsOf: source) else { return 0 }
        let apps = (try? fm.contentsOfDirectory(at: store.stubsDir,
                                                includingPropertiesForKeys: nil)) ?? []
        let register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        var updated = 0
        for app in apps where app.pathExtension == "app" {
            let dest = app.appendingPathComponent("Contents/MacOS/DockGroup")
            guard let current = try? Data(contentsOf: dest), current != fresh else { continue }
            do {
                // Overwrite in place; unlinking a provenance-tagged signed
                // binary is rejected with EPERM on macOS 27.
                try fresh.write(to: dest)
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                     ofItemAtPath: dest.path)
                let signed = resign(app)
                if fm.isExecutableFile(atPath: register) {
                    run(register, ["-f", app.path])
                }
                if signed { updated += 1 }
            } catch {
                // Leave this stub on its previous binary; a full Dock sync fixes it.
            }
        }
        return updated
    }
}
