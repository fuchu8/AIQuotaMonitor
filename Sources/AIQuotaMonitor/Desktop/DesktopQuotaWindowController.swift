import AppKit
import SwiftUI
import Combine

/// 可拖动的桌面常驻信息窗。
///
/// - 窗口层级：`.normal`（可被普通应用盖住，不压全屏）
/// - 不使用 statusBar / floating / fullScreenAuxiliary
/// - 不抢键窗焦点（NonKeyWindow）
/// - `fullScreenNone`：不进入全屏 Space；全屏期间 orderOut，回到桌面再恢复
@MainActor
final class DesktopQuotaWindowController: NSObject, NSWindowDelegate {
    private var window: NonKeyDesktopWindow?
    private var rootView: DesktopWindowRootView?
    private var hosting: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var saving = false
    /// 用户仍想显示，但因全屏临时收起（不改 `desktopWindowVisible`）。
    private var suppressedForFullscreen = false

    private let settings = SettingsStore.shared
    private let store = QuotaStore.shared

    func start() {
        settings.$desktopWindowVisible
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    if self.suppressedForFullscreen { return }
                    self.show()
                } else {
                    self.hide()
                }
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clampToScreens() }
        }

        installWorkspaceObservers()

        if settings.desktopWindowVisible {
            show()
        }
        reconcileFullscreenVisibility()
    }

    func show() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        if FullscreenPresence.frontmostLooksFullScreen() {
            suppressedForFullscreen = true
            window.orderOut(nil)
            if !settings.desktopWindowVisible {
                settings.desktopWindowVisible = true
            }
            return
        }
        suppressedForFullscreen = false
        clampToScreens()
        window.invalidateShadow()
        // orderFront 不激活应用，避免抢焦点；accessory app 也更合适
        window.orderFront(nil)
        DispatchQueue.main.async { [weak window] in
            window?.invalidateShadow()
        }
        if !settings.desktopWindowVisible {
            settings.desktopWindowVisible = true
        }
    }

    func hide() {
        window?.orderOut(nil)
        suppressedForFullscreen = false
        if settings.desktopWindowVisible {
            settings.desktopWindowVisible = false
        }
    }

    func toggle() {
        if settings.desktopWindowVisible { hide() } else { show() }
    }

    private func buildWindow() {
        let root = AnyView(
            DesktopQuotaView()
                .environmentObject(store)
                .environmentObject(settings)
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: DesktopFrameMath.defaultSize)

        let rootView = DesktopWindowRootView(frame: NSRect(origin: .zero, size: DesktopFrameMath.defaultSize))
        rootView.embed(hosting: host)

        let win = NonKeyDesktopWindow(
            contentRect: NSRect(origin: restoredOrigin(), size: DesktopFrameMath.defaultSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = rootView
        win.delegate = self
        win.isOpaque = false
        win.backgroundColor = .clear
        // 阴影跟 contentView 的圆角走，不用 SwiftUI shadow（会被窗体裁成底角黑边）。
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        // SwiftUI 会吞鼠标；拖动条是 contentView 上叠层的 AppKit DesktopWindowDragSurface。
        win.isMovableByWindowBackground = false
        win.isMovable = true
        win.level = .normal
        // 不跟进全屏 Space；禁止与全屏辅助层级方案。
        win.collectionBehavior = [.managed, .fullScreenNone]
        win.title = "AI Quota 桌面窗"
        win.setAccessibilityTitle("AI Quota 桌面窗")

        self.window = win
        self.rootView = rootView
        self.hosting = host
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.reconcileFullscreenVisibility()
                }
            }
            workspaceObservers.append(token)
        }
    }

    /// 全屏：收起桌面窗（保留用户「显示」偏好）；回桌面：按偏好恢复。
    private func reconcileFullscreenVisibility() {
        let fullscreen = FullscreenPresence.frontmostLooksFullScreen()
        guard let window else {
            suppressedForFullscreen = fullscreen && settings.desktopWindowVisible
            return
        }
        if fullscreen {
            if settings.desktopWindowVisible || window.isVisible {
                suppressedForFullscreen = true
                window.orderOut(nil)
            }
            return
        }
        if suppressedForFullscreen {
            suppressedForFullscreen = false
            if settings.desktopWindowVisible {
                clampToScreens()
                window.orderFront(nil)
            }
        }
    }

    private func restoredOrigin() -> CGPoint {
        let screens = NSScreen.screens.map { (visible: $0.visibleFrame, isMain: $0 == NSScreen.main) }
        if let x = settings.desktopWindowX, let y = settings.desktopWindowY {
            let origin = CGPoint(x: x, y: y)
            let visible = DesktopFrameMath.preferredVisibleFrame(
                forOrigin: origin,
                size: DesktopFrameMath.defaultSize,
                screens: screens
            )
            return DesktopFrameMath.clampOrigin(origin, size: DesktopFrameMath.defaultSize, visible: visible)
        }
        let visible = NSScreen.main?.visibleFrame
            ?? screens.first?.visible
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        return DesktopFrameMath.defaultOrigin(inVisible: visible)
    }

    private func clampToScreens() {
        guard let window else { return }
        let screens = NSScreen.screens.map { (visible: $0.visibleFrame, isMain: $0 == NSScreen.main) }
        let origin = window.frame.origin
        let visible = DesktopFrameMath.preferredVisibleFrame(
            forOrigin: origin,
            size: window.frame.size,
            screens: screens
        )
        let clamped = DesktopFrameMath.clampOrigin(origin, size: window.frame.size, visible: visible)
        if clamped != origin {
            window.setFrameOrigin(clamped)
            persistOrigin(clamped)
        }
    }

    private func persistOrigin(_ origin: CGPoint) {
        saving = true
        settings.desktopWindowX = origin.x
        settings.desktopWindowY = origin.y
        saving = false
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !saving, let window else { return }
        persistOrigin(window.frame.origin)
    }

    func windowWillClose(_ notification: Notification) {
        settings.desktopWindowVisible = false
    }
}

/// 普通层级、不可成为 key/main，减少抢焦点。
final class NonKeyDesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
