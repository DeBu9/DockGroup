import SwiftUI
import AppKit
import Combine

final class SettingsState: ObservableObject {
    static let shared = SettingsState()

    @Published var selectedID: UUID?
    @Published var status = "就绪"
    @Published var webSheet = false
    @Published var webURL = ""
    @Published var webName = ""
    @Published var confirmSync = false
    @Published var confirmRemove = false
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var state = SettingsState.shared

    private var dock: DockManager { DockManager(store: store) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $state.selectedID) {
                    ForEach(store.config.groups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .listStyle(.sidebar)
                HStack(spacing: 6) {
                    Button(action: addGroup) {
                        Image(systemName: "plus")
                    }
                    Button(action: removeSelectedGroup) {
                        Image(systemName: "minus")
                    }
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 170)

            Divider()

            if let id = state.selectedID, let group = store.group(with: id) {
                detail(group)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("选择或新建一个组")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 580)
        .onAppear {
            if state.selectedID == nil { state.selectedID = store.config.groups.first?.id }
            let renamed = store.refreshNames()
            if renamed > 0 {
                state.status = "已按访达中文名更新 \(renamed) 个项目"
            }
        }
    }

    @ViewBuilder
    private func detail(_ group: AppGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("组名", text: Binding(
                    get: { store.group(with: group.id)?.name ?? "" },
                    set: { store.renameGroup(group.id, to: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                Spacer()
                Button("添加应用 / 文件") { pickFiles(groupID: group.id) }
                Button("添加网页") { state.webSheet = true }
                Menu("引用子组") {
                    ForEach(store.config.groups.filter { $0.id != group.id }) { target in
                        Button(target.name) {
                            store.addItem(GroupItem(name: target.name,
                                                   path: target.id.uuidString,
                                                   kind: .subgroup),
                                          to: group.id)
                        }
                    }
                    if store.config.groups.count < 2 {
                        Text("先创建另一个组")
                    }
                }
            }

            List {
                ForEach(group.items) { item in
                    HStack(spacing: 8) {
                        itemIcon(item).frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            TextField("名称", text: Binding(
                                get: {
                                    store.group(with: group.id)?.items
                                        .first(where: { $0.id == item.id })?.name ?? item.name
                                },
                                set: { store.renameItem(item.id, in: group.id, to: $0) }
                            ))
                            .textFieldStyle(.plain)
                            .lineLimit(1)
                            Text(item.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(item.kind.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(action: { store.moveItem(item.id, in: group.id, by: -1) }) {
                            Image(systemName: "arrow.up")
                        }.buttonStyle(.plain)
                        Button(action: { store.moveItem(item.id, in: group.id, by: 1) }) {
                            Image(systemName: "arrow.down")
                        }.buttonStyle(.plain)
                        Button(action: { store.removeItem(item.id, from: group.id) }) {
                            Image(systemName: "trash")
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 3)
                }
            }
            .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
                handleDrop(providers, into: group.id)
            }

            HStack(spacing: 8) {
                Button("同步到 Dock…") { state.confirmSync = true }
                Button("从 Dock 移除所有组") { state.confirmRemove = true }
                Button("恢复最近备份") { state.status = dock.restoreLastBackup() }
                Button("刷新系统中文名") {
                    let n = store.refreshNames()
                    state.status = n > 0 ? "已更新 \(n) 个名称为访达显示名" : "名称已是最新"
                }
                Spacer()
            }

            Divider()

            Toggle(isOn: Binding(
                get: { MenuBarPreference.isVisible },
                set: { newValue in
                    MenuBarPreference.isVisible = newValue
                    AppDelegate.shared?.setMenuBarVisible(newValue)
                }
            )) {
                Text("在顶部菜单栏显示图标（默认关闭）")
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: Binding(
                get: { ResidentPreference.isEnabled },
                set: { newValue in
                    ResidentPreference.isEnabled = newValue
                    state.status = newValue
                        ? "已开启后台驻留：面板关闭后保留 3 分钟（约 21 MB 内存）"
                        : "已关闭后台驻留：面板关闭后立即退出进程"
                }
            )) {
                Text("面板关闭后保留后台 3 分钟（加快再次打开，默认关闭）")
            }
            .toggleStyle(.checkbox)

            Text(state.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            Text("默认零后台：面板关闭后立即退出进程，每次点击约 140 ms。开启上面的驻留开关后，进程会保留 3 分钟（约 21 MB 内存、0% CPU），期间再次点击约 38 ms。名称可直接点击修改，改过的名称不会被自动刷新覆盖；「刷新系统中文名」会把未自定义的条目改为访达显示名。升级主程序后请点一次「同步到 Dock」以更新占位 app；同步前会自动备份 com.apple.dock。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("同步到 Dock", isPresented: $state.confirmSync) {
            Button("取消", role: .cancel) {}
            Button("同步") {
                state.status = dock.syncToDock()
                AppDelegate.shared?.rebuildMenu()
            }
        } message: {
            Text("将备份 Dock 配置、生成占位 app、写入 Dock 左侧并重启 Dock。原有图标不会丢失。")
        }
        .alert("从 Dock 移除所有组", isPresented: $state.confirmRemove) {
            Button("取消", role: .cancel) {}
            Button("移除") { state.status = dock.removeFromDock() }
        } message: {
            Text("只移除 DockGroup 的占位图标，其他 Dock 图标不动。")
        }
        .sheet(isPresented: $state.webSheet) {
            webEntry(groupID: group.id)
        }
    }

    @ViewBuilder
    private func webEntry(groupID: UUID) -> some View {
        VStack(spacing: 12) {
            Text("添加网页").font(.headline)
            TextField("名称（可留空）", text: $state.webName)
                .textFieldStyle(.roundedBorder)
            TextField("https://example.com", text: $state.webURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { state.webSheet = false }
                Spacer()
                Button("添加") {
                    var raw = state.webURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return }
                    if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
                        raw = "https://" + raw
                    }
                    let trimmedName = state.webName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = trimmedName.isEmpty ? (URL(string: raw)?.host ?? raw) : trimmedName
                    store.addItem(GroupItem(name: name, path: raw, kind: .web), to: groupID)
                    state.webName = ""
                    state.webURL = ""
                    state.webSheet = false
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private func itemIcon(_ item: GroupItem) -> some View {
        if item.kind == .web {
            Image(systemName: "globe")
        } else if item.kind == .subgroup {
            Image(systemName: "square.stack.3d.up.fill")
        } else if FileManager.default.fileExists(atPath: item.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable()
        } else {
            Image(systemName: "questionmark.app")
        }
    }

    // MARK: - Actions

    private func addGroup() {
        let group = AppGroup(name: "新组")
        store.config.groups.append(group)
        store.save()
        state.selectedID = group.id
        AppDelegate.shared?.rebuildMenu()
    }

    private func removeSelectedGroup() {
        guard let id = state.selectedID else { return }
        store.removeGroup(id)
        state.selectedID = store.config.groups.first?.id
        AppDelegate.shared?.rebuildMenu()
    }

    private func pickFiles(groupID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择应用、文件或文件夹"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            store.addItem(GroupItem.from(url: url), to: groupID)
        }
        state.status = "已添加 \(panel.urls.count) 项"
    }

    private func handleDrop(_ providers: [NSItemProvider], into groupID: UUID) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                var url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                }
                guard let url = url else { return }
                DispatchQueue.main.async {
                    store.addItem(GroupItem.from(url: url), to: groupID)
                }
            }
        }
        return true
    }
}
