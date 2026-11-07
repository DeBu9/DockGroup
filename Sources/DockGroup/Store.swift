import Foundation
import Combine

final class Store: ObservableObject {
    @Published var config: Config = .empty

    let rootDir: URL
    let stubsDir: URL
    let backupDir: URL
    private let configURL: URL

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

    func removeItem(_ id: UUID, from groupID: UUID) {
        guard let i = groupIndex(groupID) else { return }
        config.groups[i].items.removeAll { $0.id == id }
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
                let fresh = GroupItem.resolvedName(for: URL(fileURLWithPath: item.path))
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
