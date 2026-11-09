import Foundation
import AppKit
import CoreServices

enum ItemKind: String, Codable, CaseIterable {
    case app
    case file
    case folder
    case web
    case subgroup

    var label: String {
        switch self {
        case .app: return "应用"
        case .file: return "文件"
        case .folder: return "文件夹"
        case .web: return "网页"
        case .subgroup: return "子组"
        }
    }
}

struct GroupItem: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var kind: ItemKind
    /// True once the user edits the name; auto-refresh skips those items.
    /// Optional so configs written by older builds decode unchanged.
    var customName: Bool?
    /// Bookmark for the target. A bookmark follows the file through renames and
    /// moves on the same volume, which an absolute path cannot do. Optional so
    /// configs written by older builds decode unchanged.
    var bookmark: Data?
    /// Bundle identifier for app items. Used as a second anchor: LaunchServices
    /// can find a moved .app even when its bookmark went stale (cross-volume
    /// move, restore from backup, app replaced by an upgrade).
    var bundleID: String?

    init(id: UUID = UUID(), name: String, path: String, kind: ItemKind,
         customName: Bool? = nil, bookmark: Data? = nil, bundleID: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.customName = customName
        self.bookmark = bookmark
        self.bundleID = bundleID
    }

    /// Identity anchors captured when the item is added or repaired.
    static func identity(of url: URL) -> (bookmark: Data?, bundleID: String?) {
        let data = try? url.bookmarkData(options: [],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        let bundleID = url.pathExtension == "app" ? Bundle(url: url)?.bundleIdentifier : nil
        return (data, bundleID)
    }

    /// Where the item actually is right now, or nil when it can no longer be
    /// found. The plain path check is the fast path (~10 µs); the bookmark and
    /// the LaunchServices lookup only run once the path is gone.
    func resolveURL() -> URL? {
        if kind == .web || kind == .subgroup { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        if let data = bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withoutUI],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                return url
            }
        }
        if let bundleID = bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        return nil
    }

    /// Finder's localized display name. On macOS 27 only Spotlight metadata
    /// returns Chinese system-app names (Maps -> 地图, Finder -> 访达);
    /// Bundle / FileManager / LaunchServices all return the English filename.
    /// Called only when adding or explicitly refreshing, never on panel launch.
    static func resolvedName(for url: URL) -> String {
        let ext = url.pathExtension
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let raw = MDItemCopyAttribute(item, kMDItemDisplayName) as? String,
           !raw.isEmpty {
            var name = raw
            if !ext.isEmpty, name.hasSuffix("." + ext) {
                name.removeLast(ext.count + 1)
            }
            if !name.isEmpty { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `localized: false` skips the Spotlight lookup, used when expanding a
    /// folder that may contain dozens of children on the interactive path.
    /// `captureIdentity: false` skips bookmark creation, same reason: those
    /// children only live for one panel session.
    static func from(url: URL, localized: Bool = true, captureIdentity: Bool = true) -> GroupItem {
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let kind: ItemKind
        if path.hasSuffix(".app") {
            kind = .app
        } else if exists && isDir.boolValue {
            kind = .folder
        } else {
            kind = .file
        }
        let name = localized
            ? resolvedName(for: url)
            : url.deletingPathExtension().lastPathComponent
        var item = GroupItem(name: name, path: path, kind: kind)
        if captureIdentity {
            let anchors = identity(of: url)
            item.bookmark = anchors.bookmark
            item.bundleID = anchors.bundleID
        }
        return item
    }
}

struct AppGroup: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var items: [GroupItem]

    init(id: UUID = UUID(), name: String, items: [GroupItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

struct Config: Codable {
    var groups: [AppGroup]

    static let empty = Config(groups: [])
}
