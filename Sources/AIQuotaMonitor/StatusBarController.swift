import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let aqmOpenPanel = Notification.Name("AIQuotaMonitorOpenPanel")
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let store = QuotaStore.shared
    private let settings = SettingsStore.shared
    private let chrome = PanelChrome.shared
    private let hosting: NSHostingController<AnyView>
    private var cancellables = Set<AnyCancellable>()

    /// 详情使用系统 NSPopover；不要改回高层级 NSPanel（会钉住全屏菜单栏）。
    private let popover = NSPopover()

    /// 仅在 popover 显示期间存在的本地点击监视；不是长期全局 NSEvent 监视。
    private var clickOutsideMonitor: Any?
    /// 悬停打开后/会话内轮询（桥接图标↔面板）；离开且关闭后可停。
    private var hoverPollTimer: Timer?
    /// 关闭态兜底：用 mouseLocation 判断是否在猫图标上（非 NSEvent.addGlobalMonitor）。
    /// TrackingArea 在状态栏 + 合成鼠标上常收不到 entered，不能单独依赖。
    private var idleArmTimer: Timer?
    private var hoverSensor: StatusBarHoverSensor?
    private var hostingPinned = false
    private var popoverTrackingArea: NSTrackingArea?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// 全屏期间关闭悬停自动打开，避免隐藏菜单栏被感应区/Popover 撑住。
    private var suppressHoverInFullscreen = false

    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private let showDelay: TimeInterval = 0.12
    private let hideDelay: TimeInterval = 0.30

    override init() {
        hosting = NSHostingController(
            rootView: AnyView(
                PanelView()
                    .environmentObject(QuotaStore.shared)
                    .environmentObject(SettingsStore.shared)
                    .environmentObject(PanelChrome.shared)
                    .background(Color.clear)
            )
        )
        super.init()

        // 尺寸由 contentSize 显式控制，hosting 再钉满 popover 内容区，避免左偏/顶底裁切。
        hosting.sizingOptions = []

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.setButtonType(.momentaryChange)
            button.setAccessibilityTitle("AI Quota Monitor")
            button.setAccessibilityRole(.button)
            button.imagePosition = .imageOnly
            installHoverSensor(on: button)
        }
        startIdleArmTimer()
        installFullscreenObservers()

        // applicationDefined：由悬停逻辑关闭，避免 transient 与移入面板抢关闭。
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hosting
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        updateLabel()
        bind()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openPanelFromNotification),
            name: .aqmOpenPanel,
            object: nil
        )
        reconcileFullscreenHoverPolicy()
        AppLog.write("状态项已创建（仅图标 · 悬停详情）")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func bind() {
        Publishers.CombineLatest4(store.$codex, store.$cursor, store.$opencode, store.$grokbot)
            .combineLatest(settings.$menuBarMetric, settings.$menuBarAggregate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &cancellables)
    }

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip
        button.image = statusImage()
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        statusItem.length = NSStatusItem.squareLength
        button.setAccessibilityLabel("AI Quota Monitor")
        button.setAccessibilityValue(tooltip.replacingOccurrences(of: "\n", with: "，"))
    }

    private func statusImage() -> NSImage? {
        if let cat = Self.catIcon() { return cat }
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                            accessibilityDescription: "AI 额度")
        image?.isTemplate = true
        return image
    }

    private static var cachedCatIcon: NSImage?

    private static func catIcon() -> NSImage? {
        if let cachedCatIcon { return cachedCatIcon }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = false
        var added = false
        let candidates: [(name: String, scale: CGFloat)] = [
            ("StatusBarCat", 1),
            ("StatusBarCat@2x", 2),
            ("StatusBarCat@3x", 3)
        ]
        for item in candidates {
            let urls = [
                Bundle.main.url(forResource: item.name, withExtension: "png"),
                URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/\(item.name).png")
            ]
            guard let url = urls.compactMap({ $0 }).first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep)
            added = true
        }
        guard added else { return nil }
        cachedCatIcon = image
        return image
    }

    private var tooltip: String {
        var lines: [String] = []
        func append(prefix: String, window: QuotaWindow?, stale: Bool, error: String?) {
            if let window {
                let metric = settings.menuBarMetric == .remaining
                    ? "剩余 \(Int(window.remainingPercent))%"
                    : "已用 \(Int(window.usedPercent))%"
                lines.append("\(prefix) \(window.title)：\(metric)\(stale ? "（过期）" : "")")
            } else if let error {
                lines.append("\(prefix)：\(error)")
            }
        }
        let codexWindow = settings.menuBarAggregate == .tightest
            ? store.codex.tightestWindow
            : store.codex.primaryWindow
        append(prefix: "Codex", window: codexWindow, stale: store.codex.quotaStale, error: store.codex.errorMessage)
        append(prefix: "Cursor", window: store.cursor.menuBarWindow, stale: store.cursor.quotaStale, error: store.cursor.errorMessage)
        append(prefix: "OpenCode Go", window: store.opencode.tightestWindow, stale: store.opencode.quotaStale, error: store.opencode.errorMessage)
        append(prefix: "Grok Bot", window: store.grokbot.tightestWindow, stale: store.grokbot.quotaStale, error: store.grokbot.errorMessage)
        if lines.isEmpty { lines.append("暂无额度数据，悬停查看详情") }
        lines.append("悬停图标查看详情，移开后自动关闭")
        return lines.joined(separator: "\n")
    }

    // MARK: - 悬停开合（TrackingArea + mouseLocation 轮询；无长期全局 NSEvent 监视）

    private func installHoverSensor(on button: NSStatusBarButton) {
        let sensor = StatusBarHoverSensor(frame: button.bounds)
        sensor.autoresizingMask = [.width, .height]
        sensor.onEnter = { [weak self] in
            self?.handleIconPointerEnter()
        }
        sensor.onExit = { [weak self] in
            self?.handleIconPointerExit()
        }
        button.addSubview(sensor)
        hoverSensor = sensor
        sensor.updateTrackingAreas()
    }

    private func handleIconPointerEnter() {
        guard !suppressHoverInFullscreen else { return }
        startHoverSession()
        cancelPendingHide()
        scheduleShow()
    }

    private func handleIconPointerExit() {
        scheduleHideIfNeeded()
    }

    private func installFullscreenObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.reconcileFullscreenHoverPolicy()
                }
            }
            workspaceObservers.append(token)
        }
    }

    private func reconcileFullscreenHoverPolicy() {
        let fullscreen = FullscreenPresence.frontmostLooksFullScreen()
        suppressHoverInFullscreen = fullscreen
        if fullscreen {
            cancelPendingShow()
            if popover.isShown {
                popover.performClose(nil)
            }
            stopHoverSessionIfIdle()
        }
    }

    /// 关闭态持续轻量轮询：仅比较 mouseLocation 与图标屏上矩形。
    private func startIdleArmTimer() {
        guard idleArmTimer == nil else { return }
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.evaluateIdleArm()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleArmTimer = timer
    }

    private func evaluateIdleArm() {
        if suppressHoverInFullscreen {
            cancelPendingShow()
            return
        }
        // 已打开时交给会话轮询。
        if popover.isShown {
            if hoverPollTimer == nil { startHoverSession() }
            return
        }
        if isMouseOverStatusButton() {
            startHoverSession()
            cancelPendingHide()
            armShowIfNeeded()
        } else {
            cancelPendingShow()
        }
    }

    /// 只在没有待打开任务时调度一次；会话轮询不得反复重置 showDelay。
    private func armShowIfNeeded() {
        guard showWorkItem == nil, !popover.isShown else { return }
        scheduleShow()
    }

    private func scheduleShow() {
        showWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showWorkItem = nil
            if self.isMouseOverButtonOrPopover() {
                self.presentIfNeeded()
            }
        }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    private func scheduleHideIfNeeded() {
        showWorkItem?.cancel()
        showWorkItem = nil
        guard hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil
            // 间隙：若此时已在图标或面板上，取消关闭
            if self.isMouseOverButtonOrPopover() { return }
            if self.popover.isShown {
                self.popover.performClose(nil)
            }
            self.stopHoverSessionIfIdle()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func cancelPendingHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func cancelPendingShow() {
        showWorkItem?.cancel()
        showWorkItem = nil
    }

    private func evaluatePointerHover() {
        if suppressHoverInFullscreen {
            cancelPendingShow()
            if popover.isShown {
                scheduleHideIfNeeded()
            } else {
                stopHoverSessionIfIdle()
            }
            return
        }
        if isMouseOverButtonOrPopover() {
            cancelPendingHide()
            // 与 idleArm 相同：已有 showWorkItem 时不得再 scheduleShow，否则延迟被永久推后。
            armShowIfNeeded()
        } else {
            cancelPendingShow()
            if popover.isShown {
                scheduleHideIfNeeded()
            } else {
                stopHoverSessionIfIdle()
            }
        }
    }

    private func startHoverSession() {
        guard hoverPollTimer == nil else { return }
        // 0.12s 轮询桥接图标↔面板间隙；用 mouseLocation，不是 NSEvent 全局监视。
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.evaluatePointerHover()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPollTimer = timer
    }

    private func stopHoverSessionIfIdle() {
        guard !popover.isShown, !isMouseOverButtonOrPopover() else { return }
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    /// Cocoa 屏幕坐标（底左原点）。优先 window 转换；accessibilityFrame 作兜底。
    private func statusButtonScreenRect() -> CGRect? {
        guard let button = statusItem.button else { return nil }
        if let window = button.window {
            let rectInWindow = button.convert(button.bounds, to: nil)
            let screen = window.convertToScreen(rectInWindow)
            if screen.width > 1, screen.height > 1 {
                return screen
            }
        }
        let ax = button.accessibilityFrame()
        if ax.width > 1, ax.height > 1 {
            return ax
        }
        return nil
    }

    private func isMouseOverStatusButton() -> Bool {
        guard let screenRect = statusButtonScreenRect() else { return false }
        // 状态栏命中区偏小，略放大以免边缘抖出。
        return screenRect.insetBy(dx: -6, dy: -8).contains(NSEvent.mouseLocation)
    }

    private func isMouseOverButtonOrPopover() -> Bool {
        if isMouseOverStatusButton() { return true }
        if let popWindow = hosting.view.window {
            // 含箭头方向的小间隙
            if popWindow.frame.insetBy(dx: -8, dy: -10).contains(NSEvent.mouseLocation) {
                return true
            }
        }
        return false
    }

    // MARK: 详情（NSPopover）

    @objc private func openPanelFromNotification() {
        cancelPendingHide()
        presentIfNeeded()
    }

    func presentIfNeeded() {
        guard !suppressHoverInFullscreen else { return }
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            presentPopover(from: button)
        }
    }

    /// 点击仍可作为兼容入口；关闭以移开为准，不要求再点一次。
    @objc private func togglePopover() {
        cancelPendingHide()
        cancelPendingShow()
        if popover.isShown {
            // 若鼠标仍在图标上，点击不强制关掉（避免与悬停打架）；移开后会关。
            if isMouseOverButtonOrPopover() {
                return
            }
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        presentPopover(from: button)
    }

    func popoverDidClose(_ notification: Notification) {
        store.setPanelOpen(false)
        removeClickOutsideMonitor()
        removePopoverTracking()
        stopHoverSessionIfIdle()
        updateLabel()
    }

    func popoverDidShow(_ notification: Notification) {
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        pinHostingToPopoverContent()
        if let window = popover.contentViewController?.view.window {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        installPopoverTracking()
        updateLabel()
        installClickOutsideMonitor()
    }

    private func presentPopover(from button: NSStatusBarButton) {
        let screenCap = maxPopoverHeight(for: button)
        let height = min(PanelChrome.preferredHeight, screenCap)
        chrome.viewportHeight = height
        let size = NSSize(width: PanelChrome.width, height: height)
        hosting.preferredContentSize = size
        popover.contentSize = size
        syncHostingFrame(to: size)
        hosting.view.layoutSubtreeIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        pinHostingToPopoverContent()
        startHoverSession()
        store.setPanelOpen(true)
        updateLabel()
    }

    private func syncHostingFrame(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        hosting.view.setFrameSize(size)
        hosting.view.setFrameOrigin(.zero)
    }

    /// 把 hosting 钉满 popover 内容区，消除左偏右空与顶底被裁。
    private func pinHostingToPopoverContent() {
        guard let superview = hosting.view.superview else {
            syncHostingFrame(to: popover.contentSize)
            return
        }
        if !hostingPinned {
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: superview.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: superview.bottomAnchor)
            ])
            hostingPinned = true
        }
        superview.layoutSubtreeIfNeeded()
        chrome.viewportHeight = hosting.view.bounds.height > 0
            ? hosting.view.bounds.height
            : popover.contentSize.height
    }

    private func maxPopoverHeight(for button: NSStatusBarButton) -> CGFloat {
        let screen = button.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 800
        // 为菜单栏与 popover 箭头/边框留空，避免顶底贴边被裁。
        return max(320, min(PanelChrome.preferredHeight, visible - 72))
    }

    private func installPopoverTracking() {
        removePopoverTracking()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: ["zone": "popover"]
        )
        popoverTrackingArea = area
        hosting.view.addTrackingArea(area)
    }

    private func removePopoverTracking() {
        if let popoverTrackingArea {
            hosting.view.removeTrackingArea(popoverTrackingArea)
            self.popoverTrackingArea = nil
        }
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.window === self.popover.contentViewController?.view.window {
                return event
            }
            if self.isClickOnStatusButton(event) {
                return event
            }
            self.popover.performClose(nil)
            return event
        }
    }

    private func isClickOnStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              event.window === buttonWindow else { return false }
        let local = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(local)
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }
}
