import AppKit
import CoreVideo
import SwiftUI

enum PrivacyPreferenceGate {
    static func canEnable(savedEnabled: Bool, privacyAcknowledged: Bool) -> Bool {
        savedEnabled && privacyAcknowledged
    }
}

enum TranslationOperationSafety {
    static func canContinue(
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        translatorEnabled: Bool
    ) -> Bool {
        translatorEnabled && expectedGeneration == currentGeneration
    }
}

struct RecentResponseSelectionSnapshot: Equatable, Sendable {
    let response: DetectedForeignResponse
    let processIdentifier: pid_t
    let capturedAt: Date
}

enum ResponseSelectionSnapshotPolicy {
    static let maximumRetention: TimeInterval = 15

    static func isFresh(
        snapshotProcessIdentifier: pid_t,
        targetProcessIdentifier: pid_t,
        capturedAt: Date,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        snapshotProcessIdentifier == targetProcessIdentifier
            && now.timeIntervalSince(capturedAt) >= 0
            && now.timeIntervalSince(capturedAt) <= maximumAge
    }
}

enum ResponseSelectionSnapshotCapturePolicy {
    static func allows(_ captureMethod: SelectionCaptureMethod) -> Bool {
        captureMethod == .accessibility
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum ShowReason {
        case autoClaude
        case floatingButton
        case hotkey
        case manual
    }

    enum PanelPresentation {
        case expanded
        case compact
    }

    @Published var promptText = ""
    @Published var lastTranslation = ""
    @Published var statusMessage = ""
    @Published var isTranslating = false
    @Published var isResponseTranslating = false
    @Published var focusTrigger = 0
    @Published var panelPresentation: PanelPresentation = .expanded
    @Published var targetAppName = ""
    @Published var translatorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(translatorEnabled, forKey: DefaultsKey.translatorEnabled)
        }
    }
    @Published var autoShowWhenClaudeIsActive: Bool {
        didSet {
            UserDefaults.standard.set(autoShowWhenClaudeIsActive, forKey: DefaultsKey.autoShow)
        }
    }
    @Published var unifiedBarEnabled: Bool {
        didSet {
            UserDefaults.standard.set(unifiedBarEnabled, forKey: DefaultsKey.unifiedBarEnabled)
            reconcileRuntime()
        }
    }
    @Published var floatingTriggerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(floatingTriggerEnabled, forKey: DefaultsKey.floatingTrigger)
        }
    }
    @Published var responseTranslationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(responseTranslationEnabled, forKey: DefaultsKey.responseTranslationEnabled)
            reconcileRuntime()
        }
    }
    @Published var clipboardCompatibilityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                clipboardCompatibilityEnabled,
                forKey: DefaultsKey.clipboardCompatibilityEnabled
            )
        }
    }
    @Published private(set) var blockedApplicationBundleIdentifiers: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(
                blockedApplicationBundleIdentifiers.sorted(),
                forKey: DefaultsKey.blockedApplicationBundleIdentifiers
            )
        }
    }
    @Published var contentFilterLevel: ContentFilterLevel = .bodyFirst {
        didSet {
            UserDefaults.standard.set(contentFilterLevel.rawValue, forKey: DefaultsKey.contentFilterLevel)
        }
    }
    @Published var selectionDetectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(selectionDetectionEnabled, forKey: DefaultsKey.selectionDetectionEnabled)
            reconcileRuntime()
            if !selectionDetectionEnabled {
                dismissSelectionOverlay()
            }
        }
    }
    @Published var automaticSelectionTranslationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                automaticSelectionTranslationEnabled,
                forKey: DefaultsKey.automaticSelectionTranslationEnabled
            )
        }
    }
    @Published var hoverTranslationEnabled = false {
        didSet {
            UserDefaults.standard.set(
                hoverTranslationEnabled,
                forKey: DefaultsKey.hoverTranslationEnabled
            )
            reconcileRuntime()
        }
    }
    @Published var automaticLanguageRoutingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                automaticLanguageRoutingEnabled,
                forKey: DefaultsKey.automaticLanguageRoutingEnabled
            )
        }
    }
    @Published var translationPreferenceLearningEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(
                translationPreferenceLearningEnabled,
                forKey: DefaultsKey.translationPreferenceLearningEnabled
            )
            refreshTranslationPreferenceLearning()
        }
    }
    @Published var targetLanguage: TargetLanguage {
        didSet {
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: DefaultsKey.targetLanguage)
        }
    }
    @Published var appTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: DefaultsKey.appTheme)
            storedPanelController?.applyAppearance()
        }
    }
    @Published var responseSourceText = ""
    @Published var responseSourceLanguageName = ""
    @Published var responseTranslationText = ""
    @Published var responseTranslationStatus = ""
    @Published var selectionPhase: SelectionTranslationPhase = .idle
    @Published var selectionSourceText = ""
    @Published var selectionTranslationText = ""
    @Published var selectionStatus = ""
    @Published var selectionSourceLanguageName = "自动识别"
    @Published var selectionTargetLanguageName = "简体中文"
    @Published var selectionSourceAppName = "当前应用"
    @Published var selectionCanReplace = false
    @Published private(set) var translationPreferenceLearningSummary = ""
    @Published private(set) var translationPreferenceObservationCount = 0
    @Published var selectionDisplayMode: SubtitleDisplayMode = .bilingual {
        didSet {
            UserDefaults.standard.set(selectionDisplayMode.rawValue, forKey: DefaultsKey.selectionDisplayMode)
            storedSelectionOverlayController?.refresh()
        }
    }
    @Published var subtitleTranslationActive = false
    @Published var subtitleSourceText = ""
    @Published var subtitleTranslationText = ""
    @Published var subtitleStatus = "未启动"
    @Published var subtitleTargetLanguageName = "自动"
    @Published var subtitleRecognitionMode: SubtitleRecognitionMode = .regionOCR {
        didSet {
            UserDefaults.standard.set(
                subtitleRecognitionMode.rawValue,
                forKey: DefaultsKey.subtitleRecognitionMode
            )
        }
    }
    @Published var subtitleSpeechLocale: SubtitleSpeechLocale = .system {
        didSet {
            UserDefaults.standard.set(
                subtitleSpeechLocale.rawValue,
                forKey: DefaultsKey.subtitleSpeechLocale
            )
        }
    }
    @Published var subtitleDisplayMode: SubtitleDisplayMode = .bilingual {
        didSet {
            UserDefaults.standard.set(subtitleDisplayMode.rawValue, forKey: DefaultsKey.subtitleDisplayMode)
            storedSubtitleOverlayController?.refresh()
        }
    }
    @Published var subtitleOverlayStyle: SubtitleOverlayStyle = .dark {
        didSet {
            UserDefaults.standard.set(subtitleOverlayStyle.rawValue, forKey: DefaultsKey.subtitleOverlayStyle)
            storedSubtitleOverlayController?.refresh()
        }
    }
    @Published var subtitleFontSize: CGFloat = 22 {
        didSet {
            let bounded = min(max(subtitleFontSize, 16), 34)
            if bounded != subtitleFontSize {
                subtitleFontSize = bounded
                return
            }
            UserDefaults.standard.set(Double(subtitleFontSize), forKey: DefaultsKey.subtitleFontSize)
            storedSubtitleOverlayController?.refresh()
        }
    }

    let detector = ClaudeContextDetector()

    private var storedUnifiedBarController: UnifiedEdgeBarController?
    private var storedSelectionOverlayController: SelectionOverlayController?
    private var storedSubtitleOverlayController: SubtitleOverlayController?

    var unifiedBarController: UnifiedEdgeBarController {
        if let storedUnifiedBarController { return storedUnifiedBarController }
        let controller = UnifiedEdgeBarController(model: self)
        storedUnifiedBarController = controller
        return controller
    }

    private var selectionOverlayController: SelectionOverlayController {
        selectionOverlayReleaseTask?.cancel()
        selectionOverlayReleaseTask = nil
        if let storedSelectionOverlayController { return storedSelectionOverlayController }
        let controller = SelectionOverlayController(model: self)
        storedSelectionOverlayController = controller
        return controller
    }

    private var subtitleOverlayController: SubtitleOverlayController {
        if let storedSubtitleOverlayController { return storedSubtitleOverlayController }
        let controller = SubtitleOverlayController(model: self)
        storedSubtitleOverlayController = controller
        return controller
    }

    private let translator = AutomaticTranslationClient()
    private let deliveryService = TextDeliveryService()
    private let selectionReader = UniversalSelectionReader()
    private let hoverReader = HoverTextReader()
    private let screenRegionOCRService = ScreenRegionOCRService()
    private let subtitleSpeechSession = SubtitleSpeechSession()
    private let subtitleTranslationCache = SubtitleTranslationCache()
    private lazy var subtitlePipeline = LiveSubtitlePipeline(
        cache: subtitleTranslationCache,
        targetResolver: { text in
            // Cue recognition runs outside the main actor. Keep routing pure;
            // presentation can still apply UI-owned learned preferences.
            SelectionLanguageRouter.route(for: text).targetLanguage
        },
        translator: { [translator] text, target in
            try await translator.translate(text, to: target, workKind: .subtitle)
        }
    )
    private var storedPanelController: PromptPanelController?
    private var storedSelectionMonitor: UniversalSelectionMonitor?
    private var storedHoverMonitor: HoverTranslationMonitor?
    private var storedScreenRegionSelectionController: ScreenRegionSelectionController?

    private var panelController: PromptPanelController {
        panelReleaseTask?.cancel()
        panelReleaseTask = nil
        if let storedPanelController { return storedPanelController }
        let controller = PromptPanelController(model: self)
        storedPanelController = controller
        return controller
    }

    private var selectionMonitor: UniversalSelectionMonitor {
        if let storedSelectionMonitor { return storedSelectionMonitor }
        let controller = UniversalSelectionMonitor(
            isApplicationAllowed: { [weak self] app in
                self?.isCaptureAllowed(in: app) == true
            },
            handler: { [weak self] app, hints in
                self?.storedUnifiedBarController?.refresh()
                self?.inspectPassiveSelection(in: app, hints: hints)
            }
        )
        storedSelectionMonitor = controller
        return controller
    }

    private var hoverMonitor: HoverTranslationMonitor {
        if let storedHoverMonitor { return storedHoverMonitor }
        let controller = HoverTranslationMonitor { [weak self] app, point in
            self?.inspectHoverText(in: app, at: point)
        }
        storedHoverMonitor = controller
        return controller
    }

    private var screenRegionSelectionController: ScreenRegionSelectionController {
        if let storedScreenRegionSelectionController { return storedScreenRegionSelectionController }
        let controller = ScreenRegionSelectionController()
        storedScreenRegionSelectionController = controller
        return controller
    }
    private var lastInputTarget: InputTarget?
    private var detectedSelection: UniversalTextSelection?
    private var selectionCaptureTask: Task<Void, Never>?
    private var selectionTranslationTask: Task<Void, Never>?
    private var selectionReplacementTask: Task<Void, Never>?
    private var hoverCaptureTask: Task<Void, Never>?
    private var screenOCRTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var subtitleCaptureTask: Task<Void, Never>?
    private var subtitleCaptureStream: SubtitleCaptureStream?
    private var subtitleEventTask: Task<Void, Never>?
    private var subtitleSpeechEventTask: Task<Void, Never>?
    private var subtitleSpeechShutdownTask: Task<Void, Never>?
    private var subtitlePipelineShutdownTask: Task<Void, Never>?
    private var subtitleSessionGeneration: UInt64 = 0
    private var subtitleSequence: UInt64 = 0
    private var inputTranslationTask: Task<Void, Never>?
    private var inputTranslationGeneration: UInt64 = 0
    private var selectionGeneration = 0
    private var lastPassiveSelectionFingerprint = ""
    private var recentResponseSelectionSnapshot: RecentResponseSelectionSnapshot?
    private var responseSelectionExpiryTask: Task<Void, Never>?
    private var panelReleaseTask: Task<Void, Never>?
    private var selectionOverlayReleaseTask: Task<Void, Never>?
    private var lastHoverFingerprint = ""
    private var lastHoverDate = Date.distantPast
    private var selectionFilterNote = ""
    private var translationPreferenceProfile = TranslationPreferenceProfile()
    private var runtimeCoordinator = AppRuntimeCoordinator()
    private var runtimeMemoryPressureMonitor: RuntimeMemoryPressureMonitor?
    private var lastRuntimeForegroundApplication: NSRunningApplication?

    init() {
        let savedTarget = UserDefaults.standard.string(forKey: DefaultsKey.targetLanguage)
            .flatMap(TargetLanguage.init(rawValue:)) ?? .english
        self.targetLanguage = savedTarget

        let savedTheme = UserDefaults.standard.string(forKey: DefaultsKey.appTheme)
            .flatMap(AppTheme.init(rawValue:)) ?? .claude
        self.appTheme = savedTheme

        if UserDefaults.standard.object(forKey: DefaultsKey.translatorEnabled) == nil {
            self.translatorEnabled = true
        } else {
            self.translatorEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.translatorEnabled)
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.autoShow) == nil {
            self.autoShowWhenClaudeIsActive = true
        } else {
            self.autoShowWhenClaudeIsActive = UserDefaults.standard.bool(forKey: DefaultsKey.autoShow)
        }

        if !UserDefaults.standard.bool(forKey: DefaultsKey.inlineInputPillMigration) {
            self.floatingTriggerEnabled = true
            UserDefaults.standard.set(true, forKey: DefaultsKey.floatingTrigger)
            UserDefaults.standard.set(true, forKey: DefaultsKey.inlineInputPillMigration)
        } else if UserDefaults.standard.object(forKey: DefaultsKey.floatingTrigger) == nil {
            self.floatingTriggerEnabled = true
        } else {
            self.floatingTriggerEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.floatingTrigger)
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.responseTranslationEnabled) == nil {
            self.responseTranslationEnabled = false
        } else {
            let savedEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.responseTranslationEnabled)
            let privacyAcknowledged = UserDefaults.standard.bool(
                forKey: DefaultsKey.responseTranslationPrivacyAcknowledged
            )
            self.responseTranslationEnabled = savedEnabled && privacyAcknowledged
            if savedEnabled, !privacyAcknowledged {
                UserDefaults.standard.set(false, forKey: DefaultsKey.responseTranslationEnabled)
            }
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.clipboardCompatibilityEnabled) == nil {
            self.clipboardCompatibilityEnabled = false
        } else {
            let savedEnabled = UserDefaults.standard.bool(
                forKey: DefaultsKey.clipboardCompatibilityEnabled
            )
            let privacyAcknowledged = UserDefaults.standard.bool(
                forKey: DefaultsKey.clipboardCompatibilityPrivacyAcknowledged
            )
            self.clipboardCompatibilityEnabled = PrivacyPreferenceGate.canEnable(
                savedEnabled: savedEnabled,
                privacyAcknowledged: privacyAcknowledged
            )
            if savedEnabled, !privacyAcknowledged {
                UserDefaults.standard.set(false, forKey: DefaultsKey.clipboardCompatibilityEnabled)
            }
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.selectionDetectionEnabled) == nil {
            self.selectionDetectionEnabled = true
        } else {
            self.selectionDetectionEnabled = UserDefaults.standard.bool(
                forKey: DefaultsKey.selectionDetectionEnabled
            )
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.automaticLanguageRoutingEnabled) == nil {
            self.automaticLanguageRoutingEnabled = true
        } else {
            self.automaticLanguageRoutingEnabled = UserDefaults.standard.bool(
                forKey: DefaultsKey.automaticLanguageRoutingEnabled
            )
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.translationPreferenceLearningEnabled) == nil {
            self.translationPreferenceLearningEnabled = true
        } else {
            self.translationPreferenceLearningEnabled = UserDefaults.standard.bool(
                forKey: DefaultsKey.translationPreferenceLearningEnabled
            )
        }
        self.translationPreferenceProfile = TranslationPreferencePersistence.load()

        let automaticSelectionPrivacyAcknowledged = UserDefaults.standard.bool(
            forKey: DefaultsKey.automaticSelectionTranslationPrivacyAcknowledged
        )
        if UserDefaults.standard.object(forKey: DefaultsKey.automaticSelectionTranslationEnabled) == nil {
            self.automaticSelectionTranslationEnabled = false
        } else {
            self.automaticSelectionTranslationEnabled = UserDefaults.standard.bool(
                forKey: DefaultsKey.automaticSelectionTranslationEnabled
            ) && automaticSelectionPrivacyAcknowledged
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.hoverTranslationEnabled) == nil {
            self.hoverTranslationEnabled = false
        } else {
            self.hoverTranslationEnabled = UserDefaults.standard.bool(
                forKey: DefaultsKey.hoverTranslationEnabled
            )
        }

        self.blockedApplicationBundleIdentifiers = Set(
            UserDefaults.standard.stringArray(
                forKey: DefaultsKey.blockedApplicationBundleIdentifiers
            )?.compactMap(AppPrivacyPolicy.normalizedIdentifier) ?? []
        )
        self.contentFilterLevel = UserDefaults.standard.string(forKey: DefaultsKey.contentFilterLevel)
            .flatMap(ContentFilterLevel.init(rawValue:)) ?? .bodyFirst

        self.subtitleDisplayMode = UserDefaults.standard.string(forKey: DefaultsKey.subtitleDisplayMode)
            .flatMap(SubtitleDisplayMode.init(rawValue:)) ?? .bilingual
        self.subtitleRecognitionMode = UserDefaults.standard.string(
            forKey: DefaultsKey.subtitleRecognitionMode
        ).flatMap(SubtitleRecognitionMode.init(rawValue:)) ?? .regionOCR
        self.subtitleSpeechLocale = UserDefaults.standard.string(
            forKey: DefaultsKey.subtitleSpeechLocale
        ).flatMap(SubtitleSpeechLocale.init(rawValue:)) ?? .system
        self.subtitleOverlayStyle = UserDefaults.standard.string(forKey: DefaultsKey.subtitleOverlayStyle)
            .flatMap(SubtitleOverlayStyle.init(rawValue:)) ?? .dark
        let savedSubtitleFontSize = UserDefaults.standard.double(forKey: DefaultsKey.subtitleFontSize)
        self.subtitleFontSize = savedSubtitleFontSize > 0
            ? CGFloat(min(max(savedSubtitleFontSize, 16), 34))
            : 22
        self.selectionDisplayMode = UserDefaults.standard.string(forKey: DefaultsKey.selectionDisplayMode)
            .flatMap(SubtitleDisplayMode.init(rawValue:)) ?? .bilingual

        // Unified bar: default on, migrating from old individual settings
        if UserDefaults.standard.object(forKey: DefaultsKey.unifiedBarEnabled) == nil {
            self.unifiedBarEnabled = true
        } else {
            self.unifiedBarEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.unifiedBarEnabled)
        }

        refreshTranslationPreferenceLearning()
    }

    func showPanel(reason: ShowReason) {
        showPanel(target: nil, reason: reason)
    }

#if DEBUG
    /// Deterministic, content-safe visual state for theme review. This helper is
    /// compiled out of Release and never reads another application.
    func showSelectionOverlayThemePreview() {
        selectionDisplayMode = .bilingual
        selectionPhase = .translated
        selectionSourceText = "A calm interface keeps the translation itself in focus."
        selectionTranslationText = "克制的界面，让翻译内容始终成为焦点。"
        selectionStatus = "Apple 本机翻译 · 示例内容"
        selectionSourceLanguageName = "English"
        selectionTargetLanguageName = "简体中文"
        selectionSourceAppName = "安全预览"
        selectionCanReplace = false

        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let anchor = NSRect(
            x: visibleFrame.midX - 120,
            y: visibleFrame.midY + 120,
            width: 240,
            height: 28
        )
        selectionOverlayController.show(anchorRect: anchor)
        NSApp.activate()
    }
#endif

    func startRuntimeCoordination(
        foregroundApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) {
        if runtimeMemoryPressureMonitor == nil {
            let monitor = RuntimeMemoryPressureMonitor { [weak self] pressure in
                self?.handleRuntimeMemoryPressure(pressure)
            }
            runtimeMemoryPressureMonitor = monitor
            monitor.start()
        }
        reconcileRuntime(foregroundApplication: foregroundApplication)
    }

    func stopRuntimeCoordination() {
        runtimeMemoryPressureMonitor?.stop()
        runtimeMemoryPressureMonitor = nil
        applyRuntimeTransition(runtimeCoordinator.handle(.terminate))
    }

    func setRuntimeSuspended(_ suspended: Bool) {
        applyRuntimeTransition(runtimeCoordinator.handle(.setSuspended(suspended)))
        if !suspended {
            reconcileRuntime()
        }
    }

    func reconcileRuntime(
        foregroundApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) {
        if let foregroundApplication, !isHelperApp(foregroundApplication) {
            lastRuntimeForegroundApplication = foregroundApplication
        }
        let foreground = foregroundApplication.flatMap { isHelperApp($0) ? nil : $0 }
            ?? lastRuntimeForegroundApplication
        let foregroundIsAI = foreground.map {
            isCaptureAllowed(in: $0) && detector.isAIContext($0)
        } ?? false
        let context = RuntimeContext(
            translatorEnabled: translatorEnabled,
            accessibilityTrusted: AccessibilityPermission.isTrusted,
            selectionEnabled: selectionDetectionEnabled,
            hoverEnabled: hoverTranslationEnabled,
            unifiedBarEnabled: unifiedBarEnabled,
            responseTranslationEnabled: responseTranslationEnabled,
            foregroundIsAI: foregroundIsAI,
            subtitleActive: subtitleTranslationActive,
            promptUIVisible: storedPanelController?.isVisible == true,
            guideUIVisible: false
        )
        applyRuntimeTransition(runtimeCoordinator.handle(.reconcile(context)))
        if runtimeCoordinator.demand.contains(.aiContext) {
            storedUnifiedBarController?.refresh()
        }
    }

    private func applyRuntimeTransition(_ transition: RuntimeTransition) {
        if transition.stopped.contains(.selection) {
            storedSelectionMonitor?.stop()
        }
        if transition.stopped.contains(.hover) {
            storedHoverMonitor?.stop()
        }
        if transition.stopped.contains(.aiContext) {
            storedUnifiedBarController?.stop()
        }
        if transition.stopped.contains(.subtitle), subtitleTranslationActive {
            stopSubtitleTranslation(reconcileAfterStop: false)
        }

        if transition.started.contains(.selection) {
            selectionMonitor.start()
        }
        if transition.started.contains(.hover) {
            hoverMonitor.start()
        }
        if transition.started.contains(.aiContext) {
            unifiedBarController.start()
        }
    }

    private func handleRuntimeMemoryPressure(_ pressure: RuntimeMemoryPressure) {
        let actions = MemoryPressurePolicy.actions(for: pressure)
        if actions.contains(.trimCaches) {
            Task { await subtitleTranslationCache.removeAll() }
            storedUnifiedBarController?.trimCachesForMemoryPressure()
        }
        if actions.contains(.releaseHiddenUI) {
            if storedPanelController?.isVisible != true {
                storedPanelController?.releaseResources()
                storedPanelController = nil
            }
            if storedSelectionOverlayController?.isVisible != true {
                storedSelectionOverlayController?.releaseResources()
                storedSelectionOverlayController = nil
            }
            if !subtitleTranslationActive {
                storedSubtitleOverlayController?.releaseResources()
                storedSubtitleOverlayController = nil
            }
            storedUnifiedBarController?.releaseHiddenResources()
        }
        if actions.contains(.releaseIdleTranslationHost) {
#if canImport(Translation)
            if #available(macOS 15.0, *) {
                AppleTranslationCoordinator.shared.releaseIdleResources()
            }
#endif
        }
        if actions.contains(.releaseIdleAccessibilityContexts),
           !runtimeCoordinator.demand.contains(.selection) {
            storedSelectionMonitor?.stop()
            storedSelectionMonitor = nil
        }
    }

    func setTranslatorEnabled(_ enabled: Bool) {
        guard translatorEnabled != enabled else {
            return
        }

        translatorEnabled = enabled
        reconcileRuntime()
        if enabled {
            statusMessage = "跨应用选区翻译已开启。"
        } else {
            statusMessage = "翻译器已暂停。"
            Task {
                await TranslationWorkBroker.shared.cancelAll()
#if canImport(Translation)
                if #available(macOS 15.0, *) {
                    AppleTranslationCoordinator.shared.releaseIdleResources()
                }
#endif
            }
            inputTranslationGeneration &+= 1
            inputTranslationTask?.cancel()
            inputTranslationTask = nil
            isTranslating = false
            isResponseTranslating = false
            stopSelectionMonitoring()
            dismissSelectionOverlay()
            selectionSourceText = ""
            selectionTranslationText = ""
            subtitleSourceText = ""
            subtitleTranslationText = ""
            storedUnifiedBarController?.stop()
            clearResponseTranslation()
            hidePanel()
        }
    }

    func revealEdgeBar() {
        guard translatorEnabled else {
            statusMessage = "无感翻译已暂停，请从菜单栏重新开启。"
            return
        }
        unifiedBarEnabled = true
        statusMessage = "AI 兼容边缘栏已就绪。"
        reconcileRuntime()
        guard runtimeCoordinator.demand.contains(.aiContext) else {
            statusMessage = "请先切换到已授权的 ChatGPT、Claude 或其他 AI 对话窗口。"
            return
        }
        unifiedBarController.revealTemporarily()
    }

    func showPanel(target: InputTarget?, reason: ShowReason) {
        guard translatorEnabled else {
            statusMessage = "无感翻译已暂停，请从菜单栏重新开启。"
            return
        }

        if let target, !isCaptureAllowed(in: target.app) {
            statusMessage = privacyBlockedMessage(for: target.app)
            return
        }
        if target == nil,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           !isHelperApp(frontmost),
           !isCaptureAllowed(in: frontmost) {
            statusMessage = privacyBlockedMessage(for: frontmost)
            return
        }

        if let target {
            rememberTarget(target)
        } else if let frontmost = NSWorkspace.shared.frontmostApplication, !isHelperApp(frontmost) {
            rememberTarget(frontmost)
        }

        panelPresentation = reason == .manual ? .expanded : .compact
        guard AccessibilityPermission.isTrusted else {
            statusMessage = "请先授予辅助功能权限；备用窗只写入草稿，不会发送。"
            panelController.show()
            focusTrigger += 1
            return
        }

        switch reason {
        case .autoClaude:
            statusMessage = "已识别 Claude；输入中文后按 Enter，仅翻译并写入草稿。"
        case .floatingButton:
            statusMessage = "已识别消息输入框；按 Enter 只写入译文草稿。"
        case .hotkey:
            statusMessage = "草稿翻译窗已打开；不会替你发送消息。"
        case .manual:
            statusMessage = "请输入草稿；翻译后只写入目标输入框，不会发送。"
        }

        panelController.show()
        focusTrigger += 1
    }

    func showReplyTranslationPanel(for app: NSRunningApplication?) {
        if let app, !isCaptureAllowed(in: app) {
            statusMessage = privacyBlockedMessage(for: app)
            return
        }
        if let app, !isHelperApp(app) {
            rememberTarget(app)
        }

        guard storedPanelController?.isVisible != true else {
            return
        }

        if hasResponseTranslationActivity {
            panelPresentation = .compact
        }
        panelController.showPassive()
    }

    func hidePanel() {
        guard let controller = storedPanelController else { return }
        controller.hide()
        panelReleaseTask?.cancel()
        panelReleaseTask = Task { @MainActor [weak self, weak controller] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard let self,
                  self.storedPanelController === controller,
                  controller?.isVisible != true else { return }
            controller?.releaseResources()
            self.storedPanelController = nil
            self.panelReleaseTask = nil
        }
    }

    func expandPanel() {
        panelPresentation = .expanded
        panelController.applyPresentation(animated: true)
        focusTrigger += 1
    }

    func collapsePanelForNextPrompt() {
        panelPresentation = .compact
        panelController.applyPresentation(animated: false)
        panelController.bringToFront()
        focusTrigger += 1
    }

    var isPromptPanelVisible: Bool {
        storedPanelController?.isVisible == true
    }

    var isUnifiedBarRunning: Bool {
        storedUnifiedBarController?.isRunning == true
    }

    var isManualResponseOCRRetryAvailable: Bool {
        storedUnifiedBarController?.isManualResponseOCRRetryAvailable == true
    }

    var loadedResponseTargetApplication: NSRunningApplication? {
        storedUnifiedBarController?.responseTargetApplication
    }

    func selectionMonitorOwnsAXObserver(for processIdentifier: pid_t) -> Bool {
        storedSelectionMonitor?.ownsAccessibilityObserver(for: processIdentifier) == true
    }

    func startUnifiedBar() {
        reconcileRuntime()
    }

    func stopUnifiedBar() {
        storedUnifiedBarController?.stop()
    }

    func refreshUnifiedBarIfLoaded() {
        storedUnifiedBarController?.refresh()
    }

    func translateLatestResponseFromBar() {
        unifiedBarController.translateLatestResponse()
    }

    func copyLatestResponseFromBar() {
        guard let controller = storedUnifiedBarController else {
            statusMessage = "当前没有可复制的回复译文。"
            return
        }
        controller.copyResponseTranslation()
    }

    var hasResponseTranslationActivity: Bool {
        isResponseTranslating
            || !responseSourceText.isEmpty
            || !responseTranslationText.isEmpty
            || !responseTranslationStatus.isEmpty
    }

    var responseScanApplication: NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isCaptureAllowed(in: frontmost), detector.isAIContext(frontmost) {
            return frontmost
        }

        if let app = lastInputTarget?.app, !app.isTerminated, isCaptureAllowed(in: app) {
            return app
        }

        return nil
    }

    func rememberTarget(_ app: NSRunningApplication) {
        guard isCaptureAllowed(in: app), detector.isAIContext(app) else {
            return
        }
        if let target = InputTarget.captureTextTarget(from: app) {
            rememberTarget(target)
        }
    }

    func rememberTarget(_ target: InputTarget) {
        guard isCaptureAllowed(in: target.app) else {
            return
        }
        if targetAppName != target.appName {
            lastTranslation = ""
        }
        lastInputTarget = target
        targetAppName = target.appName
    }

    func isHelperApp(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == Bundle.main.bundleIdentifier
            || app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    func isCaptureAllowed(in app: NSRunningApplication) -> Bool {
        !isHelperApp(app)
            && AppPrivacyPolicy.allowsCapture(
                bundleIdentifier: app.bundleIdentifier,
                userBlockedIdentifiers: blockedApplicationBundleIdentifiers
            )
    }

    @discardableResult
    func blockApplicationForPrivacy(_ app: NSRunningApplication) -> Bool {
        guard let identifier = AppPrivacyPolicy.normalizedIdentifier(app.bundleIdentifier),
              !AppPrivacyPolicy.isBuiltInProtected(identifier) else {
            statusMessage = "该应用已由内置敏感应用策略保护。"
            return false
        }
        let blockedProcessIdentifier = app.processIdentifier
        blockedApplicationBundleIdentifiers.insert(identifier)
        storedSelectionMonitor?.refreshPrivacyPolicy()
        inputTranslationGeneration &+= 1
        inputTranslationTask?.cancel()
        inputTranslationTask = nil
        selectionCaptureTask?.cancel()
        selectionTranslationTask?.cancel()
        selectionReplacementTask?.cancel()
        hoverCaptureTask?.cancel()
        screenOCRTask?.cancel()
        screenOCRTask = nil
        storedScreenRegionSelectionController?.cancel()
        if lastInputTarget?.app.processIdentifier == app.processIdentifier {
            lastInputTarget = nil
            targetAppName = ""
        }
        purgeSensitiveTranslationState(for: blockedProcessIdentifier)
        stopSubtitleTranslation()
        Task { await subtitleTranslationCache.removeAll() }
        clearRecentResponseSelection(for: blockedProcessIdentifier)
        storedUnifiedBarController?.refresh()
        statusMessage = "已禁止在 \(app.localizedName ?? identifier) 中读取、OCR 或翻译内容。"
        return true
    }

    private func purgeSensitiveTranslationState(for processIdentifier: pid_t) {
        let selectionBelongsToBlockedApplication = detectedSelection?.app.processIdentifier
            == processIdentifier
        dismissSelectionOverlay()
        if selectionBelongsToBlockedApplication || !selectionSourceText.isEmpty {
            selectionSourceText = ""
            selectionTranslationText = ""
            selectionStatus = ""
            selectionSourceLanguageName = "自动识别"
            selectionTargetLanguageName = "简体中文"
            selectionSourceAppName = "当前应用"
            selectionCanReplace = false
        }
        subtitleSourceText = ""
        subtitleTranslationText = ""
        lastTranslation = ""
        clearResponseTranslation()
    }

    @discardableResult
    func allowApplicationForPrivacy(_ app: NSRunningApplication) -> Bool {
        allowApplicationForPrivacy(bundleIdentifier: app.bundleIdentifier)
    }

    @discardableResult
    func allowApplicationForPrivacy(bundleIdentifier: String?) -> Bool {
        guard let identifier = AppPrivacyPolicy.normalizedIdentifier(bundleIdentifier),
              !AppPrivacyPolicy.isBuiltInProtected(identifier) else {
            return false
        }
        let removed = blockedApplicationBundleIdentifiers.remove(identifier) != nil
        if removed {
            statusMessage = "已允许在 \(identifier) 中使用翻译功能。"
            storedSelectionMonitor?.refreshPrivacyPolicy()
            storedUnifiedBarController?.refresh()
        }
        return removed
    }

    var userBlockedApplicationIdentifiers: [String] {
        blockedApplicationBundleIdentifiers.sorted()
    }

    func recordSuccessfulUserTranslation(
        sourceText: String,
        targetLanguage: TargetLanguage,
        targetWasDeliberatelySelected: Bool
    ) {
        guard translationPreferenceLearningEnabled else { return }
        let sourceIdentifier = SelectionLanguageRouter.detectedLanguageIdentifier(in: sourceText)
        recordSuccessfulUserTranslation(
            detectedSourceIdentifier: sourceIdentifier,
            targetLanguage: targetLanguage,
            targetWasDeliberatelySelected: targetWasDeliberatelySelected
        )
    }

    func recordSuccessfulUserTranslation(
        sourceIdentifier: String,
        targetLanguage: TargetLanguage,
        targetWasDeliberatelySelected: Bool
    ) {
        guard translationPreferenceLearningEnabled else { return }
        recordSuccessfulUserTranslation(
            detectedSourceIdentifier: sourceIdentifier,
            targetLanguage: targetLanguage,
            targetWasDeliberatelySelected: targetWasDeliberatelySelected
        )
    }

    func resetTranslationPreferenceLearning() {
        translationPreferenceProfile = TranslationPreferenceProfile()
        TranslationPreferencePersistence.reset()
        refreshTranslationPreferenceLearning()
        statusMessage = "本机语言偏好统计已重置；不会影响现有翻译设置。"
    }

    private func refreshTranslationPreferenceLearning(now: Date = Date()) {
        if translationPreferenceLearningEnabled {
            let evaluated = TranslationPreferenceLearningPolicy.evaluated(
                profile: translationPreferenceProfile,
                at: now
            )
            if evaluated != translationPreferenceProfile {
                translationPreferenceProfile = evaluated
                TranslationPreferencePersistence.save(evaluated)
            }
        }
        translationPreferenceObservationCount = translationPreferenceProfile.totalSuccessfulTranslations
        translationPreferenceLearningSummary = TranslationPreferenceLearningPolicy.summary(
            profile: translationPreferenceProfile,
            enabled: translationPreferenceLearningEnabled,
            now: now
        )
    }

    private func recordSuccessfulUserTranslation(
        detectedSourceIdentifier: String,
        targetLanguage: TargetLanguage,
        targetWasDeliberatelySelected: Bool
    ) {
        translationPreferenceProfile = TranslationPreferenceLearningPolicy.record(
            profile: translationPreferenceProfile,
            sourceIdentifier: detectedSourceIdentifier,
            targetLanguage: targetLanguage,
            at: Date(),
            deliberateTargetWeight: targetWasDeliberatelySelected ? 3 : 1
        )
        TranslationPreferencePersistence.save(translationPreferenceProfile)
        refreshTranslationPreferenceLearning()

    }

    func userInputTargetChoice(
        for sourceText: String
    ) -> (language: TargetLanguage, learned: Bool) {
        guard automaticLanguageRoutingEnabled,
              translationPreferenceLearningEnabled else {
            return (targetLanguage, false)
        }
        let sourceIdentifier = SelectionLanguageRouter.detectedLanguageIdentifier(in: sourceText)
        if let learnedTarget = TranslationPreferenceLearningPolicy.preferredTarget(
            for: sourceIdentifier,
            profile: translationPreferenceProfile
        ) {
            return (learnedTarget, true)
        }
        if TranslationPreferenceLearningPolicy.canonicalSourceIdentifier(sourceIdentifier) == nil,
           let learnedDefault = TranslationPreferenceLearningPolicy.preferredDefaultTarget(
                profile: translationPreferenceProfile
           ) {
            return (learnedDefault, true)
        }
        return (targetLanguage, false)
    }

    private func privacyBlockedMessage(for app: NSRunningApplication) -> String {
        "隐私名单已禁止读取 \(app.localizedName ?? app.bundleIdentifier ?? "此应用")。"
    }

    func submitPrompt() {
        guard translatorEnabled else {
            statusMessage = "无感翻译已暂停，请从菜单栏重新开启。"
            return
        }

        let source = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !isTranslating else {
            return
        }

        let targetChoice = userInputTargetChoice(for: source)
        let translationTarget = targetChoice.language
        if targetChoice.learned, targetLanguage != translationTarget {
            targetLanguage = translationTarget
        }

        isTranslating = true
        statusMessage = targetChoice.learned
            ? "已按两周本机习惯选择\(translationTarget.displayName)，正在翻译…"
            : "正在翻译为\(translationTarget.displayName)…"
        let deliveryTarget = lastInputTarget
        guard deliveryTarget.map({ isCaptureAllowed(in: $0.app) }) ?? true else {
            statusMessage = deliveryTarget.map { privacyBlockedMessage(for: $0.app) }
                ?? "隐私名单已禁止读取此应用。"
            isTranslating = false
            return
        }

        inputTranslationGeneration &+= 1
        let generation = inputTranslationGeneration
        inputTranslationTask?.cancel()
        inputTranslationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if inputTranslationGeneration == generation {
                    inputTranslationTask = nil
                    isTranslating = false
                }
            }
            do {
                guard AccessibilityPermission.isTrusted else {
                    throw DeliveryError.accessibilityPermissionRequired
                }

                let output = try await translator.translate(source, to: translationTarget)
                try Task.checkCancellation()
                guard TranslationOperationSafety.canContinue(
                    expectedGeneration: generation,
                    currentGeneration: inputTranslationGeneration,
                    translatorEnabled: translatorEnabled
                ) else {
                    throw CancellationError()
                }
                guard let deliveryTarget,
                      lastInputTarget?.app.processIdentifier == deliveryTarget.app.processIdentifier else {
                    throw DeliveryError.targetAppChanged
                }
                if let frontmost = NSWorkspace.shared.frontmostApplication,
                   !isHelperApp(frontmost),
                   frontmost.processIdentifier != deliveryTarget.app.processIdentifier {
                    throw DeliveryError.targetAppChanged
                }
                lastTranslation = output.text
                statusMessage = "正在把 \(output.providerName) 译文写入 \(deliveryTarget.appName) 草稿…"
                try await deliveryService.deliver(
                    output.text,
                    to: deliveryTarget,
                    allowClipboardFallback: clipboardCompatibilityEnabled,
                    authorizationCheck: { [weak self] in
                        self?.isCaptureAllowed(in: deliveryTarget.app) == true
                    }
                )
                try Task.checkCancellation()
                guard TranslationOperationSafety.canContinue(
                    expectedGeneration: generation,
                    currentGeneration: inputTranslationGeneration,
                    translatorEnabled: translatorEnabled
                ) else {
                    throw CancellationError()
                }
                recordSuccessfulUserTranslation(
                    sourceText: source,
                    targetLanguage: translationTarget,
                    targetWasDeliberatelySelected: !targetChoice.learned
                )
                promptText = ""
                statusMessage = "已写入 \(deliveryTarget.appName) 草稿；请检查后自行决定是否发送。"
                collapsePanelForNextPrompt()
            } catch is CancellationError {
                if inputTranslationGeneration == generation, translatorEnabled {
                    statusMessage = "翻译已取消。"
                }
            } catch {
                guard inputTranslationGeneration == generation else { return }
                statusMessage = "翻译失败：\(error.localizedDescription)"
            }
        }
    }

    func startSelectionMonitoring() {
        reconcileRuntime()
    }

    func stopSelectionMonitoring() {
        if subtitleTranslationActive
            || subtitleCaptureStream != nil
            || subtitleSpeechEventTask != nil {
            stopSubtitleTranslation(reconcileAfterStop: false)
        }
        storedSelectionMonitor?.stop()
        storedHoverMonitor?.stop()
        storedSelectionMonitor = nil
        storedHoverMonitor = nil
        selectionCaptureTask?.cancel()
        selectionTranslationTask?.cancel()
        selectionReplacementTask?.cancel()
        hoverCaptureTask?.cancel()
        screenOCRTask?.cancel()
        subtitleTask?.cancel()
        storedScreenRegionSelectionController?.cancel()
        storedScreenRegionSelectionController = nil
        selectionCaptureTask = nil
        selectionTranslationTask = nil
        selectionReplacementTask = nil
        hoverCaptureTask = nil
        screenOCRTask = nil
        subtitleTask = nil
        responseSelectionExpiryTask?.cancel()
        responseSelectionExpiryTask = nil
        recentResponseSelectionSnapshot = nil
        storedSubtitleOverlayController?.hide()
        Task { await subtitleTranslationCache.removeAll() }
    }

    func translateScreenRegion() {
        guard translatorEnabled else {
            statusMessage = "翻译器已暂停。"
            return
        }
        guard ScreenRecordingPermission.requestIfNeeded() else {
            showSelectionFailure("区域 OCR 需要屏幕录制权限；授权后重新选择“框选屏幕文字”。")
            return
        }
        guard let sourceApp = NSWorkspace.shared.frontmostApplication,
              !isHelperApp(sourceApp) else {
            showSelectionFailure("请先切换到包含图片、Canvas 或字幕的应用。")
            return
        }
        guard isCaptureAllowed(in: sourceApp) else {
            showSelectionFailure(privacyBlockedMessage(for: sourceApp))
            return
        }

        screenOCRTask?.cancel()
        selectionTranslationTask?.cancel()
        selectionReplacementTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        let suggestedRegion = ScreenRegionSelection.frontmostWindow(of: sourceApp)
        screenOCRTask = Task { [weak self] in
            guard let self,
                  let region = await screenRegionSelectionController.selectRegion(
                      suggestedRegion: suggestedRegion
                  ),
                  !Task.isCancelled else {
                return
            }
            guard isCaptureAllowed(in: sourceApp) else {
                showSelectionFailure(privacyBlockedMessage(for: sourceApp))
                return
            }
            selectionPhase = .reading
            selectionSourceText = ""
            selectionTranslationText = ""
            selectionSourceAppName = sourceApp.localizedName ?? "屏幕区域"
            selectionStatus = "正在本机识别框选区域…"
            selectionCanReplace = false
            selectionOverlayController.show(anchorRect: region.appKitRect)
            do {
                try await Task.sleep(nanoseconds: 140_000_000)
                guard isCaptureAllowed(in: sourceApp) else {
                    throw CancellationError()
                }
                let result = try await screenRegionOCRService.recognize(
                    region: region,
                    sourceApplication: sourceApp,
                    authorizationCheck: { [weak self] in
                        self?.isCaptureAllowed(in: sourceApp) == true
                    }
                )
                guard !Task.isCancelled,
                      selectionGeneration == generation,
                      isCaptureAllowed(in: sourceApp) else { return }
                let selection = UniversalTextSelection(
                    app: sourceApp,
                    rawText: result.text,
                    text: result.text,
                    captureMethod: .screenOCR,
                    anchorRect: region.appKitRect,
                    element: nil,
                    selectedRange: nil
                )
                present(selection)
                selectionStatus = "本机 OCR 识别 \(result.lineCount) 行 · 未保存截图"
                selectionOverlayController.refresh()
                beginTranslation(for: selection, learnsPreference: true)
            } catch is CancellationError {
                return
            } catch {
                guard selectionGeneration == generation else { return }
                showSelectionFailure(error.localizedDescription)
            }
        }
    }

    func startSubtitleTranslation() {
        switch subtitleRecognitionMode {
        case .regionOCR:
            startRegionOCRSubtitleTranslation()
        case .systemSpeech:
            startSystemSpeechSubtitleTranslation()
        case .offlineASRModel:
            statusMessage = "私有 ASR 引擎尚未安装；请选择区域 OCR 或 Apple 设备端语音。"
        }
    }

    private func startRegionOCRSubtitleTranslation() {
        guard translatorEnabled else {
            statusMessage = "翻译器已暂停。"
            return
        }
        guard ScreenRecordingPermission.requestIfNeeded() else {
            statusMessage = "实时字幕需要屏幕录制权限；只处理你框选的字幕区域。"
            return
        }
        guard let sourceApp = NSWorkspace.shared.frontmostApplication,
              !isHelperApp(sourceApp) else {
            statusMessage = "请先切换到正在播放视频的应用。"
            return
        }
        guard isCaptureAllowed(in: sourceApp) else {
            statusMessage = privacyBlockedMessage(for: sourceApp)
            return
        }

        stopSubtitleTranslation()
        let appGeneration = subtitleSessionGeneration
        let previousPipelineShutdown = subtitlePipelineShutdownTask
        subtitleStatus = "请框选视频中的字幕区域"
        let suggestedRegion = ScreenRegionSelection.frontmostWindow(of: sourceApp)
        subtitleTask = Task { [weak self] in
            guard let self else { return }
            guard let region = await screenRegionSelectionController.selectRegion(
                suggestedRegion: suggestedRegion
            ),
                  !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration else {
                if subtitleSessionGeneration == appGeneration {
                    subtitleStatus = "已取消"
                }
                return
            }
            guard subtitleSessionGeneration == appGeneration,
                  isCaptureAllowed(in: sourceApp) else {
                subtitleStatus = privacyBlockedMessage(for: sourceApp)
                return
            }

            await previousPipelineShutdown?.value
            guard !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration,
                  isCaptureAllowed(in: sourceApp) else { return }
            sourceApp.activate()
            subtitleTranslationActive = true
            reconcileRuntime(foregroundApplication: sourceApp)
            subtitleSourceText = ""
            subtitleTranslationText = ""
            subtitleStatus = "本机 OCR 监听中"
            subtitleOverlayController.show(region: region)
            let session = await subtitlePipeline.start()
            guard !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration,
                  subtitleTranslationActive,
                  isCaptureAllowed(in: sourceApp) else {
                await subtitlePipeline.stop(generation: session.generation)
                return
            }
            startSubtitleEventConsumption(
                session: session,
                sourceApplication: sourceApp,
                appGeneration: appGeneration
            )
            startSubtitleFrameProduction(
                region: region,
                sourceApplication: sourceApp,
                generation: session.generation,
                appGeneration: appGeneration
            )
        }
    }

    private func startSystemSpeechSubtitleTranslation() {
        guard translatorEnabled else {
            statusMessage = "翻译器已暂停。"
            return
        }
        guard ScreenRecordingPermission.requestIfNeeded() else {
            statusMessage = "设备端语音字幕需要屏幕录制权限来捕获你明确选择的 App 音频。"
            return
        }
        guard let sourceApp = NSWorkspace.shared.frontmostApplication,
              !isHelperApp(sourceApp),
              !sourceApp.isTerminated else {
            statusMessage = "请先切换到正在播放视频的应用。"
            return
        }
        guard isCaptureAllowed(in: sourceApp) else {
            statusMessage = privacyBlockedMessage(for: sourceApp)
            return
        }
        guard let overlayRegion = ScreenRegionSelection.frontmostWindow(of: sourceApp) else {
            statusMessage = "无法确定目标 App 窗口；未启动音频捕获。"
            return
        }

        stopSubtitleTranslation()
        let appGeneration = subtitleSessionGeneration
        subtitleTranslationActive = true
        reconcileRuntime(foregroundApplication: sourceApp)
        subtitleSourceText = ""
        subtitleTranslationText = ""
        subtitleStatus = "正在准备 Apple 设备端语音识别…"
        subtitleOverlayController.show(region: overlayRegion)

        let previousSpeechShutdown = subtitleSpeechShutdownTask
        let previousPipelineShutdown = subtitlePipelineShutdownTask
        subtitleTask = Task { [weak self] in
            guard let self else { return }
            await previousSpeechShutdown?.value
            await previousPipelineShutdown?.value
            guard !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration,
                  subtitleTranslationActive,
                  isCaptureAllowed(in: sourceApp) else { return }
            let pipelineSession = await subtitlePipeline.start()
            guard !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration,
                  subtitleTranslationActive,
                  isCaptureAllowed(in: sourceApp) else {
                await subtitlePipeline.stop(generation: pipelineSession.generation)
                return
            }
            startSubtitleEventConsumption(
                session: pipelineSession,
                sourceApplication: sourceApp,
                appGeneration: appGeneration
            )

            do {
                let speechHandle = try await subtitleSpeechSession.start(
                    sourceApplication: sourceApp,
                    localeIdentifier: subtitleSpeechLocale.localeIdentifier,
                    authorizationCheck: { [weak self] in
                        self?.subtitleSessionGeneration == appGeneration
                            && self?.subtitleTranslationActive == true
                            && ScreenRecordingPermission.isGranted
                            && self?.isCaptureAllowed(in: sourceApp) == true
                    }
                )
                guard !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration,
                  subtitleTranslationActive,
                  ScreenRecordingPermission.isGranted,
                  isCaptureAllowed(in: sourceApp) else {
                    await subtitleSpeechSession.cancel()
                    return
                }
                startSubtitleSpeechEventConsumption(
                    handle: speechHandle,
                    pipelineGeneration: pipelineSession.generation,
                    sourceApplication: sourceApp,
                    appGeneration: appGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard subtitleSessionGeneration == appGeneration,
                      subtitleTranslationActive else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "无法启动设备端语音字幕。"
                statusMessage = message
                stopSubtitleTranslation()
            }
        }
    }

    private func startSubtitleFrameProduction(
        region: ScreenRegionSelection,
        sourceApplication: NSRunningApplication,
        generation: UInt64,
        appGeneration: UInt64
    ) {
        subtitleCaptureTask?.cancel()
        let previousStream = subtitleCaptureStream
        subtitleCaptureStream = nil
        if let previousStream {
            Task { await previousStream.stop() }
        }
        subtitleSequence = 0
        subtitleCaptureTask = Task { [weak self] in
            guard let self else { return }
            var previousFingerprint: UInt64?
            var nextInterval = LiveSubtitleCadencePolicy.dynamicInterval
            var appliedStreamInterval = nextInterval
            let captureStream: SubtitleCaptureStream
            do {
                captureStream = try await screenRegionOCRService.startSubtitleCaptureStream(
                    region: region,
                    sourceApplication: sourceApplication,
                    authorizationCheck: { [weak self] in
                        self?.subtitleSessionGeneration == appGeneration
                            && self?.subtitleTranslationActive == true
                            && ScreenRecordingPermission.isGranted
                            && self?.isCaptureAllowed(in: sourceApplication) == true
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                guard subtitleSessionGeneration == appGeneration,
                      subtitleTranslationActive else { return }
                let message = error.localizedDescription
                stopSubtitleTranslation()
                subtitleStatus = "已停止：\(message)"
                return
            }
            guard !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration,
                  subtitleTranslationActive,
                  ScreenRecordingPermission.isGranted,
                  isCaptureAllowed(in: sourceApplication) else {
                await captureStream.stop()
                return
            }
            subtitleCaptureStream = captureStream
            while !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration,
                  subtitleTranslationActive,
                  ScreenRecordingPermission.isGranted,
                  isCaptureAllowed(in: sourceApplication) {
                let intervalStart = ContinuousClock.now
                if let pixelBuffer = captureStream.takeLatestPixelBuffer() {
                    guard !Task.isCancelled,
                          subtitleSessionGeneration == appGeneration,
                          subtitleTranslationActive,
                          ScreenRecordingPermission.isGranted,
                          isCaptureAllowed(in: sourceApplication) else { break }
                    subtitleSequence &+= 1
                    let fingerprint = Self.subtitleFrameFingerprint(pixelBuffer)
                    let frame = LiveSubtitleFrame(
                        sequence: subtitleSequence,
                        pixelBuffer: pixelBuffer,
                        hasVisualChange: previousFingerprint != fingerprint
                    )
                    previousFingerprint = fingerprint
                    let submission = await subtitlePipeline.submitFrame(
                        frame,
                        generation: generation
                    )
                    guard submission.accepted else { break }
                    nextInterval = submission.recommendedCaptureInterval
                    if abs(appliedStreamInterval - nextInterval) > 0.001 {
                        do {
                            try await captureStream.updateMinimumFrameInterval(nextInterval)
                            appliedStreamInterval = nextInterval
                        } catch {
                            guard !Task.isCancelled else { break }
                            // Capture can continue at its prior bounded cadence;
                            // a configuration update failure is not permission
                            // to rebuild a broader stream.
                        }
                    }
                } else {
                    if let terminal = captureStream.terminal {
                        if terminal.requiresApplicationShutdown {
                            // `stopSubtitleTranslation` does not await
                            // captureTask, so invoking it here cannot self-wait;
                            // it synchronously flips active to false, takes this
                            // stream for asynchronous stop, and releases the
                            // overlay/pipeline resources.
                            let message = terminal.statusMessage
                            guard subtitleSessionGeneration == appGeneration else { return }
                            stopSubtitleTranslation()
                            subtitleStatus = "已停止：\(message)"
                            return
                        }
                        break
                    }
                    // Wait briefly for the first stream callback without
                    // turning an empty slot into a busy loop.
                    nextInterval = min(nextInterval, 0.05)
                }
                let elapsed = intervalStart.duration(to: ContinuousClock.now)
                let requestedDelay = Duration.milliseconds(Int64(nextInterval * 1_000)) - elapsed
                if requestedDelay > .zero {
                    try? await Task.sleep(for: requestedDelay)
                }
            }
            await captureStream.stop()
            if subtitleCaptureStream === captureStream {
                subtitleCaptureStream = nil
            }
            if subtitleSessionGeneration == appGeneration,
               subtitleTranslationActive,
               (!ScreenRecordingPermission.isGranted
                   || !isCaptureAllowed(in: sourceApplication)) {
                stopSubtitleTranslation()
            }
        }
    }

    private func startSubtitleEventConsumption(
        session: LiveSubtitlePipelineSession,
        sourceApplication: NSRunningApplication,
        appGeneration: UInt64
    ) {
        subtitleEventTask?.cancel()
        subtitleEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in session.events {
                guard !Task.isCancelled,
                      subtitleSessionGeneration == appGeneration,
                      subtitleTranslationActive,
                      ScreenRecordingPermission.isGranted,
                      isCaptureAllowed(in: sourceApplication) else { break }
                switch event {
                case .recognized:
                    if subtitleSourceText.isEmpty {
                        subtitleStatus = "已识别画面，等待字幕稳定…"
                    }
                case .translationStarted(_, _, let text):
                    subtitleSourceText = text
                    subtitleTargetLanguageName = languageRoute(for: text).targetLanguage.displayName
                    subtitleStatus = "正在翻译最新字幕…"
                case .translated(_, _, let sourceText, let output, let cacheHit):
                    subtitleSourceText = sourceText
                    subtitleTranslationText = output.text
                    let sourceName = subtitleRecognitionMode == .systemSpeech
                        ? "设备端语音"
                        : "区域 OCR"
                    subtitleStatus = cacheHit
                        ? "\(output.providerName) · 本机缓存 · \(sourceName)"
                        : "\(output.providerName) · \(sourceName)"
                case .recognitionFailed(_, _, let message),
                     .translationFailed(_, _, let message):
                    subtitleStatus = message
                case .stopped:
                    break
                }
                storedSubtitleOverlayController?.refresh()
            }
        }
    }

    private func startSubtitleSpeechEventConsumption(
        handle: SubtitleSpeechSessionHandle,
        pipelineGeneration: UInt64,
        sourceApplication: NSRunningApplication,
        appGeneration: UInt64
    ) {
        subtitleSpeechEventTask?.cancel()
        subtitleSequence = 0
        subtitleSpeechEventTask = Task { [weak self] in
            guard let self else { return }
            var receivedExpectedTerminalEvent = false
            for await event in handle.events {
                guard !Task.isCancelled,
                      subtitleSessionGeneration == appGeneration,
                      subtitleTranslationActive,
                      ScreenRecordingPermission.isGranted,
                      isCaptureAllowed(in: sourceApplication) else { break }
                switch event {
                case .started(_, let engine):
                    subtitleStatus = engine == .speechAnalyzer
                        ? "Apple SpeechAnalyzer 本机监听中"
                        : "Apple 设备端语音监听中"
                case .partial(_, let text):
                    subtitleSequence &+= 1
                    _ = await subtitlePipeline.submitRecognizedText(
                        text,
                        sequence: subtitleSequence,
                        generation: pipelineGeneration
                    )
                    guard subtitleSessionGeneration == appGeneration else { return }
                case .final(_, let text):
                    subtitleSequence &+= 1
                    _ = await subtitlePipeline.submitRecognizedText(
                        text,
                        sequence: subtitleSequence,
                        generation: pipelineGeneration,
                        isFinal: true
                    )
                    guard subtitleSessionGeneration == appGeneration else { return }
                case .failed(_, let message):
                    // A recognizer failure is terminal for the explicit audio
                    // session. Stop every capture/recognition resource at once
                    // instead of leaving target-App audio flowing until the
                    // user notices the status and presses Stop.
                    guard subtitleSessionGeneration == appGeneration else { return }
                    stopSubtitleTranslation()
                    subtitleStatus = "已停止：\(message)"
                    return
                case .stopped, .cancelled:
                    receivedExpectedTerminalEvent = true
                }
                storedSubtitleOverlayController?.refresh()
            }
            guard !Task.isCancelled,
                  subtitleSessionGeneration == appGeneration,
                  subtitleTranslationActive,
                  (!receivedExpectedTerminalEvent || !isCaptureAllowed(in: sourceApplication)) else {
                return
            }
            stopSubtitleTranslation()
        }
    }

    nonisolated private static func subtitleFrameFingerprint(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
        // A small deterministic sample is sufficient for cadence selection; it
        // is not persisted and never leaves the process.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var fingerprint = UInt64(width) &* 1_099_511_628_211
        fingerprint ^= UInt64(height)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return fingerprint }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let length = max(bytesPerRow * height, 0)
        guard length > 0 else { return fingerprint }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sampleCount = min(64, length)
        for index in 0..<sampleCount {
            let offset = index * max(length / sampleCount, 1)
            fingerprint = (fingerprint ^ UInt64(bytes[min(offset, length - 1)]))
                &* 1_099_511_628_211
        }
        return fingerprint
    }

    func stopSubtitleTranslation(reconcileAfterStop: Bool = true) {
        // Invalidate every authorization closure synchronously before any
        // asynchronous SCStream shutdown work is scheduled.
        subtitleSessionGeneration &+= 1
        subtitleTranslationActive = false
        subtitleTask?.cancel()
        subtitleTask = nil
        subtitleCaptureTask?.cancel()
        subtitleCaptureTask = nil
        let captureStream = subtitleCaptureStream
        subtitleCaptureStream = nil
        if let captureStream {
            Task { await captureStream.stop() }
        }
        subtitleEventTask?.cancel()
        subtitleEventTask = nil
        subtitleSpeechEventTask?.cancel()
        subtitleSpeechEventTask = nil
        let previousSpeechShutdown = subtitleSpeechShutdownTask
        subtitleSpeechShutdownTask = Task { [subtitleSpeechSession] in
            await previousSpeechShutdown?.value
            await subtitleSpeechSession.cancel()
        }
        let previousPipelineShutdown = subtitlePipelineShutdownTask
        subtitlePipelineShutdownTask = Task { [subtitlePipeline] in
            await previousPipelineShutdown?.value
            await subtitlePipeline.stop()
        }
        storedScreenRegionSelectionController?.cancel()
        storedScreenRegionSelectionController = nil
        storedSubtitleOverlayController?.hide()
        storedSubtitleOverlayController?.releaseResources()
        storedSubtitleOverlayController = nil
        subtitleSourceText = ""
        subtitleTranslationText = ""
        Task { await subtitleTranslationCache.removeAll() }
        if subtitleStatus != "未启动" {
            subtitleStatus = "已停止"
        }
        if reconcileAfterStop {
            reconcileRuntime()
        }
    }

    func translateCurrentSelection() {
        guard translatorEnabled else {
            statusMessage = "翻译器已暂停。"
            return
        }
        guard AccessibilityPermission.isTrusted else {
            _ = AccessibilityPermission.requestIfNeeded(prompt: true)
            statusMessage = "请授予辅助功能权限，然后再次使用 ⌃⌥T。"
            return
        }
        guard let sourceApp = NSWorkspace.shared.frontmostApplication,
              !isHelperApp(sourceApp) else {
            showSelectionFailure("请先在浏览器或其他 App 中选中文字。")
            return
        }
        guard isCaptureAllowed(in: sourceApp) else {
            showSelectionFailure(privacyBlockedMessage(for: sourceApp))
            return
        }

        selectionCaptureTask?.cancel()
        selectionTranslationTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration

        selectionPhase = .reading
        selectionSourceText = ""
        selectionTranslationText = ""
        selectionStatus = "正在读取 \(sourceApp.localizedName ?? "当前应用") 的选区…"
        selectionSourceAppName = sourceApp.localizedName ?? "当前应用"
        selectionCanReplace = false
        selectionOverlayController.show(anchorRect: nil)

        selectionCaptureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await selectionReader.capture(
                    from: sourceApp,
                    scanPolicy: .boundedTree,
                    allowClipboardFallback: clipboardCompatibilityEnabled,
                    authorizationCheck: { [weak self] in
                        self?.isCaptureAllowed(in: sourceApp) == true
                    }
                )
                guard !Task.isCancelled, selectionGeneration == generation else {
                    return
                }
                guard let selection else {
                    showSelectionFailure("未检测到选中文字；请保持选区后重试。")
                    return
                }
                present(selection)
                beginTranslation(for: selection, learnsPreference: true)
            } catch is CancellationError {
                return
            } catch {
                guard selectionGeneration == generation else { return }
                showSelectionFailure(error.localizedDescription)
            }
        }
    }

#if DEBUG
    /// Test-only probe enabled by `CPT_DEBUG_SELECTION=1`. It exercises the
    /// same Accessibility reader and overlay without exposing selected text to
    /// another process or adding a production IPC surface.
    func runSelectionDebugProbe(processIdentifier: pid_t) {
        guard SelectionDiagnostics.isEnabled,
              let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await selectionReader.capture(
                    from: app,
                    scanPolicy: .boundedTree,
                    allowClipboardFallback: false,
                    authorizationCheck: { [weak self] in
                        self?.isCaptureAllowed(in: app) == true
                    }
                )
                guard let selection else {
                    SelectionDiagnostics.record("debug probe found no selection")
                    return
                }
                SelectionDiagnostics.record(
                    "debug probe accepted app=\(app.bundleIdentifier ?? "unknown") count=\(selection.text.count)"
                )
                present(selection)
                selectionOverlayController.activateForDebugAutomation()
            } catch {
                SelectionDiagnostics.record("debug probe failed error=\(error.localizedDescription)")
            }
        }
    }
#endif

    func translateDetectedSelection() {
        SelectionDiagnostics.record("overlay translate action received")
        guard let detectedSelection else {
            translateCurrentSelection()
            return
        }
        beginTranslation(for: detectedSelection, learnsPreference: true)
    }

    func copySelectionTranslation() {
        guard !selectionTranslationText.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectionTranslationText, forType: .string)
        selectionStatus = "译文已复制。"
        selectionOverlayController.refresh()
    }

    func replaceSelectionWithTranslation() {
        guard let selection = detectedSelection,
              !selectionTranslationText.isEmpty else {
            return
        }
        guard isCaptureAllowed(in: selection.app) else {
            selectionStatus = privacyBlockedMessage(for: selection.app)
            selectionCanReplace = false
            selectionOverlayController.refresh()
            return
        }
        let replacement = selectionTranslationText
        let generation = selectionGeneration
        selectionStatus = "正在安全替换原选区…"
        selectionOverlayController.refresh()

        selectionReplacementTask?.cancel()
        selectionReplacementTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if selectionGeneration == generation {
                    selectionReplacementTask = nil
                }
            }
            do {
#if DEBUG
                // Computer Use must temporarily activate the debug overlay to
                // reach its controls. Restore the source app first so this
                // test exercises the same nonactivating replacement path used
                // by the production panel.
                if SelectionDiagnostics.isEnabled {
                    selection.app.activate()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
#endif
                guard isCaptureAllowed(in: selection.app),
                      selectionGeneration == generation else {
                    throw CancellationError()
                }
                try await selection.replace(
                    with: replacement,
                    authorizationCheck: { [weak self] in
                        guard let self else { return false }
                        return selectionGeneration == generation
                            && isCaptureAllowed(in: selection.app)
                    }
                )
                guard isCaptureAllowed(in: selection.app),
                      selectionGeneration == generation else {
                    throw CancellationError()
                }
                selectionStatus = "已在 \(selection.appName) 中替换选区。"
                selectionCanReplace = false
                selectionOverlayController.refresh()
            } catch is CancellationError {
                if selectionGeneration == generation {
                    selectionStatus = privacyBlockedMessage(for: selection.app)
                    selectionCanReplace = false
                    selectionOverlayController.refresh()
                }
            } catch {
                selectionStatus = error.localizedDescription
                selectionPhase = .failed
                selectionOverlayController.refresh()
            }
        }
    }

    func dismissSelectionOverlay() {
        selectionCaptureTask?.cancel()
        selectionTranslationTask?.cancel()
        selectionReplacementTask?.cancel()
        hoverCaptureTask?.cancel()
        selectionCaptureTask = nil
        selectionTranslationTask = nil
        selectionReplacementTask = nil
        hoverCaptureTask = nil
        selectionGeneration += 1
        detectedSelection = nil
        selectionPhase = .idle
        storedSelectionOverlayController?.hide()
        scheduleSelectionOverlayRelease()
    }

    var automaticSelectionTranslationPrivacyAcknowledged: Bool {
        UserDefaults.standard.bool(
            forKey: DefaultsKey.automaticSelectionTranslationPrivacyAcknowledged
        )
    }

    func acknowledgeAutomaticSelectionTranslationPrivacy() {
        UserDefaults.standard.set(
            true,
            forKey: DefaultsKey.automaticSelectionTranslationPrivacyAcknowledged
        )
    }

    private func inspectPassiveSelection(
        in app: NSRunningApplication,
        hints: SelectionCaptureHints
    ) {
        guard translatorEnabled,
              selectionDetectionEnabled,
              AccessibilityPermission.isTrusted,
              isCaptureAllowed(in: app) else {
            SelectionDiagnostics.record("passive inspection skipped")
            return
        }

        SelectionDiagnostics.record(
            "passive inspection started app=\(app.bundleIdentifier ?? "unknown")"
        )

        selectionCaptureTask?.cancel()
        selectionCaptureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capturedSelection = try await selectionReader.capture(
                    from: app,
                    scanPolicy: .focusedPath,
                    allowClipboardFallback: false,
                    hints: hints,
                    authorizationCheck: { [weak self] in
                        self?.isCaptureAllowed(in: app) == true
                    }
                )
                guard !Task.isCancelled else { return }
                guard let capturedSelection else {
                    clearRecentResponseSelection(for: app.processIdentifier)
                    SelectionDiagnostics.record("passive inspection found no selection")
                    return
                }
                guard PassiveTextEligibility.normalizedCandidate(
                    capturedSelection.text,
                    maximumCharacters: TranslationLimits.maxInputCharacters
                ) != nil else {
                    SelectionDiagnostics.record("passive selection skipped by quick filter")
                    return
                }
                guard let filtered = contentFilteredSelection(
                    capturedSelection,
                    intent: .passiveSelection
                ) else {
                    SelectionDiagnostics.record("passive selection skipped by content filter")
                    return
                }
                let selection = filtered.selection
                if selection.fingerprint == lastPassiveSelectionFingerprint,
                   storedSelectionOverlayController?.isVisible == true {
                    return
                }
                lastPassiveSelectionFingerprint = selection.fingerprint
                SelectionDiagnostics.record(
                    "passive selection accepted count=\(selection.text.count)"
                )
                selectionTranslationTask?.cancel()
                present(selection)
                selectionFilterNote = filtered.note
                if automaticSelectionTranslationEnabled {
                    beginTranslation(for: selection, learnsPreference: false)
                }
            } catch {
                // Passive detection is deliberately silent. The explicit hotkey
                // surfaces permission and compatibility errors to the user.
            }
        }
    }

    private func inspectHoverText(in app: NSRunningApplication, at point: CGPoint) {
        guard translatorEnabled,
              hoverTranslationEnabled,
              AccessibilityPermission.isTrusted,
              isCaptureAllowed(in: app) else {
            return
        }

        hoverCaptureTask?.cancel()
        hoverCaptureTask = Task { [weak self] in
            guard let self,
                  let capturedSelection = hoverReader.capture(from: app, at: point),
                  !Task.isCancelled else {
                return
            }
            guard let filtered = contentFilteredSelection(capturedSelection, intent: .hover) else {
                return
            }
            let selection = filtered.selection
            let now = Date()
            if selection.fingerprint == lastHoverFingerprint,
               now.timeIntervalSince(lastHoverDate) < 4 {
                return
            }
            lastHoverFingerprint = selection.fingerprint
            lastHoverDate = now
            selectionTranslationTask?.cancel()
            present(selection)
            selectionFilterNote = filtered.note
            beginTranslation(for: selection, learnsPreference: false)
        }
    }

    private func present(_ selection: UniversalTextSelection) {
        selectionFilterNote = ""
        detectedSelection = selection
        updateRecentResponseSelection(from: selection)
        let route = languageRoute(for: selection.text)
        selectionPhase = .detected
        selectionSourceText = selection.text
        selectionTranslationText = ""
        selectionSourceLanguageName = route.sourceDisplayName
        selectionTargetLanguageName = route.targetLanguage.displayName
        selectionSourceAppName = selection.appName
        selectionCanReplace = selection.canReplace
        switch selection.captureMethod {
        case .accessibility:
            selectionStatus = "已通过辅助功能读取选区。"
        case .menuCopyFallback:
            selectionStatus = "已通过应用的“复制”菜单读取选区并恢复原剪贴板。"
        case .clipboardFallback:
            selectionStatus = "已读取选区并恢复原剪贴板。"
        case .hoverAccessibility:
            selectionStatus = "已读取鼠标停留处的可见文字。"
        case .screenOCR:
            selectionStatus = "已在本机识别框选区域。"
        case .subtitleOCR:
            selectionStatus = "已在本机识别字幕区域。"
        }
        selectionOverlayController.show(anchorRect: selection.anchorRect)
    }

    func recentResponseSelection(
        for processIdentifier: pid_t,
        maximumAge: TimeInterval,
        now: Date = Date()
    ) -> RecentResponseSelectionSnapshot? {
        guard let snapshot = recentResponseSelectionSnapshot,
              ResponseSelectionSnapshotPolicy.isFresh(
                snapshotProcessIdentifier: snapshot.processIdentifier,
                targetProcessIdentifier: processIdentifier,
                capturedAt: snapshot.capturedAt,
                now: now,
                maximumAge: maximumAge
              ) else {
            return nil
        }
        return snapshot
    }

    private func updateRecentResponseSelection(from selection: UniversalTextSelection) {
        guard ResponseSelectionSnapshotCapturePolicy.allows(selection.captureMethod),
              isCaptureAllowed(in: selection.app),
              detector.isAIContext(selection.app) else {
            return
        }

        guard let response = AIResponseReader.foreignSelection(from: selection.text) else {
            clearRecentResponseSelection(for: selection.app.processIdentifier)
            return
        }
        let applicationIdentifier = selection.app.bundleIdentifier
            ?? selection.app.localizedName
            ?? "pid-\(selection.app.processIdentifier)"
        recentResponseSelectionSnapshot = RecentResponseSelectionSnapshot(
            response: response.annotated(
                source: .selectedText,
                applicationIdentifier: applicationIdentifier
            ),
            processIdentifier: selection.app.processIdentifier,
            capturedAt: Date()
        )
        guard let snapshot = recentResponseSelectionSnapshot else { return }
        responseSelectionExpiryTask?.cancel()
        responseSelectionExpiryTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(ResponseSelectionSnapshotPolicy.maximumRetention * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  recentResponseSelectionSnapshot?.processIdentifier
                    == snapshot.processIdentifier,
                  recentResponseSelectionSnapshot?.capturedAt == snapshot.capturedAt else {
                return
            }
            recentResponseSelectionSnapshot = nil
            responseSelectionExpiryTask = nil
        }
    }

    private func clearRecentResponseSelection(for processIdentifier: pid_t) {
        guard recentResponseSelectionSnapshot?.processIdentifier == processIdentifier else {
            return
        }
        recentResponseSelectionSnapshot = nil
        responseSelectionExpiryTask?.cancel()
        responseSelectionExpiryTask = nil
    }

    private func beginTranslation(
        for selection: UniversalTextSelection,
        learnsPreference: Bool
    ) {
        selectionTranslationTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        let route = languageRoute(for: selection.text)

        detectedSelection = selection
        selectionPhase = .translating
        selectionTranslationText = ""
        selectionSourceLanguageName = route.sourceDisplayName
        selectionTargetLanguageName = route.targetLanguage.displayName
        selectionStatus = "正在翻译为\(route.targetLanguage.displayName)…\(selectionFilterNote)"
        SelectionDiagnostics.record(
            "translation started target=\(route.targetLanguage.rawValue) count=\(selection.text.count)"
        )
        selectionOverlayController.show(anchorRect: selection.anchorRect)

        selectionTranslationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let automaticKind: TranslationWorkKind = switch selection.captureMethod {
                case .hoverAccessibility:
                    .hover
                default:
                    learnsPreference ? .manual : .automaticSelection
                }
                let output = try await translator.translate(
                    selection.text,
                    to: route.targetLanguage,
                    workKind: automaticKind
                )
                guard !Task.isCancelled,
                      selectionGeneration == generation,
                      detectedSelection?.fingerprint == selection.fingerprint else {
                    return
                }
                selectionTranslationText = output.text
                lastTranslation = output.text
                selectionStatus = "\(output.providerName) · \(route.sourceDisplayName) → \(route.targetLanguage.displayName)\(selectionFilterNote)"
                selectionPhase = .translated
                selectionCanReplace = selection.canReplace
                if learnsPreference {
                    recordSuccessfulUserTranslation(
                        sourceIdentifier: route.sourceIdentifier,
                        targetLanguage: route.targetLanguage,
                        targetWasDeliberatelySelected: !automaticLanguageRoutingEnabled
                    )
                }
                SelectionDiagnostics.record("translation succeeded provider=\(output.providerName)")
                selectionOverlayController.refresh()
            } catch is CancellationError {
                return
            } catch {
                guard selectionGeneration == generation else { return }
                selectionTranslationText = ""
                selectionStatus = "翻译失败：\(error.localizedDescription)"
                selectionPhase = .failed
                SelectionDiagnostics.record("translation failed error=\(error.localizedDescription)")
                selectionOverlayController.refresh()
            }
        }
    }

    private func languageRoute(for text: String) -> SelectionLanguageRoute {
        let sourceIdentifier = SelectionLanguageRouter.detectedLanguageIdentifier(in: text)
        let learnedTarget = translationPreferenceLearningEnabled
            ? TranslationPreferenceLearningPolicy.preferredTarget(
                for: sourceIdentifier,
                profile: translationPreferenceProfile
            )
            : nil
        return SelectionLanguageRouter.route(
            for: text,
            manualTarget: automaticLanguageRoutingEnabled ? learnedTarget : targetLanguage
        )
    }

    private func contentFilteredSelection(
        _ selection: UniversalTextSelection,
        intent: ContentFilterIntent
    ) -> (selection: UniversalTextSelection, note: String)? {
        // Never filter an editable selection: replacing a translated subset
        // could otherwise overwrite more text than the user intended.
        if selection.canReplace {
            return (selection, "")
        }
        guard let result = TranslationContentFilter.filter(
            selection.text,
            level: contentFilterLevel,
            intent: intent,
            appName: selection.appName,
            windowTitle: AppWindowContext.title(for: selection.app)
        ) else {
            return nil
        }
        let projected = result.text == selection.text
            ? selection
            : selection.readOnlyProjection(text: result.text)
        let note = result.removedLineCount > 0
            ? " · \(result.profileIdentifier) 已跳过 \(result.removedLineCount) 行界面信息"
            : ""
        SelectionDiagnostics.record(
            "content filter profile=\(result.profileIdentifier) removed=\(result.removedLineCount)"
        )
        return (projected, note)
    }

    private func showSelectionFailure(_ message: String) {
        selectionPhase = .failed
        selectionTranslationText = ""
        selectionStatus = message
        selectionSourceLanguageName = "选区"
        selectionTargetLanguageName = "翻译"
        selectionCanReplace = false
        selectionOverlayController.show(anchorRect: nil)
        statusMessage = message
    }

    func translateCurrentInputInline(target preferredTarget: InputTarget? = nil) {
        guard translatorEnabled else {
            statusMessage = "无感翻译已暂停，请从菜单栏重新开启。"
            return
        }

        guard !isTranslating else {
            return
        }

        guard AccessibilityPermission.isTrusted else {
            _ = AccessibilityPermission.requestIfNeeded(prompt: true)
            statusMessage = "请授予辅助功能权限，然后再次点击“翻译输入”。"
            return
        }

        guard let target = preferredTarget ?? currentInputTarget() else {
            statusMessage = "请先点进 Claude 或 ChatGPT 的消息输入框，再点击“翻译输入”。"
            return
        }
        guard isCaptureAllowed(in: target.app) else {
            statusMessage = privacyBlockedMessage(for: target.app)
            return
        }

        rememberTarget(target)
        isTranslating = true
        statusMessage = "正在读取 \(target.appName) 输入草稿…"

        inputTranslationGeneration &+= 1
        let generation = inputTranslationGeneration
        inputTranslationTask?.cancel()
        inputTranslationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if inputTranslationGeneration == generation {
                    inputTranslationTask = nil
                    isTranslating = false
                }
            }
            do {
                guard isCaptureAllowed(in: target.app) else {
                    throw CancellationError()
                }
                guard let source = await deliveryService.readCurrentInput(
                    from: target,
                    allowClipboardFallback: clipboardCompatibilityEnabled,
                    authorizationCheck: { [weak self] in
                        self?.isCaptureAllowed(in: target.app) == true
                    }
                ) else {
                    throw DeliveryError.emptyInput
                }
                let targetChoice = userInputTargetChoice(for: source.text)
                let translationTarget = targetChoice.language
                if targetChoice.learned, targetLanguage != translationTarget {
                    targetLanguage = translationTarget
                }
                guard InputTarget.isTranslatableInputText(source.text, to: translationTarget) else {
                    throw DeliveryError.nonTranslatableInput
                }

                let segmentCount = TranslationChunker.chunks(for: source.text)
                    .filter(\.shouldTranslate)
                    .count
                if segmentCount > 1 {
                    statusMessage = "正在按顺序翻译长文本（\(segmentCount) 段）…"
                } else {
                    statusMessage = source.usesSelection
                        ? "正在把选中文字翻译为\(translationTarget.displayName)…"
                        : (targetChoice.learned
                            ? "已按两周本机习惯选择\(translationTarget.displayName)，正在翻译…"
                            : "正在翻译为\(translationTarget.displayName)…")
                }
                let output = try await translator.translate(source.text, to: translationTarget)
                try Task.checkCancellation()
                guard TranslationOperationSafety.canContinue(
                    expectedGeneration: generation,
                    currentGeneration: inputTranslationGeneration,
                    translatorEnabled: translatorEnabled
                ), isCaptureAllowed(in: target.app) else {
                    throw CancellationError()
                }
                lastTranslation = output.text
                statusMessage = source.usesSelection
                    ? "正在安全替换 \(target.appName) 中的选中文字…"
                    : "正在用译文替换 \(target.appName) 输入草稿…"
                try await deliveryService.replaceCurrentInput(
                    with: output.text,
                    in: target,
                    scope: source.replacementScope,
                    allowClipboardFallback: clipboardCompatibilityEnabled,
                    authorizationCheck: { [weak self] in
                        self?.isCaptureAllowed(in: target.app) == true
                    }
                )
                try Task.checkCancellation()
                guard TranslationOperationSafety.canContinue(
                    expectedGeneration: generation,
                    currentGeneration: inputTranslationGeneration,
                    translatorEnabled: translatorEnabled
                ), isCaptureAllowed(in: target.app) else {
                    throw CancellationError()
                }
                recordSuccessfulUserTranslation(
                    sourceText: source.text,
                    targetLanguage: translationTarget,
                    targetWasDeliberatelySelected: !targetChoice.learned
                )
                statusMessage = source.usesSelection
                    ? "已翻译 \(target.appName) 中的选中文字。"
                    : "译文已写入 \(target.appName) 草稿；检查后请自行决定是否发送。"
            } catch is CancellationError {
                if inputTranslationGeneration == generation, translatorEnabled {
                    statusMessage = "输入草稿翻译已取消。"
                }
            } catch {
                guard inputTranslationGeneration == generation else { return }
                statusMessage = "输入草稿翻译失败：\(error.localizedDescription)"
            }
        }
    }

    func copyLastTranslation() {
        guard !lastTranslation.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranslation, forType: .string)
        statusMessage = "上次译文已复制。"
    }

    func beginResponseTranslation(source: String, language: DetectedResponseLanguage) {
        responseSourceText = source
        responseSourceLanguageName = language.displayName
        responseTranslationStatus = "正在把\(language.displayName)回复翻译为中文…"
        isResponseTranslating = true
        refreshPanelLayout(animated: false)
    }

    func completeResponseTranslation(source: String, language: DetectedResponseLanguage, translation: String) {
        responseSourceText = source
        responseSourceLanguageName = language.displayName
        responseTranslationText = translation
        responseTranslationStatus = "已翻译\(language.displayName)回复。"
        isResponseTranslating = false
        refreshPanelLayout(animated: false)
    }

    func failResponseTranslation(_ error: Error) {
        responseTranslationStatus = "回复翻译失败：\(error.localizedDescription)"
        isResponseTranslating = false
        refreshPanelLayout(animated: false)
    }

    func clearResponseTranslation() {
        storedUnifiedBarController?.clearResponseTranslation()
        responseSourceText = ""
        responseSourceLanguageName = ""
        responseTranslationText = ""
        responseTranslationStatus = ""
        isResponseTranslating = false
        refreshPanelLayout(animated: false)
    }

    func copyResponseTranslation() {
        guard !responseTranslationText.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(responseTranslationText, forType: .string)
        responseTranslationStatus = "中文译文已复制。"
    }

    var responseTranslationPrivacyAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.responseTranslationPrivacyAcknowledged)
    }

    func acknowledgeResponseTranslationPrivacy() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.responseTranslationPrivacyAcknowledged)
    }

    var clipboardCompatibilityPrivacyAcknowledged: Bool {
        UserDefaults.standard.bool(
            forKey: DefaultsKey.clipboardCompatibilityPrivacyAcknowledged
        )
    }

    func acknowledgeClipboardCompatibilityPrivacy() {
        UserDefaults.standard.set(
            true,
            forKey: DefaultsKey.clipboardCompatibilityPrivacyAcknowledged
        )
    }

    private func refreshPanelLayout(animated: Bool) {
        guard let panelController = storedPanelController, panelController.isVisible else {
            return
        }
        panelController.applyPresentation(animated: animated)
    }

    private func scheduleSelectionOverlayRelease() {
        guard let controller = storedSelectionOverlayController else { return }
        selectionOverlayReleaseTask?.cancel()
        selectionOverlayReleaseTask = Task { @MainActor [weak self, weak controller] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self,
                  self.storedSelectionOverlayController === controller,
                  controller?.isVisible != true else { return }
            controller?.releaseResources()
            self.storedSelectionOverlayController = nil
            self.selectionOverlayReleaseTask = nil
        }
    }

    private func currentInputTarget() -> InputTarget? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isCaptureAllowed(in: frontmost), detector.isAIContext(frontmost) {
            if let target = InputTarget.captureTextTarget(from: frontmost) {
                return target
            }

        }

        // Only fall back to lastInputTarget when the last target was an AI app
        if let lastInputTarget, !lastInputTarget.app.isTerminated,
           lastInputTarget.hasConcreteTextInput,
           isCaptureAllowed(in: lastInputTarget.app),
           detector.isAIContext(lastInputTarget.app) {
            return lastInputTarget
        }

        return nil
    }
}

private enum DefaultsKey {
    static let translatorEnabled = "translatorEnabled"
    static let targetLanguage = "targetLanguage"
    static let autoShow = "autoShowWhenClaudeIsActive"
    static let floatingTrigger = "floatingTriggerEnabled"
    static let responseTranslationEnabled = "responseTranslationEnabled"
    static let responseTranslationPrivacyAcknowledged = "responseTranslationPrivacyAcknowledged"
    static let clipboardCompatibilityEnabled = "clipboardCompatibilityEnabled"
    static let clipboardCompatibilityPrivacyAcknowledged = "clipboardCompatibilityPrivacyAcknowledged"
    static let selectionDetectionEnabled = "selectionDetectionEnabled"
    static let automaticSelectionTranslationEnabled = "automaticSelectionTranslationEnabled"
    static let automaticSelectionTranslationPrivacyAcknowledged = "automaticSelectionTranslationPrivacyAcknowledged"
    static let hoverTranslationEnabled = "hoverTranslationEnabled"
    static let subtitleDisplayMode = "subtitleDisplayMode"
    static let subtitleRecognitionMode = "subtitleRecognitionMode"
    static let subtitleSpeechLocale = "subtitleSpeechLocale"
    static let subtitleOverlayStyle = "subtitleOverlayStyle"
    static let subtitleFontSize = "subtitleFontSize"
    static let selectionDisplayMode = "selectionDisplayMode"
    static let automaticLanguageRoutingEnabled = "automaticLanguageRoutingEnabled"
    static let translationPreferenceLearningEnabled = "translationPreferenceLearningEnabled"
    static let unifiedBarEnabled = "unifiedBarEnabled"
    static let appTheme = "appTheme"
    static let inlineModeMigration = "inlineModeMigration"
    static let inlineInputPillMigration = "inlineInputPillMigration"
    static let blockedApplicationBundleIdentifiers = "blockedApplicationBundleIdentifiers"
    static let contentFilterLevel = "contentFilterLevel"
}
