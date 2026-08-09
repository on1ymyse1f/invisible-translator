import AppKit
import ApplicationServices
import Carbon.HIToolbox

@main
enum ClaudePromptTranslatorMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?
    private var showExistingInstanceObserver: NSObjectProtocol?
    private var contextTimer: Timer?
    private var existingInstanceAtLaunch: NSRunningApplication?
    private var handledIncomingURL = false
    private var lastAutoRevealedProcessIdentifier: pid_t?
    private var lastAutoRevealAt: Date?
    private lazy var usageGuideController = UsageGuideController(model: model)
    private let hotKeySignature = OSType(0x43505431) // "CPT1"
    private let hotKeyID = UInt32(1)
    private let showExistingInstanceNotification = Notification.Name("local.codex.ClaudePromptTranslator.show")

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if let selfTest = SelfTestRunner.configuration(from: CommandLine.arguments) {
            SelfTestRunner.run(selfTest)
            return
        }
#endif

        existingInstanceAtLaunch = findExistingInstance()

        configureSingleInstanceObserver()
        configureStatusItem()
        configureHotkeys()
        configureClaudeDetection()
        model.startSelectionMonitoring()
        if model.translatorEnabled, model.unifiedBarEnabled {
            model.unifiedBarController.start()
        }
        scheduleInitialAIRevealChecks()
        model.statusMessage = AccessibilityPermission.isTrusted
            ? "已就绪：在任意 App 选中文字，点击浮动“翻译”或按 ⌃⌥T。"
            : "请授予辅助功能权限，以读取跨应用选区。"

        if existingInstanceAtLaunch == nil,
           usageGuideController.shouldPresentAutomatically {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.usageGuideController.show()
            }
        }

#if DEBUG
        if SelectionDiagnostics.isEnabled,
           let rawProcessIdentifier = ProcessInfo.processInfo.environment["CPT_DEBUG_SELECTION_PID"],
           let processIdentifier = pid_t(rawProcessIdentifier) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.model.runSelectionDebugProbe(processIdentifier: processIdentifier)
            }
        }
#endif

        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.model.revealEdgeBar()
            }
        }

        if existingInstanceAtLaunch != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.exitDuplicateIfNoURLWasHandled()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        usageGuideController.show()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledIncomingURL = true
        if existingInstanceAtLaunch != nil {
            for url in urls {
                forwardURLToExistingInstance(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
            return
        }

        for url in urls {
            handleURL(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyEventHandler {
            RemoveEventHandler(hotKeyEventHandler)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let showExistingInstanceObserver {
            DistributedNotificationCenter.default().removeObserver(showExistingInstanceObserver)
        }
        contextTimer?.invalidate()
        model.stopSelectionMonitoring()
        model.dismissSelectionOverlay()
        model.unifiedBarController.stop()
    }

    @objc private func showInputPanel() {
        model.showPanel(reason: .manual)
    }

    @objc private func showUsageGuide() {
        usageGuideController.show()
    }

    @objc private func revealEdgeBar() {
        model.revealEdgeBar()
    }

    @objc private func translateCurrentInput() {
        model.translateCurrentInputInline()
    }

    @objc private func translateLatestResponse() {
        model.unifiedBarController.translateLatestResponse()
    }

    @objc private func copyLatestResponse() {
        model.unifiedBarController.copyResponseTranslation()
    }

    @objc private func translateCurrentSelection() {
        model.translateCurrentSelection()
    }

    @objc private func translateScreenRegion() {
        model.translateScreenRegion()
    }

    @objc private func toggleSubtitleTranslation() {
        if model.subtitleTranslationActive {
            model.stopSubtitleTranslation()
        } else {
            model.startSubtitleTranslation()
        }
        configureStatusItem()
    }

    @objc private func chooseSubtitleBilingual() {
        model.subtitleDisplayMode = .bilingual
        configureStatusItem()
    }

    @objc private func chooseSubtitleTranslationOnly() {
        model.subtitleDisplayMode = .translationOnly
        configureStatusItem()
    }

    @objc private func chooseSelectionBilingual() {
        model.selectionDisplayMode = .bilingual
        configureStatusItem()
    }

    @objc private func chooseSelectionTranslationOnly() {
        model.selectionDisplayMode = .translationOnly
        configureStatusItem()
    }

    @objc private func chooseSubtitleDarkStyle() {
        model.subtitleOverlayStyle = .dark
        configureStatusItem()
    }

    @objc private func chooseSubtitleLightStyle() {
        model.subtitleOverlayStyle = .light
        configureStatusItem()
    }

    @objc private func chooseSubtitleHighContrastStyle() {
        model.subtitleOverlayStyle = .highContrast
        configureStatusItem()
    }

    @objc private func chooseSubtitleSmallFont() {
        model.subtitleFontSize = 18
        configureStatusItem()
    }

    @objc private func chooseSubtitleMediumFont() {
        model.subtitleFontSize = 22
        configureStatusItem()
    }

    @objc private func chooseSubtitleLargeFont() {
        model.subtitleFontSize = 28
        configureStatusItem()
    }

    @objc private func copyLastTranslation() {
        model.copyLastTranslation()
    }

    @objc private func clearResponseTranslation() {
        model.clearResponseTranslation()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        model.revealEdgeBar()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleTranslatorEnabled(_ sender: NSMenuItem) {
        model.setTranslatorEnabled(!model.translatorEnabled)
        configureStatusItem()
    }

    @objc private func toggleAutoShow(_ sender: NSMenuItem) {
        model.autoShowWhenClaudeIsActive.toggle()
        sender.state = model.autoShowWhenClaudeIsActive ? .on : .off
        configureStatusItem()
    }

    @objc private func toggleSelectionDetection(_ sender: NSMenuItem) {
        model.selectionDetectionEnabled.toggle()
        sender.state = model.selectionDetectionEnabled ? .on : .off
        configureStatusItem()
    }

    @objc private func toggleAutomaticLanguageRouting(_ sender: NSMenuItem) {
        model.automaticLanguageRoutingEnabled.toggle()
        sender.state = model.automaticLanguageRoutingEnabled ? .on : .off
        configureStatusItem()
    }

    @objc private func toggleAutomaticSelectionTranslation(_ sender: NSMenuItem) {
        if model.automaticSelectionTranslationEnabled {
            model.automaticSelectionTranslationEnabled = false
        } else {
            if !model.automaticSelectionTranslationPrivacyAcknowledged {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "开启选中即翻译？"
                alert.informativeText = "选中文字后会立即调用 Apple 设备端语言包，原文不会发送到第三方翻译服务。密码框会被排除；Apple 不支持的语言组合会直接提示失败。"
                alert.addButton(withTitle: "了解并开启")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    sender.state = .off
                    return
                }
                model.acknowledgeAutomaticSelectionTranslationPrivacy()
            }
            model.automaticSelectionTranslationEnabled = true
        }
        sender.state = model.automaticSelectionTranslationEnabled ? .on : .off
        configureStatusItem()
    }

    @objc private func toggleHoverTranslation(_ sender: NSMenuItem) {
        if !model.hoverTranslationEnabled {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "开启鼠标悬停翻译？"
            alert.informativeText = "鼠标稳定停留约 0.65 秒后，只读取指针下方由辅助功能公开的静态文字，并使用 Apple 本地语言包翻译。输入框、密码框、截图和 Canvas 不会被悬停模式读取；移动鼠标即可取消等待。"
            alert.addButton(withTitle: "开启")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                sender.state = .off
                return
            }
        }
        model.hoverTranslationEnabled.toggle()
        sender.state = model.hoverTranslationEnabled ? .on : .off
        configureStatusItem()
    }

    @objc private func toggleClipboardCompatibility(_ sender: NSMenuItem) {
        if model.clipboardCompatibilityEnabled {
            model.clipboardCompatibilityEnabled = false
        } else {
            if !model.clipboardCompatibilityPrivacyAcknowledged {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "开启剪贴板兼容模式？"
                alert.informativeText = "仅在 Accessibility 无法读取或写入时，显式快捷键和 AI 兼容输入功能才会短暂借用系统通用剪贴板。内容可能被剪贴板管理器或 Universal Clipboard 观察到；因此默认关闭。AI 回复翻译无论此开关是否开启，都不会读取、写入或快照剪贴板。"
                alert.addButton(withTitle: "了解风险并开启")
                alert.addButton(withTitle: "保持关闭")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    sender.state = .off
                    return
                }
                model.acknowledgeClipboardCompatibilityPrivacy()
            }
            model.clipboardCompatibilityEnabled = true
        }
        sender.state = model.clipboardCompatibilityEnabled ? .on : .off
        configureStatusItem()
    }

    @objc private func blockFrontmostApplicationForPrivacy(_ sender: NSMenuItem) {
        guard let processIdentifier = (sender.representedObject as? NSNumber)?.int32Value,
              let app = NSRunningApplication(processIdentifier: processIdentifier),
              !model.isHelperApp(app) else {
            return
        }
        _ = model.blockApplicationForPrivacy(app)
        configureStatusItem()
    }

    @objc private func allowFrontmostApplicationForPrivacy(_ sender: NSMenuItem) {
        guard let processIdentifier = (sender.representedObject as? NSNumber)?.int32Value,
              let app = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        _ = model.allowApplicationForPrivacy(app)
        configureStatusItem()
    }

    @objc private func allowBlockedApplicationForPrivacy(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        _ = model.allowApplicationForPrivacy(bundleIdentifier: identifier)
        configureStatusItem()
    }

    @objc private func chooseContentFilterOff() {
        model.contentFilterLevel = .off
        configureStatusItem()
    }

    @objc private func chooseContentFilterBodyFirst() {
        model.contentFilterLevel = .bodyFirst
        configureStatusItem()
    }

    @objc private func chooseContentFilterStrict() {
        model.contentFilterLevel = .strict
        configureStatusItem()
    }

    @objc private func toggleUnifiedBar(_ sender: NSMenuItem) {
        model.unifiedBarEnabled.toggle()
        sender.state = model.unifiedBarEnabled ? .on : .off
        if model.translatorEnabled, model.unifiedBarEnabled {
            model.unifiedBarController.start()
        } else {
            model.unifiedBarController.stop()
            model.clearResponseTranslation()
        }
        configureStatusItem()
    }

    @objc private func toggleResponseTranslation(_ sender: NSMenuItem) {
        if model.responseTranslationEnabled {
            model.responseTranslationEnabled = false
        } else {
            if !model.responseTranslationPrivacyAcknowledged {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "开启自动回复翻译？"
                alert.informativeText = "自动模式只通过辅助功能读取外语回复，不截屏，也不读取或写入剪贴板；翻译只调用 Apple 设备端语言包，原文不会发送到第三方服务。只有你在辅助功能读取失败后再次明确点击“OCR 重试”，才会请求屏幕录制，并仅截取目标 AI 窗口中按布局近似计算的对话区域；它可能包含同列可见历史对话，但不会截取其他 App，截图也不保存。"
                alert.addButton(withTitle: "了解并开启")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    sender.state = .off
                    return
                }
                model.acknowledgeResponseTranslationPrivacy()
            }
            model.responseTranslationEnabled = true
        }
        sender.state = model.responseTranslationEnabled ? .on : .off
        if !model.responseTranslationEnabled {
            model.clearResponseTranslation()
        }
        configureStatusItem()
    }

    @objc private func chooseEnglish() {
        DispatchQueue.main.async { [weak self] in
            self?.model.targetLanguage = .english
            self?.configureStatusItem()
        }
    }

    @objc private func chooseSimplifiedChinese() {
        DispatchQueue.main.async { [weak self] in
            self?.model.targetLanguage = .simplifiedChinese
            self?.configureStatusItem()
        }
    }

    @objc private func chooseJapanese() {
        DispatchQueue.main.async { [weak self] in
            self?.model.targetLanguage = .japanese
            self?.configureStatusItem()
        }
    }

    @objc private func chooseSystemTheme() {
        chooseTheme(.system)
    }

    @objc private func chooseDarkTheme() {
        chooseTheme(.dark)
    }

    @objc private func chooseTokyoBlueTheme() {
        chooseTheme(.tokyoBlue)
    }

    @objc private func requestAccessibilityPermission() {
        _ = AccessibilityPermission.requestIfNeeded(prompt: true)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        _ = AccessibilityPermission.requestIfNeeded(prompt: true)
    }

    @objc private func requestScreenRecordingPermission() {
        if !ScreenRecordingPermission.requestIfNeeded() {
            ScreenRecordingPermission.openSettings()
        }
        configureStatusItem()
    }

    @objc private func openScreenRecordingSettings() {
        ScreenRecordingPermission.openSettings()
    }

    @objc private func restartEdgeBar() {
        model.unifiedBarController.stop()
        if model.translatorEnabled, model.unifiedBarEnabled {
            model.unifiedBarController.start()
            model.revealEdgeBar()
            model.statusMessage = "Edge bar restarted."
        } else {
            model.statusMessage = "Edge bar is disabled."
        }
        configureStatusItem()
    }

    @objc private func refreshStatusMenu() {
        model.statusMessage = "Menu state refreshed."
        configureStatusItem()
    }

    @objc private func copyDebugInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(debugInfoText(), forType: .string)
        model.statusMessage = "Debug info copied."
        configureStatusItem()
    }

    private func configureStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }

        statusItem?.length = NSStatusItem.squareLength
        configureStatusButton()

        statusMenu = makeStatusMenu()
        statusItem?.menu = statusMenu
        statusItem?.button?.target = nil
        statusItem?.button?.action = nil
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu(title: "无感翻译")

        let guideItem = NSMenuItem(
            title: "快速开始与安全自检…",
            action: #selector(showUsageGuide),
            keyEquivalent: ""
        )
        menu.addItem(guideItem)
        menu.addItem(NSMenuItem.separator())

        let enabledItem = NSMenuItem(
            title: model.translatorEnabled ? "跨应用翻译已开启" : "跨应用翻译已暂停",
            action: #selector(toggleTranslatorEnabled(_:)),
            keyEquivalent: ""
        )
        enabledItem.state = model.translatorEnabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(NSMenuItem.separator())

        let translateSelectionItem = NSMenuItem(
            title: "翻译选中文字（⌃⌥T）",
            action: #selector(translateCurrentSelection),
            keyEquivalent: ""
        )
        translateSelectionItem.isEnabled = model.translatorEnabled
        menu.addItem(translateSelectionItem)

        let translateScreenRegionItem = NSMenuItem(
            title: "框选屏幕文字（OCR）…",
            action: #selector(translateScreenRegion),
            keyEquivalent: ""
        )
        translateScreenRegionItem.isEnabled = model.translatorEnabled
        menu.addItem(translateScreenRegionItem)

        let subtitleMenu = NSMenu(title: "视频字幕翻译")
        let toggleSubtitleItem = NSMenuItem(
            title: model.subtitleTranslationActive ? "停止实时字幕" : "框选字幕区域并开始…",
            action: #selector(toggleSubtitleTranslation),
            keyEquivalent: ""
        )
        toggleSubtitleItem.isEnabled = model.translatorEnabled
        subtitleMenu.addItem(toggleSubtitleItem)
        subtitleMenu.addItem(NSMenuItem.separator())

        let bilingualItem = NSMenuItem(title: "双语显示", action: #selector(chooseSubtitleBilingual), keyEquivalent: "")
        bilingualItem.state = model.subtitleDisplayMode == .bilingual ? .on : .off
        subtitleMenu.addItem(bilingualItem)
        let translationOnlyItem = NSMenuItem(title: "仅显示译文", action: #selector(chooseSubtitleTranslationOnly), keyEquivalent: "")
        translationOnlyItem.state = model.subtitleDisplayMode == .translationOnly ? .on : .off
        subtitleMenu.addItem(translationOnlyItem)

        let subtitleStyleMenu = NSMenu(title: "字幕样式")
        let darkSubtitleItem = NSMenuItem(title: "深色", action: #selector(chooseSubtitleDarkStyle), keyEquivalent: "")
        darkSubtitleItem.state = model.subtitleOverlayStyle == .dark ? .on : .off
        subtitleStyleMenu.addItem(darkSubtitleItem)
        let lightSubtitleItem = NSMenuItem(title: "浅色", action: #selector(chooseSubtitleLightStyle), keyEquivalent: "")
        lightSubtitleItem.state = model.subtitleOverlayStyle == .light ? .on : .off
        subtitleStyleMenu.addItem(lightSubtitleItem)
        let contrastSubtitleItem = NSMenuItem(title: "高对比", action: #selector(chooseSubtitleHighContrastStyle), keyEquivalent: "")
        contrastSubtitleItem.state = model.subtitleOverlayStyle == .highContrast ? .on : .off
        subtitleStyleMenu.addItem(contrastSubtitleItem)
        let subtitleStyleItem = NSMenuItem(title: "样式: \(model.subtitleOverlayStyle.displayName)", action: nil, keyEquivalent: "")
        subtitleStyleItem.submenu = subtitleStyleMenu
        subtitleMenu.addItem(subtitleStyleItem)

        let subtitleFontMenu = NSMenu(title: "字号")
        let smallFontItem = NSMenuItem(title: "小", action: #selector(chooseSubtitleSmallFont), keyEquivalent: "")
        smallFontItem.state = model.subtitleFontSize == 18 ? .on : .off
        subtitleFontMenu.addItem(smallFontItem)
        let mediumFontItem = NSMenuItem(title: "中", action: #selector(chooseSubtitleMediumFont), keyEquivalent: "")
        mediumFontItem.state = model.subtitleFontSize == 22 ? .on : .off
        subtitleFontMenu.addItem(mediumFontItem)
        let largeFontItem = NSMenuItem(title: "大", action: #selector(chooseSubtitleLargeFont), keyEquivalent: "")
        largeFontItem.state = model.subtitleFontSize == 28 ? .on : .off
        subtitleFontMenu.addItem(largeFontItem)
        let subtitleFontItem = NSMenuItem(title: "字号: \(Int(model.subtitleFontSize))", action: nil, keyEquivalent: "")
        subtitleFontItem.submenu = subtitleFontMenu
        subtitleMenu.addItem(subtitleFontItem)

        let subtitleItem = NSMenuItem(title: "视频字幕翻译", action: nil, keyEquivalent: "")
        subtitleItem.submenu = subtitleMenu
        menu.addItem(subtitleItem)

        let selectionDetectionItem = NSMenuItem(
            title: "选中后显示翻译按钮",
            action: #selector(toggleSelectionDetection(_:)),
            keyEquivalent: ""
        )
        selectionDetectionItem.state = model.selectionDetectionEnabled ? .on : .off
        selectionDetectionItem.isEnabled = model.translatorEnabled
        menu.addItem(selectionDetectionItem)

        let automaticSelectionItem = NSMenuItem(
            title: "选中即自动翻译（仅本地）",
            action: #selector(toggleAutomaticSelectionTranslation(_:)),
            keyEquivalent: ""
        )
        automaticSelectionItem.state = model.automaticSelectionTranslationEnabled ? .on : .off
        automaticSelectionItem.isEnabled = model.translatorEnabled && model.selectionDetectionEnabled
        menu.addItem(automaticSelectionItem)

        let hoverTranslationItem = NSMenuItem(
            title: "鼠标悬停翻译（仅静态文字）",
            action: #selector(toggleHoverTranslation(_:)),
            keyEquivalent: ""
        )
        hoverTranslationItem.state = model.hoverTranslationEnabled ? .on : .off
        hoverTranslationItem.isEnabled = model.translatorEnabled
        menu.addItem(hoverTranslationItem)

        let selectionDisplayMenu = NSMenu(title: "选区浮层显示")
        let selectionBilingualItem = NSMenuItem(
            title: "原文 + 译文",
            action: #selector(chooseSelectionBilingual),
            keyEquivalent: ""
        )
        selectionBilingualItem.state = model.selectionDisplayMode == .bilingual ? .on : .off
        selectionDisplayMenu.addItem(selectionBilingualItem)
        let selectionTranslationOnlyItem = NSMenuItem(
            title: "仅显示译文",
            action: #selector(chooseSelectionTranslationOnly),
            keyEquivalent: ""
        )
        selectionTranslationOnlyItem.state = model.selectionDisplayMode == .translationOnly ? .on : .off
        selectionDisplayMenu.addItem(selectionTranslationOnlyItem)
        let selectionDisplayItem = NSMenuItem(
            title: "选区浮层: \(model.selectionDisplayMode == .bilingual ? "双语" : "仅译文")",
            action: nil,
            keyEquivalent: ""
        )
        selectionDisplayItem.submenu = selectionDisplayMenu
        menu.addItem(selectionDisplayItem)

        let automaticLanguageItem = NSMenuItem(
            title: "自动识别语言（中文→英文，其他→中文）",
            action: #selector(toggleAutomaticLanguageRouting(_:)),
            keyEquivalent: ""
        )
        automaticLanguageItem.state = model.automaticLanguageRoutingEnabled ? .on : .off
        automaticLanguageItem.isEnabled = model.translatorEnabled
        menu.addItem(automaticLanguageItem)

        let contentFilterMenu = NSMenu(title: "内容筛选")
        for (title, level, action) in [
            ("关闭", ContentFilterLevel.off, #selector(chooseContentFilterOff)),
            ("正文优先（推荐）", ContentFilterLevel.bodyFirst, #selector(chooseContentFilterBodyFirst)),
            ("严格", ContentFilterLevel.strict, #selector(chooseContentFilterStrict))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.state = model.contentFilterLevel == level ? .on : .off
            contentFilterMenu.addItem(item)
        }
        let contentFilterItem = NSMenuItem(
            title: "内容筛选: \(model.contentFilterLevel.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        contentFilterItem.submenu = contentFilterMenu
        menu.addItem(contentFilterItem)

        let clipboardCompatibilityItem = NSMenuItem(
            title: "允许剪贴板兼容模式（默认关闭）",
            action: #selector(toggleClipboardCompatibility(_:)),
            keyEquivalent: ""
        )
        clipboardCompatibilityItem.state = model.clipboardCompatibilityEnabled ? .on : .off
        clipboardCompatibilityItem.isEnabled = model.translatorEnabled
        menu.addItem(clipboardCompatibilityItem)

        let privacyMenu = NSMenu(title: "App 隐私名单")
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !model.isHelperApp(frontmost) {
            let identifier = frontmost.bundleIdentifier ?? "无 Bundle ID"
            if AppPrivacyPolicy.isBuiltInProtected(frontmost.bundleIdentifier) {
                privacyMenu.addItem(disabledMenuItem("\(frontmost.localizedName ?? identifier)：内置保护"))
            } else if model.isCaptureAllowed(in: frontmost) {
                let item = NSMenuItem(
                    title: "禁止读取当前 App：\(frontmost.localizedName ?? identifier)",
                    action: #selector(blockFrontmostApplicationForPrivacy(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = NSNumber(value: frontmost.processIdentifier)
                privacyMenu.addItem(item)
            } else {
                let item = NSMenuItem(
                    title: "允许读取当前 App：\(frontmost.localizedName ?? identifier)",
                    action: #selector(allowFrontmostApplicationForPrivacy(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = NSNumber(value: frontmost.processIdentifier)
                privacyMenu.addItem(item)
            }
        } else {
            privacyMenu.addItem(disabledMenuItem("请先切换到要管理的 App"))
        }
        if !model.userBlockedApplicationIdentifiers.isEmpty {
            privacyMenu.addItem(.separator())
            privacyMenu.addItem(disabledMenuItem("自定义禁止名单"))
            for identifier in model.userBlockedApplicationIdentifiers {
                let item = NSMenuItem(
                    title: "移除：\(identifier)",
                    action: #selector(allowBlockedApplicationForPrivacy(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = identifier
                privacyMenu.addItem(item)
            }
        }
        let privacyItem = NSMenuItem(title: "App 隐私名单", action: nil, keyEquivalent: "")
        privacyItem.submenu = privacyMenu
        menu.addItem(privacyItem)
        menu.addItem(NSMenuItem.separator())

        let targetMenu = NSMenu()
        let chineseItem = NSMenuItem(title: "简体中文", action: #selector(chooseSimplifiedChinese), keyEquivalent: "")
        chineseItem.state = model.targetLanguage == .simplifiedChinese ? .on : .off
        targetMenu.addItem(chineseItem)

        let englishItem = NSMenuItem(title: "English", action: #selector(chooseEnglish), keyEquivalent: "")
        englishItem.state = model.targetLanguage == .english ? .on : .off
        targetMenu.addItem(englishItem)

        let japaneseItem = NSMenuItem(title: "Japanese", action: #selector(chooseJapanese), keyEquivalent: "")
        japaneseItem.state = model.targetLanguage == .japanese ? .on : .off
        targetMenu.addItem(japaneseItem)
        let targetTitle = model.automaticLanguageRoutingEnabled
            ? "语言路由: 自动"
            : "固定目标: \(model.targetLanguage.displayName)"
        let targetItem = NSMenuItem(title: targetTitle, action: nil, keyEquivalent: "")
        targetItem.submenu = targetMenu
        menu.addItem(targetItem)

        let themeMenu = NSMenu()
        let systemThemeItem = NSMenuItem(title: AppTheme.system.menuTitle, action: #selector(chooseSystemTheme), keyEquivalent: "")
        systemThemeItem.state = model.appTheme == .system ? .on : .off
        themeMenu.addItem(systemThemeItem)

        let darkThemeItem = NSMenuItem(title: AppTheme.dark.menuTitle, action: #selector(chooseDarkTheme), keyEquivalent: "")
        darkThemeItem.state = model.appTheme == .dark ? .on : .off
        themeMenu.addItem(darkThemeItem)

        let tokyoBlueThemeItem = NSMenuItem(title: AppTheme.tokyoBlue.menuTitle, action: #selector(chooseTokyoBlueTheme), keyEquivalent: "")
        tokyoBlueThemeItem.state = model.appTheme == .tokyoBlue ? .on : .off
        themeMenu.addItem(tokyoBlueThemeItem)
        let themeItem = NSMenuItem(title: "外观: \(model.appTheme.displayName)", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        menu.addItem(NSMenuItem.separator())

        let aiCompatibilityMenu = NSMenu(title: "AI 兼容模式")

        let revealItem = NSMenuItem(title: "显示边缘栏", action: #selector(revealEdgeBar), keyEquivalent: "")
        revealItem.isEnabled = model.translatorEnabled
        aiCompatibilityMenu.addItem(revealItem)

        let translateItem = NSMenuItem(title: "翻译输入草稿（不会发送）", action: #selector(translateCurrentInput), keyEquivalent: "")
        translateItem.isEnabled = model.translatorEnabled
        aiCompatibilityMenu.addItem(translateItem)

        let translateResponseItem = NSMenuItem(
            title: "翻译已选或最新回复",
            action: #selector(translateLatestResponse),
            keyEquivalent: ""
        )
        translateResponseItem.isEnabled = model.translatorEnabled
        aiCompatibilityMenu.addItem(translateResponseItem)

        let copyResponseItem = NSMenuItem(
            title: "复制回复译文",
            action: #selector(copyLatestResponse),
            keyEquivalent: ""
        )
        copyResponseItem.isEnabled = model.translatorEnabled && !model.responseTranslationText.isEmpty
        aiCompatibilityMenu.addItem(copyResponseItem)
        aiCompatibilityMenu.addItem(NSMenuItem.separator())

        let unifiedBarItem = NSMenuItem(title: "启用 AI 兼容边缘栏", action: #selector(toggleUnifiedBar(_:)), keyEquivalent: "")
        unifiedBarItem.state = model.unifiedBarEnabled ? .on : .off
        unifiedBarItem.isEnabled = model.translatorEnabled
        aiCompatibilityMenu.addItem(unifiedBarItem)

        let autoShowItem = NSMenuItem(title: "AI 窗口自动显示边缘栏", action: #selector(toggleAutoShow(_:)), keyEquivalent: "")
        autoShowItem.state = model.autoShowWhenClaudeIsActive ? .on : .off
        autoShowItem.isEnabled = model.translatorEnabled
        aiCompatibilityMenu.addItem(autoShowItem)

        let responseItem = NSMenuItem(title: "自动翻译 AI 回复（仅本地）", action: #selector(toggleResponseTranslation(_:)), keyEquivalent: "")
        responseItem.state = model.responseTranslationEnabled ? .on : .off
        responseItem.isEnabled = model.translatorEnabled
        aiCompatibilityMenu.addItem(responseItem)

        let aiCompatibilityItem = NSMenuItem(title: "AI 兼容模式", action: nil, keyEquivalent: "")
        aiCompatibilityItem.submenu = aiCompatibilityMenu
        menu.addItem(aiCompatibilityItem)

        menu.addItem(NSMenuItem.separator())
        let diagnosticsMenu = NSMenu(title: "状态与故障诊断")
        diagnosticsMenu.addItem(disabledMenuItem("辅助功能权限: \(AccessibilityPermission.isTrusted ? "已授权" : "未授权")"))
        diagnosticsMenu.addItem(disabledMenuItem("屏幕录制权限: \(ScreenRecordingPermission.isGranted ? "已授权" : "未授权（仅影响 OCR）")"))
        diagnosticsMenu.addItem(disabledMenuItem("边缘栏运行: \(model.unifiedBarController.isRunning ? "运行中" : "未运行")"))
        diagnosticsMenu.addItem(disabledMenuItem("选区被动识别: \(model.selectionDetectionEnabled ? "已开启" : "已关闭")"))
        diagnosticsMenu.addItem(disabledMenuItem("选中即翻译: \(model.automaticSelectionTranslationEnabled ? "已开启" : "已关闭")"))
        diagnosticsMenu.addItem(disabledMenuItem("鼠标悬停翻译: \(model.hoverTranslationEnabled ? "已开启" : "已关闭")"))
        diagnosticsMenu.addItem(disabledMenuItem("实时字幕: \(model.subtitleTranslationActive ? "运行中" : "未运行")"))
        diagnosticsMenu.addItem(disabledMenuItem("剪贴板兼容: \(model.clipboardCompatibilityEnabled ? "已开启（有本地暴露风险）" : "已关闭")"))
        diagnosticsMenu.addItem(disabledMenuItem("当前目标: \(model.targetAppName.isEmpty ? "未检测" : model.targetAppName)"))
        diagnosticsMenu.addItem(disabledMenuItem("前台应用: \(frontmostAppDescription())"))
        diagnosticsMenu.addItem(disabledMenuItem("目标语言: \(model.targetLanguage.displayName)"))
        diagnosticsMenu.addItem(disabledMenuItem("状态: \(model.statusMessage.isEmpty ? "无" : model.statusMessage)"))
        diagnosticsMenu.addItem(NSMenuItem.separator())

        let restartBarItem = NSMenuItem(title: "重启边缘栏", action: #selector(restartEdgeBar), keyEquivalent: "")
        restartBarItem.isEnabled = model.translatorEnabled
        diagnosticsMenu.addItem(restartBarItem)

        diagnosticsMenu.addItem(NSMenuItem(title: "刷新菜单状态", action: #selector(refreshStatusMenu), keyEquivalent: ""))
        diagnosticsMenu.addItem(NSMenuItem(title: "复制脱敏诊断", action: #selector(copyDebugInfo), keyEquivalent: ""))
        diagnosticsMenu.addItem(NSMenuItem(title: "打开辅助功能设置", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        diagnosticsMenu.addItem(NSMenuItem(title: "打开屏幕录制设置", action: #selector(openScreenRecordingSettings), keyEquivalent: ""))

        let diagnosticsItem = NSMenuItem(title: "状态与故障诊断", action: nil, keyEquivalent: "")
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)

        let moreMenu = NSMenu()
        moreMenu.addItem(NSMenuItem(title: "打开备用草稿窗（高级）", action: #selector(showInputPanel), keyEquivalent: ""))
        let copyLastItem = NSMenuItem(title: "复制上次译文", action: #selector(copyLastTranslation), keyEquivalent: "")
        copyLastItem.isEnabled = model.translatorEnabled && !model.lastTranslation.isEmpty
        moreMenu.addItem(copyLastItem)

        let clearReplyItem = NSMenuItem(title: "清除回复译文", action: #selector(clearResponseTranslation), keyEquivalent: "")
        clearReplyItem.isEnabled = model.translatorEnabled && model.hasResponseTranslationActivity
        moreMenu.addItem(clearReplyItem)
        moreMenu.addItem(NSMenuItem.separator())
        moreMenu.addItem(NSMenuItem(title: "请求辅助功能权限", action: #selector(requestAccessibilityPermission), keyEquivalent: ""))
        moreMenu.addItem(NSMenuItem(title: "打开辅助功能设置", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        moreMenu.addItem(NSMenuItem(title: "请求屏幕录制权限（OCR）", action: #selector(requestScreenRecordingPermission), keyEquivalent: ""))
        let moreItem = NSMenuItem(title: "高级与权限", action: nil, keyEquivalent: "")
        moreItem.submenu = moreMenu
        menu.addItem(moreItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出无感翻译", action: #selector(quit), keyEquivalent: "q"))

        prepareStatusMenu(menu)
        return menu
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func prepareStatusMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        for item in menu.items {
            if item.action != nil {
                item.target = self
            }
            if let submenu = item.submenu {
                prepareStatusMenu(submenu)
            }
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem?.button else {
            return
        }

        let image = NSImage(
            systemSymbolName: "translate",
            accessibilityDescription: "无感翻译"
        ) ?? NSImage(
            systemSymbolName: "character.book.closed",
            accessibilityDescription: "无感翻译"
        )

        if let image {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = "译"
        }

        button.alphaValue = model.translatorEnabled ? 1.0 : 0.45
        button.toolTip = model.translatorEnabled
            ? "无感翻译：选中文字后点击“翻译”，或按 ⌃⌥T。"
            : "无感翻译已暂停：点击打开控制菜单。"
    }

    private func popStatusMenu(from sender: NSStatusBarButton) {
        statusMenu = makeStatusMenu()
        statusItem?.menu = statusMenu
        sender.performClick(nil)
    }

    private func frontmostAppDescription() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "未知"
        }
        let name = app.localizedName ?? "未知应用"
        let bundleIdentifier = app.bundleIdentifier ?? "无 bundle id"
        return "\(name) (\(bundleIdentifier))"
    }

    private func debugInfoText() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return """
        无感翻译脱敏诊断
        Version: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Apple local translation: available
        Translator enabled: \(model.translatorEnabled)
        Unified edge bar enabled: \(model.unifiedBarEnabled)
        Unified edge bar running: \(model.unifiedBarController.isRunning)
        Selection detection enabled: \(model.selectionDetectionEnabled)
        Automatic selection translation enabled: \(model.automaticSelectionTranslationEnabled)
        Hover translation enabled: \(model.hoverTranslationEnabled)
        Live subtitle translation active: \(model.subtitleTranslationActive)
        Subtitle display mode: \(model.subtitleDisplayMode.displayName)
        Automatic language routing enabled: \(model.automaticLanguageRoutingEnabled)
        Clipboard compatibility enabled: \(model.clipboardCompatibilityEnabled)
        Auto AI detection enabled: \(model.autoShowWhenClaudeIsActive)
        Response translation enabled: \(model.responseTranslationEnabled)
        Target language: \(model.targetLanguage.displayName)
        Theme: \(model.appTheme.displayName)
        Accessibility trusted: \(AccessibilityPermission.isTrusted)
        Screen recording trusted (explicit region OCR/subtitles/reply OCR retry only): \(ScreenRecordingPermission.isGranted)
        Response translation active: \(model.hasResponseTranslationActivity)
        Contains source text, translations, app names, window titles, or clipboard data: false
        """
    }

    private func findExistingInstance() -> NSRunningApplication? {
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.processIdentifier != currentProcessIdentifier else {
                return false
            }
            return app.bundleIdentifier == bundleIdentifier
        }
    }

    private func exitDuplicateIfNoURLWasHandled() {
        guard !handledIncomingURL, let existingInstance = existingInstanceAtLaunch else {
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            showExistingInstanceNotification,
            object: nil,
            userInfo: ["action": "activate"],
            deliverImmediately: true
        )
        existingInstance.activate()
        NSApp.terminate(nil)
    }

    private func configureSingleInstanceObserver() {
        showExistingInstanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: showExistingInstanceNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let action = notification.userInfo?["action"] as? String
            let languageValue = notification.userInfo?["language"] as? String
            Task { @MainActor in
                self?.handleExistingInstanceNotification(action: action, languageValue: languageValue)
            }
        }
    }

    private func configureHotkeys() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return noErr
            }

            var hotKeyID = EventHotKeyID()
            let error = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard error == noErr else {
                return error
            }

            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            guard hotKeyID.signature == appDelegate.hotKeySignature, hotKeyID.id == appDelegate.hotKeyID else {
                return noErr
            }

            Task { @MainActor in
                appDelegate.model.translateCurrentSelection()
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyEventHandler
        )
        guard installStatus == noErr else {
            NSLog("ClaudePromptTranslator: failed to install hotkey event handler: \(installStatus)")
            return
        }

        let carbonHotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(controlKey | optionKey),
            carbonHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            NSLog("ClaudePromptTranslator: failed to register universal selection hotkey: \(registerStatus)")
        }
    }

    private func configureClaudeDetection() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let processIdentifier = app.processIdentifier
            Task { @MainActor in
                self?.handleActivatedApplication(processIdentifier: processIdentifier)
            }
        }

        contextTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.showEdgeBarIfAIIsActive(forceReveal: false)
            }
        }
    }

    private func scheduleInitialAIRevealChecks() {
        for delay in [0.4, 1.2, 2.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.showEdgeBarIfAIIsActive(forceReveal: true)
            }
        }
    }

    private func handleActivatedApplication(processIdentifier: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return
        }
        if !model.isHelperApp(app) {
            model.rememberTarget(app)
        }
        showEdgeBarIfAIIsActive(appOverride: app, forceReveal: true)
    }

    private func showEdgeBarIfAIIsActive(
        appOverride: NSRunningApplication? = nil,
        forceReveal: Bool
    ) {
        guard model.translatorEnabled,
              model.unifiedBarEnabled,
              model.autoShowWhenClaudeIsActive else {
            return
        }
        guard let app = appOverride ?? NSWorkspace.shared.frontmostApplication else {
            return
        }
        if model.isHelperApp(app) {
            return
        }
        guard model.isCaptureAllowed(in: app), model.detector.isAIContext(app) else {
            lastAutoRevealedProcessIdentifier = nil
            lastAutoRevealAt = nil
            return
        }
        model.rememberTarget(app)
        model.statusMessage = "AI chat detected. Move near the window edge for translation controls."
        let revealIsStale = lastAutoRevealAt.map { Date().timeIntervalSince($0) > 12 } ?? true
        if forceReveal || lastAutoRevealedProcessIdentifier != app.processIdentifier || revealIsStale {
            lastAutoRevealedProcessIdentifier = app.processIdentifier
            lastAutoRevealAt = Date()
            model.revealEdgeBar()
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "claude-prompt-translator" else {
            return
        }

        switch url.host {
        case "translate":
            model.statusMessage = "For safety, URL links can only show the edge bar. Use the button or hotkey to translate."
            model.revealEdgeBar()
        case "show", "input":
            model.revealEdgeBar()
        case "english":
            model.targetLanguage = .english
            model.revealEdgeBar()
            configureStatusItem()
        case "japanese":
            model.targetLanguage = .japanese
            model.revealEdgeBar()
            configureStatusItem()
        default:
            if url.path == "/show" || url.path == "/input" {
                model.revealEdgeBar()
            } else if url.path == "/translate" {
                model.statusMessage = "For safety, URL links can only show the edge bar. Use the button or hotkey to translate."
                model.revealEdgeBar()
            }
        }
    }

    private func forwardURLToExistingInstance(_ url: URL) {
        guard url.scheme == "claude-prompt-translator" else {
            return
        }

        var userInfo: [String: String] = [:]
        switch url.host {
        case "translate":
            userInfo["action"] = "show"
        case "english":
            userInfo["action"] = "show"
            userInfo["language"] = TargetLanguage.english.rawValue
        case "japanese":
            userInfo["action"] = "show"
            userInfo["language"] = TargetLanguage.japanese.rawValue
        case "show", "input":
            userInfo["action"] = "show"
        default:
            if url.path == "/translate" {
                userInfo["action"] = "show"
            } else if url.path == "/show" || url.path == "/input" {
                userInfo["action"] = "show"
            }
        }

        guard !userInfo.isEmpty else {
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            showExistingInstanceNotification,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    private func handleExistingInstanceNotification(action: String? = nil, languageValue: String? = nil) {
        if let languageValue,
           let language = TargetLanguage(rawValue: languageValue) {
            model.targetLanguage = language
            configureStatusItem()
        }

        switch action {
        case "translate":
            model.statusMessage = "External requests can only show the edge bar. Use the button or hotkey to translate."
            model.revealEdgeBar()
        case "show":
            model.revealEdgeBar()
        default:
            model.statusMessage = "Prompt Translator is already running in the menu bar."
        }
    }

    private func chooseTheme(_ theme: AppTheme) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.model.appTheme = theme
            self.configureStatusItem()
        }
    }
}
