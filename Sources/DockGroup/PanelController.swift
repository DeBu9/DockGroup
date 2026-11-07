import AppKit
import SwiftUI
import Combine

final class PanelNav: ObservableObject {
    @Published var levels: [NavLevel] = []
    /// Mirrors the currently displayed item count so the AppKit window can
    /// resize itself whenever the grid changes.
    @Published var itemCount: Int = 0
}

struct NavLevel: Identifiable {
    let id = UUID()
    let title: String
    let items: [GroupItem]
}

/// Borderless panels refuse key status by default, which breaks Esc handling.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController {
    static let shared = PanelController()

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyResignObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var idleExitTimer: Timer?
    private var sizeSink: AnyCancellable?
    private var navigation = PanelNav()
    private var resident = false
    /// Bumped whenever the panel is shown, so a pending exit from a previous
    /// close cannot kill a freshly reopened panel.
    private var exitGeneration = 0

    var isVisible: Bool { panel?.isVisible == true }

    /// - returns: false when the group no longer exists, so the caller can exit.
    @discardableResult
    func show(groupId: UUID, store: Store, resident: Bool = false) -> Bool {
        let showStart = CFAbsoluteTimeGetCurrent()
        exitGeneration += 1
        idleExitTimer?.invalidate()
        idleExitTimer = nil
        teardown()
        // A resident stub may have been edited from the settings window while
        // this process was idle; pick up the latest config each time.
        if resident { store.load() }
        guard let group = store.group(with: groupId) else { return false }
        self.resident = resident

        let nav = PanelNav()
        nav.itemCount = group.items.count
        navigation = nav

        let root = GroupPanelRoot(
            groupID: groupId,
            store: store,
            nav: nav,
            onClose: { [weak self] in self?.close() },
            onSettings: { AppDelegate.shared?.openSettingsWindow() }
        )
        let size = PanelLayout.size(for: nav.itemCount)
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)

        let window: NSPanel = KeyablePanel(contentRect: frame,
                                           styleMask: [.borderless, .fullSizeContentView],
                                           backing: .buffered, defer: false)
        window.contentView = makeContentView(root: root, frame: frame)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .popUpMenu
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.acceptsMouseMovedEvents = false

        position(window)
        if resident { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        if resident {
            // Activation is asynchronous; retry once so the panel really takes key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, self.panel === window else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        panel = window
        installMonitors()
        installAutoDismiss(for: window)

        sizeSink = nav.$itemCount
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window] count in
                guard let self = self, let window = window else { return }
                self.resize(window, itemCount: count)
            }

        if resident { logLaunchLatency(window: window, showStart: showStart) }
        return true
    }

    private func makeContentView(root: GroupPanelRoot, frame: NSRect) -> NSView {
        let container = NSView(frame: frame)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }

    /// Keep the horizontal centre and the bottom edge pinned: the panel grows
    /// upward from the Dock instead of jumping around on every drill-down.
    private func resize(_ window: NSPanel, itemCount: Int) {
        let size = PanelLayout.size(for: itemCount)
        let current = window.frame
        guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }
        var frame = NSRect(x: current.midX - size.width / 2,
                           y: current.minY,
                           width: size.width,
                           height: size.height)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8),
                                 visible.maxX - size.width - 8)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 8),
                                 visible.maxY - size.height - 8)
        }
        window.setFrame(frame, display: true)
    }

    private func position(_ window: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let visible = screen.visibleFrame
        let w = window.frame.width
        let h = window.frame.height
        var x: CGFloat
        var y: CGFloat

        if mouse.x - visible.minX < 130 {
            x = visible.minX + 72
            y = mouse.y - h / 2
        } else if visible.maxX - mouse.x < 130 {
            x = visible.maxX - w - 72
            y = mouse.y - h / 2
        } else {
            x = mouse.x - w / 2
            y = mouse.y + 22
        }

        x = min(max(x, visible.minX + 8), visible.maxX - w - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - h - 8)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async { self?.close() }
                return nil
            }
            return event
        }
    }

    /// Clicking outside, Esc, losing key-window status and a long idle close the
    /// panel. The process then exits (or briefly stays warm if opted in).
    private func installAutoDismiss(for window: NSPanel) {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            self?.close()
        }
        // Only watch key resignation if the panel really became key. On an
        // accessory app that never activates, observing app-level deactivation
        // would close the panel immediately after it appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, self.panel === window else { return }
            self.logState(tag: "settled", window: window)
            guard window.isKeyWindow else { return }
            self.keyResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    self?.close()
                }
        }
    }

    private func teardown() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let observer = keyResignObserver {
            NotificationCenter.default.removeObserver(observer)
            keyResignObserver = nil
        }
        sizeSink?.cancel()
        sizeSink = nil
        idleTimer?.invalidate()
        idleTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// By default the stub process exits as soon as the panel closes, leaving
    /// nothing running in the background. The optional keep-alive preference
    /// trades that for a 3-minute warm process so a second Dock click is faster.
    /// - parameter forceExit: used when handing off to the settings host, which
    ///   must exit even if keep-alive is enabled (otherwise the panel pops back).
    func close(forceExit: Bool = false) {
        teardown()
        guard resident else { return }
        idleExitTimer?.invalidate()
        idleExitTimer = nil

        if !forceExit && ResidentPreference.isEnabled {
            idleExitTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in
                NSApp.terminate(nil)
            }
            return
        }

        exitGeneration += 1
        let generation = exitGeneration
        // A short grace period lets a pending "open settings" handoff / app
        // activation finish. Reopening the panel cancels this pending exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard self?.exitGeneration == generation else { return }
            NSApp.terminate(nil)
        }
    }

    /// Records real cold-launch-to-panel time so the speedup is measurable.
    private func logLaunchLatency(window: NSPanel, showStart: CFAbsoluteTime) {
        let now = CFAbsoluteTimeGetCurrent()
        appendTiming(String(format: "render=%.1f ms  sinceLaunch=%.1f ms  active=%@ key=%@  epoch=%.3f  %@  group=%@\n",
                            (now - showStart) * 1000,
                            (now - appLaunchTime) * 1000,
                            NSApp.isActive ? "yes" : "no",
                            window.isKeyWindow ? "yes" : "no",
                            Date().timeIntervalSince1970,
                            Bundle.main.bundleIdentifier ?? "?",
                            LaunchMode.stubGroupID?.uuidString ?? "-"))
    }

    private func logState(tag: String, window: NSPanel) {
        appendTiming(String(format: "%@  active=%@ key=%@  epoch=%.3f\n",
                            tag,
                            NSApp.isActive ? "yes" : "no",
                            window.isKeyWindow ? "yes" : "no",
                            Date().timeIntervalSince1970))
    }

    private func appendTiming(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DockGroup/launch-timing.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// MARK: - Glass styling

/// macOS 26+ uses the system Liquid Glass material; older systems fall back to
/// a regular material so the same build still runs from macOS 13 upwards.
private struct GlassBackdrop: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
            )
        } else {
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        }
    }
}

private struct GlassCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.20)
                          : Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(width: 27, height: 27)
            .background(
                Circle().fill(configuration.isPressed
                              ? Color.primary.opacity(0.20)
                              : Color.primary.opacity(0.08))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.14)
                          : Color.primary.opacity(0.001))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GroupPanelRoot: View {
    let groupID: UUID
    @ObservedObject var store: Store
    @ObservedObject var nav: PanelNav
    let onClose: () -> Void
    let onSettings: () -> Void

    private var rootGroup: AppGroup? { store.group(with: groupID) }
    private var items: [GroupItem] { nav.levels.last?.items ?? rootGroup?.items ?? [] }
    private var title: String { nav.levels.last?.title ?? rootGroup?.name ?? "组" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            content
            Divider().opacity(0.35)
            footer
        }
        .frame(width: PanelLayout.size(for: nav.itemCount).width,
               height: PanelLayout.size(for: nav.itemCount).height)
        .background { GlassBackdrop() }
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                .padding(1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !nav.levels.isEmpty {
                Button(action: pop) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(GlassIconButtonStyle())
            }
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button("编辑", action: onSettings)
                .buttonStyle(GlassCapsuleButtonStyle())
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(GlassIconButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: PanelLayout.headerHeight)
    }

    private var content: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("组内还没有项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("在设置窗口里添加应用、文件或网页")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(PanelLayout.cell.width),
                                                           spacing: PanelLayout.spacing),
                                       count: PanelLayout.columnCount(for: nav.itemCount)),
                        spacing: PanelLayout.spacing
                    ) {
                        ForEach(items) { item in tile(item) }
                    }
                    .frame(width: PanelLayout.gridWidth(for: nav.itemCount))
                    .padding(.vertical, PanelLayout.gridPadding)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(items.count) 项")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("点击外部或 Esc 关闭")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .frame(height: PanelLayout.footerHeight)
    }

    private func tile(_ item: GroupItem) -> some View {
        Button(action: { activate(item) }) {
            VStack(spacing: 6) {
                icon(for: item)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
                Text(item.name)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(width: PanelLayout.cell.width, height: PanelLayout.cell.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .help(item.path)
        .contextMenu {
            if item.kind == .folder {
                Button("在面板中展开") { expand(item) }
                Button("在访达中打开") { reveal(item) }
            } else {
                Button("在访达中显示") { reveal(item) }
            }
        }
    }

    private func icon(for item: GroupItem) -> Image {
        switch item.kind {
        case .web:
            return Image(systemName: "globe")
        case .subgroup:
            return Image(systemName: "square.stack.3d.up.fill")
        default:
            if FileManager.default.fileExists(atPath: item.path) {
                return Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
            }
            return Image(systemName: "questionmark.app")
        }
    }

    private func push(_ title: String, _ children: [GroupItem]) {
        nav.levels.append(NavLevel(title: title, items: children))
        nav.itemCount = children.count
    }

    private func pop() {
        guard !nav.levels.isEmpty else { return }
        nav.levels.removeLast()
        nav.itemCount = items.count
    }

    private func activate(_ item: GroupItem) {
        switch item.kind {
        case .folder:
            expand(item)
            return
        case .subgroup:
            if let id = UUID(uuidString: item.path), let group = store.group(with: id) {
                push(group.name, group.items)
            }
            return
        case .web:
            if let url = URL(string: item.path) {
                NSWorkspace.shared.open(url)
            }
        default:
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
        onClose()
    }

    private func expand(_ item: GroupItem) {
        let url = URL(fileURLWithPath: item.path)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let children = contents.prefix(80).map { GroupItem.from(url: $0, localized: false) }
        push(item.name, children)
    }

    private func reveal(_ item: GroupItem) {
        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        onClose()
    }
}
