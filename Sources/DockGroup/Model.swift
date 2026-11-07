import Foundation
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

    init(id: UUID = UUID(), name: String, path: String, kind: ItemKind,
         customName: Bool? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.customName = customName
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
    static func from(url: URL, localized: Bool = true) -> GroupItem {
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
        return GroupItem(name: name, path: path, kind: kind)
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
