import AppKit
import Combine
import SwiftUI

struct AppHealthSnapshot: Equatable {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let translatorEnabled: Bool
    let selectionDetectionEnabled: Bool
    let automaticLanguageRoutingEnabled: Bool
    let translationPreferenceLearningEnabled: Bool
    let translationPreferenceLearningSummary: String
    let translationPreferenceObservationCount: Int
    let aiInputTargetLanguageName: String
    let clipboardCompatibilityEnabled: Bool
    let unifiedBarEnabled: Bool
    let responseTranslationEnabled: Bool
    let appVersion: String
    let macOSVersion: String

    var selectionReady: Bool {
        accessibilityGranted && translatorEnabled && selectionDetectionEnabled
    }

    var readinessTitle: String {
        if !translatorEnabled {
            return "翻译器已暂停"
        }
        if !accessibilityGranted {
            return "还需授予辅助功能权限"
        }
        if !selectionDetectionEnabled {
            return "请开启选区识别"
        }
        return "已可开始安全翻译"
    }

    @MainActor
    static func capture(from model: AppModel) -> AppHealthSnapshot {
        AppHealthSnapshot(
            accessibilityGranted: AccessibilityPermission.isTrusted,
            screenRecordingGranted: ScreenRecordingPermission.isGranted,
            translatorEnabled: model.translatorEnabled,
            selectionDetectionEnabled: model.selectionDetectionEnabled,
            automaticLanguageRoutingEnabled: model.automaticLanguageRoutingEnabled,
            translationPreferenceLearningEnabled: model.translationPreferenceLearningEnabled,
            translationPreferenceLearningSummary: model.translationPreferenceLearningSummary,
            translationPreferenceObservationCount: model.translationPreferenceObservationCount,
            aiInputTargetLanguageName: model.targetLanguage.shortChineseName,
            clipboardCompatibilityEnabled: model.clipboardCompatibilityEnabled,
            unifiedBarEnabled: model.unifiedBarEnabled,
            responseTranslationEnabled: model.responseTranslationEnabled,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

private struct RunningAIApplication: Identifiable, Equatable {
    let processIdentifier: pid_t
    let name: String

    var id: pid_t { processIdentifier }
}

@MainActor
private final class UsageGuideState: ObservableObject {
    @Published private(set) var snapshot: AppHealthSnapshot
    @Published private(set) var runningAIApplications: [RunningAIApplication] = []
    @Published var actionMessage = "自检只读取权限和功能开关，不读取原文、译文、剪贴板或聊天记录。"

    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        self.snapshot = AppHealthSnapshot.capture(from: model)
    }

    func refresh(message: String? = nil) {
        snapshot = AppHealthSnapshot.capture(from: model)
        runningAIApplications = NSWorkspace.shared.runningApplications
            .filter { app in
                !app.isTerminated
                    && app.activationPolicy == .regular
                    && !model.isHelperApp(app)
                    && model.detector.isAIContext(app)
            }
            .compactMap { app in
                guard let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    return nil
                }
                return RunningAIApplication(
                    processIdentifier: app.processIdentifier,
                    name: name
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        if let message {
            actionMessage = message
        }
    }

    func enableTranslator() {
        model.setTranslatorEnabled(true)
        if !model.selectionDetectionEnabled {
            model.selectionDetectionEnabled = true
        }
        refresh(message: "跨应用翻译和选区识别已开启。")
    }

    func requestAccessibility() {
        _ = AccessibilityPermission.requestIfNeeded(prompt: true)
        refresh(message: AccessibilityPermission.isTrusted
            ? "辅助功能权限已就绪。"
            : "已发起权限请求；允许后返回此窗口并点击“刷新自检”。")
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
        actionMessage = "请在“辅助功能”中允许“无感翻译”，然后返回刷新。"
    }

    func openScreenRecordingSettings() {
        ScreenRecordingPermission.openSettings()
        actionMessage = "屏幕录制只用于你主动框选的 OCR/字幕区域，或二次确认的 AI 回复 OCR；回复 OCR 只截取目标窗口内近似计算的对话区域，可能包含同列可见历史对话，但不会后台全屏扫描。"
    }

    func copySanitizedDiagnostics() {
        let report = """
        无感翻译脱敏诊断
        Version: \(snapshot.appVersion)
        macOS: \(snapshot.macOSVersion)
        Apple local translation: available
        Accessibility: \(snapshot.accessibilityGranted ? "granted" : "missing")
        Screen recording (explicit region OCR/subtitles only): \(snapshot.screenRecordingGranted ? "granted" : "missing")
        Translator enabled: \(snapshot.translatorEnabled)
        Selection detection enabled: \(snapshot.selectionDetectionEnabled)
        Automatic language routing: \(snapshot.automaticLanguageRoutingEnabled)
        Translation preference learning: \(snapshot.translationPreferenceLearningEnabled)
        Translation preference aggregate event count: \(snapshot.translationPreferenceObservationCount)
        AI input target language: \(snapshot.aiInputTargetLanguageName)
        Clipboard compatibility: \(snapshot.clipboardCompatibilityEnabled)
        AI edge bar: \(snapshot.unifiedBarEnabled)
        Automatic reply translation: \(snapshot.responseTranslationEnabled)
        Contains source text, translations, app names, window titles, or clipboard data: false
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        actionMessage = "脱敏诊断已复制；其中不含原文、译文、应用名或窗口标题。"
    }

    func confirmAndResetTranslationPreferenceLearning() {
        let alert = NSAlert()
        alert.messageText = "重置本机语言偏好统计？"
        alert.informativeText = "这会删除已累计的评估时间、语言代码、方向和聚合次数，并从下一次成功的主动翻译重新开始 14 天评估。此操作不会删除其他设置。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置统计")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        model.resetTranslationPreferenceLearning()
        refresh(message: "本机语言偏好统计已重置。")
    }
}

@MainActor
final class UsageGuideController: NSObject, NSWindowDelegate {
    static let presentationDefaultsKey = "usageGuidePresented.2026-08"

    private unowned let model: AppModel
    private let state: UsageGuideState
    private var activationObserver: NSObjectProtocol?
    private lazy var window: NSWindow = makeWindow()

    init(model: AppModel) {
        self.model = model
        self.state = UsageGuideState(model: model)
        super.init()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window.isVisible else { return }
                self.state.refresh()
            }
        }
    }

    var shouldPresentAutomatically: Bool {
        !UserDefaults.standard.bool(forKey: Self.presentationDefaultsKey)
    }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.presentationDefaultsKey)
        state.refresh()
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func openSyntheticSelectionTest() {
        let sample = """
        无感翻译 · 合成文本测试（不含任何个人信息）

        1. 选中下面的英文句子，点击浮动“翻译”，或按 Control + Option + T。
        This synthetic sentence verifies local English-to-Chinese selection translation without sending any message.

        2. 选中下面的中文句子，确认自动路由为英文。
        这是一段只用于本机回归测试的合成中文，不包含真实聊天或文件内容。

        3. 译文出现后可测试“复制译文”；TextEdit 中可写且选区未变化时，可测试“替换选区”，随后按 Command + Z 撤销。
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("无感翻译-合成选区测试.txt")
        do {
            try sample.write(to: url, atomically: true, encoding: .utf8)
            state.actionMessage = "已打开只含合成文字的测试文档；不会自动发送或读取其他内容。"
            window.orderOut(nil)
            NSWorkspace.shared.open(url)
        } catch {
            state.actionMessage = "无法创建合成测试文档：\(error.localizedDescription)"
        }
    }

    func showAICompatibilityBar(processIdentifier: pid_t?) {
        let targetApplication = processIdentifier.flatMap(NSRunningApplication.init(processIdentifier:))
        state.actionMessage = targetApplication.map { "正在返回 \($0.localizedName ?? "所选 AI App")；不会移动鼠标或发送消息。" }
            ?? "请先点进 ChatGPT、Claude 或其他 AI 的消息输入框，再使用边缘栏。"
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if let targetApplication, !targetApplication.isTerminated {
                targetApplication.activate()
                model.rememberTarget(targetApplication)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.model.revealEdgeBar()
            }
        }
    }

    func translateAIResponseFromGuide() {
        SelectionDiagnostics.record("guide response translation requested")
        state.actionMessage = model.unifiedBarController.isManualResponseOCRRetryAvailable
            ? "你已明确选择 OCR 重试；只会截取当前 AI 窗口中近似计算的对话区域，可能包含同列可见历史对话。"
            : "正在优先读取同一 AI App 的选区；没有选区时才读取最新回复，本次不会使用 OCR。"
        guard let targetApplication = model.unifiedBarController.responseTargetApplication else {
            state.actionMessage = "请先在上一步选择并显示 ChatGPT、Claude 或其他 AI 窗口。"
            return
        }
        window.orderOut(nil)
        targetApplication.activate()
        model.rememberTarget(targetApplication)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  !targetApplication.isTerminated,
                  targetApplication.isActive else {
                self?.state.actionMessage = "AI 窗口未能重新激活，请再试一次。"
                self?.show()
                return
            }
            self.model.revealEdgeBar()
            SelectionDiagnostics.record("guide response translation dispatched")
            self.model.unifiedBarController.translateLatestResponse()
        }
    }

    func openSyntheticOCRTest(startSubtitle: Bool) {
        let title = startSubtitle
            ? "Synthetic video subtitle for local bilingual translation"
            : "Synthetic image text for private on-device OCR translation"
        let subtitle = startSubtitle
            ? "Keep this caption inside the selected region."
            : "Only the rectangle you drag will be captured."
        let image = NSImage(size: NSSize(width: 1_200, height: 520))
        image.lockFocus()
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1_200, height: 520).fill()
        title.draw(
            at: NSPoint(x: 70, y: 250),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 38, weight: .bold),
                .foregroundColor: NSColor.white
            ]
        )
        subtitle.draw(
            at: NSPoint(x: 70, y: 190),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .medium),
                .foregroundColor: NSColor.systemYellow
            ]
        )
        image.unlockFocus()

        let filename = startSubtitle ? "无感翻译-合成字幕测试.png" : "无感翻译-合成OCR测试.png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            state.actionMessage = "无法生成合成 OCR 测试图片。"
            return
        }
        do {
            try png.write(to: url, options: .atomic)
            state.actionMessage = "已打开仅含合成文字的图片；请按提示框选黄色/白色字幕区域。"
            window.orderOut(nil)
            NSWorkspace.shared.open(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                if startSubtitle {
                    self?.model.startSubtitleTranslation()
                } else {
                    self?.model.translateScreenRegion()
                }
            }
        } catch {
            state.actionMessage = "无法写入合成 OCR 测试图片：\(error.localizedDescription)"
        }
    }

    private func makeWindow() -> NSWindow {
        let rootView = UsageGuideView(
            model: model,
            state: state,
            onOpenSyntheticTest: { [weak self] in self?.openSyntheticSelectionTest() },
            onShowAIBar: { [weak self] processIdentifier in
                self?.showAICompatibilityBar(processIdentifier: processIdentifier)
            },
            onTranslateAIResponse: { [weak self] in self?.translateAIResponseFromGuide() },
            onOpenSyntheticOCRTest: { [weak self] in self?.openSyntheticOCRTest(startSubtitle: false) },
            onOpenSyntheticSubtitleTest: { [weak self] in self?.openSyntheticOCRTest(startSubtitle: true) }
        )
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "无感翻译 · 快速开始与安全自检"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 540)
        window.delegate = self
        window.setAccessibilityIdentifier("cpt.setup.window")
        return window
    }
}

private struct UsageGuideView: View {
    @ObservedObject var model: AppModel
    @ObservedObject fileprivate var state: UsageGuideState
    let onOpenSyntheticTest: () -> Void
    let onShowAIBar: (pid_t?) -> Void
    let onTranslateAIResponse: () -> Void
    let onOpenSyntheticOCRTest: () -> Void
    let onOpenSyntheticSubtitleTest: () -> Void

    private var snapshot: AppHealthSnapshot { state.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                readinessBanner
                principlesSection
                preferenceLearningSection
                permissionCards
                workflowSection
                privacySection
                footer
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, idealWidth: 780, minHeight: 540, idealHeight: 680)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("无感翻译")
                    .font(.system(size: 24, weight: .bold))
                Text("先确认目标，再翻译；结果可见、写入可控、发送始终由你决定。")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("v\(snapshot.appVersion)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var readinessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: snapshot.selectionReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(snapshot.selectionReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.readinessTitle)
                    .font(.headline)
                Text(state.actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cpt.setup.status")
            }
            Spacer()
            Button("刷新自检") {
                state.refresh(message: "状态已刷新；自检没有读取任何用户文本。")
            }
            .accessibilityIdentifier("cpt.setup.refresh")
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((snapshot.selectionReady ? Color.green : Color.orange).opacity(0.10))
        )
    }

    private var principlesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("三条默认原则")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 10) {
                principleCard(
                    systemImage: "scope",
                    title: "只处理明确目标",
                    detail: "先确认选区或消息输入框，再读取文字。"
                )
                principleCard(
                    systemImage: "eye",
                    title: "结果先展示",
                    detail: "译文先在浮层中可见，替换和复制都由你点击。"
                )
                principleCard(
                    systemImage: "lock.shield",
                    title: "默认不外发",
                    detail: "Apple 本机翻译；剪贴板与 OCR 都需要明确开启。"
                )
            }
        }
    }

    private var permissionCards: some View {
        HStack(alignment: .top, spacing: 12) {
            statusCard(
                title: "辅助功能",
                detail: "必需：读取选区、确认焦点并安全替换",
                isReady: snapshot.accessibilityGranted,
                readyText: "已授权",
                missingText: "未授权"
            ) {
                HStack {
                    Button(snapshot.accessibilityGranted ? "打开设置" : "请求授权") {
                        if snapshot.accessibilityGranted {
                            state.openAccessibilitySettings()
                        } else {
                            state.requestAccessibility()
                        }
                    }
                    .accessibilityIdentifier("cpt.setup.accessibility")
                    if !snapshot.accessibilityGranted {
                        Button("直接打开设置") { state.openAccessibilitySettings() }
                    }
                }
            }

            statusCard(
                title: "Apple 本地翻译",
                detail: "macOS 15+；缺少语言包时由系统确认下载",
                isReady: true,
                readyText: "可用",
                missingText: "不可用"
            ) { EmptyView() }

            statusCard(
                title: "屏幕录制",
                detail: "可选：仅供主动框选 OCR、字幕区域和二次确认的回复 OCR",
                isReady: snapshot.screenRecordingGranted,
                readyText: "已授权（可选）",
                missingText: "未授权（正常）"
            ) {
                Button("打开设置") { state.openScreenRecordingSettings() }
                    .accessibilityIdentifier("cpt.setup.screen-recording")
            }
        }
    }

    private var preferenceLearningSection: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 5) {
                Text("两周本机语言偏好")
                    .font(.headline)
                Text("从第一次成功的主动翻译开始计时；满 14 天且至少 8 次、某方向达到 67% 后，自动语言路由才会采用该偏好。只保存评估时间、语言代码和聚合次数/分数，不保存原文、译文、App 或窗口信息。回复翻译、自动选区、悬停和字幕不会计入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.translationPreferenceLearningSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(
                        Color(nsColor: model.translationPreferenceLearningEnabled
                            ? .controlAccentColor
                            : .secondaryLabelColor)
                    )
                    .accessibilityIdentifier("cpt.setup.preference-summary")
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Toggle("启用", isOn: $model.translationPreferenceLearningEnabled)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("cpt.setup.preference-toggle")
                Button("重置统计") {
                    state.confirmAndResetTranslationPreferenceLearning()
                }
                .controlSize(.small)
                .disabled(model.translationPreferenceObservationCount == 0)
                .accessibilityIdentifier("cpt.setup.preference-reset")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("完整使用链路")
                .font(.title3.weight(.semibold))

            workflowRow(
                number: "1",
                title: "任意 App 选区翻译",
                detail: "选中文字 → 点击“翻译选区”或按 ⌃⌥T → 先查看译文；只有焦点、窗口和原文都未变化时才可替换。"
            ) {
                Button("打开合成测试文本") { onOpenSyntheticTest() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("cpt.setup.synthetic-selection")
            }

            workflowRow(
                number: "2",
                title: "AI 输入草稿翻译",
                detail: "先点进 ChatGPT / Claude 的消息输入框，再点击“翻译输入”。只写入草稿，不按 Enter、不发送。"
            ) {
                if state.runningAIApplications.isEmpty {
                    Button("显示 AI 兼容边缘栏") { onShowAIBar(nil) }
                        .accessibilityIdentifier("cpt.setup.ai-bar")
                } else {
                    Menu("选择并显示 AI 窗口") {
                        ForEach(state.runningAIApplications) { application in
                            Button(application.name) {
                                onShowAIBar(application.processIdentifier)
                            }
                            .accessibilityIdentifier(
                                "cpt.setup.ai-app.\(application.processIdentifier)"
                            )
                        }
                    }
                    .accessibilityIdentifier("cpt.setup.ai-bar")
                }
            }

            workflowRow(
                number: "3",
                title: "AI 回复翻译",
                detail: "优先选中 assistant 回复；没有选区时读取最新可见回复。第一次失败只提示，再次点击才会请求 OCR。"
            ) {
                VStack(alignment: .trailing, spacing: 6) {
                    Button(responseTranslationButtonTitle) { onTranslateAIResponse() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("cpt.setup.translate-response")
                    if !model.responseTranslationStatus.isEmpty {
                        Text(model.responseTranslationStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 260, alignment: .trailing)
                            .accessibilityIdentifier("cpt.setup.response-status")
                    }
                }
            }

            if !model.responseTranslationText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("回复译文")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(model.responseTranslationText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("cpt.setup.response-result")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
            }

            workflowRow(
                number: "4",
                title: "悬停与图片 / Canvas OCR",
                detail: "悬停只读取静态 AX 文字并排除输入框；图片或 Canvas 请主动框选 OCR。"
            ) {
                Button("打开合成 OCR 测试") { onOpenSyntheticOCRTest() }
                    .accessibilityIdentifier("cpt.setup.synthetic-ocr")
            }

            workflowRow(
                number: "5",
                title: "视频字幕翻译",
                detail: "框选固定字幕区域；相同画面稳定后翻译。可选双语/仅译文和字幕样式。"
            ) {
                Button("打开合成字幕测试") { onOpenSyntheticSubtitleTest() }
                    .accessibilityIdentifier("cpt.setup.synthetic-subtitle")
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("隐私与兼容状态")
                .font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                privacyPill(
                    snapshot.clipboardCompatibilityEnabled ? "剪贴板兼容：已开启" : "剪贴板兼容：已关闭（推荐）",
                    warning: snapshot.clipboardCompatibilityEnabled
                )
                privacyPill(
                    snapshot.responseTranslationEnabled ? "自动回复：已开启（仅 AX）" : "自动回复：已关闭",
                    warning: false
                )
                privacyPill(
                    "选区：\(snapshot.automaticLanguageRoutingEnabled ? "自动" : "固定") · AI：\(snapshot.aiInputTargetLanguageName)",
                    warning: false
                )
            }
            Text("应用没有联网翻译后备：Apple 不支持的语言组合会明确失败。剪贴板兼容和悬停默认关闭；回复翻译从不使用剪贴板。只有主动框选的 OCR/字幕，或二次确认的回复 OCR，才会截取限定区域。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var responseTranslationButtonTitle: String {
        if model.isResponseTranslating {
            return "取消回复读取"
        }
        if model.unifiedBarController.isManualResponseOCRRetryAvailable {
            return "使用 OCR 重试（需屏幕录制）"
        }
        return "翻译已选/最新回复"
    }

    private var footer: some View {
        HStack {
            if !snapshot.translatorEnabled || !snapshot.selectionDetectionEnabled {
                Button("启用翻译与选区识别") { state.enableTranslator() }
                    .buttonStyle(.borderedProminent)
            }
            Button("复制脱敏诊断") { state.copySanitizedDiagnostics() }
                .accessibilityIdentifier("cpt.setup.copy-diagnostics")
            Spacer()
            Text("任何翻译动作都不会替你发送消息。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func statusCard<Actions: View>(
        title: String,
        detail: String,
        isReady: Bool,
        readyText: String,
        missingText: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isReady ? .green : .secondary)
                Text(title).font(.headline)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(isReady ? readyText : missingText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isReady ? .green : .secondary)
            actions()
                .controlSize(.small)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func principleCard(systemImage: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func workflowRow<Actions: View>(
        number: String,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions()
                .controlSize(.small)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
    }

    private func privacyPill(_ title: String, warning: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill((warning ? Color.orange : Color.accentColor).opacity(0.11)))
    }
}
