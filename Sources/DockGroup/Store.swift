import Foundation
import Combine

final class Store: ObservableObject {
    @Published var config: Config = .empty

    let rootDir: URL
    let stubsDir: URL
    let backupDir: URL
    private let configURL: URL

    /// Resolved locations, keyed by item id. Kept so the panel render path never
    /// touches disk more than once per item.
    private var urlCache: [UUID: URL] = [:]
    private var unresolvable: Set<UUID> = []

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DockGroup", isDirectory: true)
        rootDir = base
        stubsDir = base.appendingPathComponent("Stubs", isDirectory: true)
        backupDir = base.appendingPathComponent("Backups", isDirectory: true)
        configURL = base.appendingPathComponent("config.json")

        let fm = FileManager.default
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        try? fm.createDirectory(at: stubsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(Config.self, from: data) else { return }
        config = decoded
        urlCache.removeAll()
        unresolvable.removeAll()
    }

    /// Used to decide whether a stub bundle still matches the config it shows.
    var configModificationDate: Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: configURL.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    // MARK: - Groups

    func addGroup() {
        config.groups.append(AppGroup(name: "新组"))
        save()
    }

    func removeGroup(_ id: UUID) {
        config.groups.removeAll { $0.id == id }
        save()
    }

    func groupIndex(_ id: UUID) -> Int? {
        config.groups.firstIndex { $0.id == id }
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let i = groupIndex(id) else { return }
        config.groups[i].name = name
        save()
    }

    // MARK: - Items

    func addItem(_ item: GroupItem, to groupID: UUID) {
        guard let i = groupIndex(groupID) else { return }
        config.groups[i].items.append(item)
        save()
    }

    /// Batch append used by drag-and-drop. Entries already in the group are
    /// skipped so dropping the same file twice is a no-op.
    @discardableResult
    func addItems(_ items: [GroupItem], to groupID: UUID) -> Int {
        guard let i = groupIndex(groupID) else { return 0 }
        var added = 0
        for item in items where !config.groups[i].items.contains(where: { $0.path == item.path }) {
            config.groups[i].items.append(item)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    // MARK: - Locations

    /// Cached resolution for the render path.
    func url(for item: GroupItem) -> URL? {
        if item.kind == .web || item.kind == .subgroup { return nil }
        if let hit = urlCache[item.id] { return hit }
        if unresolvable.contains(item.id) { return nil }
        guard let url = item.resolveURL() else {
            unresolvable.insert(item.id)
            return nil
        }
        urlCache[item.id] = url
        return url
    }

    private func forget(_ id: UUID) {
        urlCache[id] = nil
        unresolvable.remove(id)
    }

    /// Rewrites every item whose stored path no longer exists. One `stat` per
    /// item on the common path, so this stays cheap enough for panel launch.
    @discardableResult
    func repairStaleItems() -> Int {
        let fm = FileManager.default
        var fixed = 0
        for gi in config.groups.indices {
            for ii in config.groups[gi].items.indices {
                let item = config.groups[gi].items[ii]
                guard item.kind == .app || item.kind == .file || item.kind == .folder else { continue }
                if fm.fileExists(atPath: item.path) {
                    urlCache[item.id] = URL(fileURLWithPath: item.path)
                    continue
                }
                guard let url = item.resolveURL() else {
                    unresolvable.insert(item.id)
                    continue
                }
                if adopt(url, at: gi, index: ii) { fixed += 1 }
            }
        }
        if fixed > 0 { save() }
        return fixed
    }

    /// Adds identity anchors to configs written by builds that only stored paths.
    /// Runs from the settings host once; afterwards every item already has one.
    @discardableResult
    func backfillBookmarks() -> Int {
        let fm = FileManager.default
        var filled = 0
        for gi in config.groups.indices {
            for ii in config.groups[gi].items.indices {
                var item = config.groups[gi].items[ii]
                guard item.kind == .app || item.kind == .file || item.kind == .folder,
                      item.bookmark == nil,
                      fm.fileExists(atPath: item.path) else { continue }
                let anchors = GroupItem.identity(of: URL(fileURLWithPath: item.path))
                item.bookmark = anchors.bookmark
                if item.bundleID == nil { item.bundleID = anchors.bundleID }
                config.groups[gi].items[ii] = item
                filled += 1
            }
        }
        if filled > 0 { save() }
        return filled
    }

    /// Points a stored item at a new location and refreshes its anchors.
    @discardableResult
    func adopt(_ url: URL, forItem id: UUID) -> URL? {
        for gi in config.groups.indices {
            guard let ii = config.groups[gi].items.firstIndex(where: { $0.id == id }) else { continue }
            _ = adopt(url, at: gi, index: ii)
            save()
            return url
        }
        return nil
    }

    private func adopt(_ url: URL, at gi: Int, index ii: Int) -> Bool {
        var item = config.groups[gi].items[ii]
        guard item.path != url.path || item.bookmark == nil else { return false }
        item.path = url.standardizedFileURL.path
        if item.customName != true {
            item.name = GroupItem.resolvedName(for: url)
        }
        let anchors = GroupItem.identity(of: url)
        item.bookmark = anchors.bookmark
        if item.bundleID == nil { item.bundleID = anchors.bundleID }
        config.groups[gi].items[ii] = item
        urlCache[item.id] = url
        unresolvable.remove(item.id)
        return true
    }

    /// Last resort for a moved or renamed item: ask Spotlight for the same file
    /// name and adopt the first plausible hit. Only ever called from a click on
    /// a broken tile, never from the render path.
    func searchForMovedItem(_ item: GroupItem) -> URL? {
        guard item.kind == .app || item.kind == .file || item.kind == .folder else { return nil }
        let name = (item.path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["-name", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let fm = FileManager.default
        let candidates = (String(data: data, encoding: .utf8)?
            .split(separator: "\n").map(String.init) ?? [])
            .filter { ($0 as NSString).lastPathComponent == name }
            .filter { path in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
                switch item.kind {
                case .folder: return isDir.boolValue
                case .file: return !isDir.boolValue
                default: return true
                }
            }
            .sorted { $0.count < $1.count }
        guard let best = candidates.first else { return nil }
        return adopt(URL(fileURLWithPath: best), forItem: item.id)
    }

    func removeItem(_ id: UUID) {
        for gi in config.groups.indices {
            config.groups[gi].items.removeAll { $0.id == id }
        }
        forget(id)
        save()
    }

    func removeItem(_ id: UUID, from groupID: UUID) {
        guard let i = groupIndex(groupID) else { return }
        config.groups[i].items.removeAll { $0.id == id }
        forget(id)
        save()
    }

    func moveItem(_ id: UUID, in groupID: UUID, by offset: Int) {
        guard let gi = groupIndex(groupID),
              let from = config.groups[gi].items.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard to >= 0, to < config.groups[gi].items.count else { return }
        let item = config.groups[gi].items.remove(at: from)
        config.groups[gi].items.insert(item, at: to)
        save()
    }

    func group(with id: UUID) -> AppGroup? {
        config.groups.first { $0.id == id }
    }

    // MARK: - Names

    func renameItem(_ id: UUID, in groupID: UUID, to name: String) {
        guard let gi = groupIndex(groupID),
              let ii = config.groups[gi].items.firstIndex(where: { $0.id == id }) else { return }
        config.groups[gi].items[ii].name = name
        config.groups[gi].items[ii].customName = true
        save()
    }

    /// Re-resolve localized Finder names for existing entries. Explicitly invoked
    /// from settings, never on the panel hot path (MDItem lookups cost ~5 ms each).
    @discardableResult
    func refreshNames() -> Int {
        var changed = 0
        for gi in config.groups.indices {
            for ii in config.groups[gi].items.indices {
                let item = config.groups[gi].items[ii]
                guard item.customName != true,
                      item.kind == .app || item.kind == .file || item.kind == .folder else { continue }
                let url = url(for: item) ?? URL(fileURLWithPath: item.path)
                let fresh = GroupItem.resolvedName(for: url)
                if fresh != item.name {
                    config.groups[gi].items[ii].name = fresh
                    changed += 1
                }
            }
        }
        if changed > 0 { save() }
        return changed
    }
}
