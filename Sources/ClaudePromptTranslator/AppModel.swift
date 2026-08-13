import AppKit
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
            if selectionDetectionEnabled, translatorEnabled {
                selectionMonitor.start()
            } else {
                selectionMonitor.stop()
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
            if hoverTranslationEnabled, translatorEnabled {
                hoverMonitor.start()
            } else {
                hoverMonitor.stop()
            }
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
            panelController.applyAppearance()
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
            selectionOverlayController.refresh()
        }
    }
    @Published var subtitleTranslationActive = false
    @Published var subtitleSourceText = ""
    @Published var subtitleTranslationText = ""
    @Published var subtitleStatus = "未启动"
    @Published var subtitleTargetLanguageName = "自动"
    @Published var subtitleDisplayMode: SubtitleDisplayMode = .bilingual {
        didSet {
            UserDefaults.standard.set(subtitleDisplayMode.rawValue, forKey: DefaultsKey.subtitleDisplayMode)
            subtitleOverlayController.refresh()
        }
    }
    @Published var subtitleOverlayStyle: SubtitleOverlayStyle = .dark {
        didSet {
            UserDefaults.standard.set(subtitleOverlayStyle.rawValue, forKey: DefaultsKey.subtitleOverlayStyle)
            subtitleOverlayController.refresh()
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
            subtitleOverlayController.refresh()
        }
    }

    let detector = ClaudeContextDetector()

    lazy var unifiedBarController = UnifiedEdgeBarController(model: self)
    lazy var selectionOverlayController = SelectionOverlayController(model: self)
    lazy var subtitleOverlayController = SubtitleOverlayController(model: self)

    private let translator = AutomaticTranslationClient()
    private let deliveryService = TextDeliveryService()
    private let selectionReader = UniversalSelectionReader()
    private let hoverReader = HoverTextReader()
    private let screenRegionOCRService = ScreenRegionOCRService()
    private let subtitleTranslationCache = SubtitleTranslationCache()
    private lazy var panelController = PromptPanelController(model: self)
    private lazy var selectionMonitor = UniversalSelectionMonitor(
        isApplicationAllowed: { [weak self] app in
            self?.isCaptureAllowed(in: app) == true
        },
        handler: { [weak self] app, hints in
            self?.inspectPassiveSelection(in: app, hints: hints)
        }
    )
    private lazy var hoverMonitor = HoverTranslationMonitor { [weak self] app, point in
        self?.inspectHoverText(in: app, at: point)
    }
    private lazy var screenRegionSelectionController = ScreenRegionSelectionController()
    private var lastInputTarget: InputTarget?
    private var detectedSelection: UniversalTextSelection?
    private var selectionCaptureTask: Task<Void, Never>?
    private var selectionTranslationTask: Task<Void, Never>?
    private var selectionReplacementTask: Task<Void, Never>?
    private var hoverCaptureTask: Task<Void, Never>?
    private var screenOCRTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var inputTranslationTask: Task<Void, Never>?
    private var inputTranslationGeneration: UInt64 = 0
    private var selectionGeneration = 0
    private var lastPassiveSelectionFingerprint = ""
    private var recentResponseSelectionSnapshot: RecentResponseSelectionSnapshot?
    private var responseSelectionExpiryTask: Task<Void, Never>?
    private var lastHoverFingerprint = ""
    private var lastHoverDate = Date.distantPast
    private var selectionFilterNote = ""
    private var translationPreferenceProfile = TranslationPreferenceProfile()

    init() {
        let savedTarget = UserDefaults.standard.string(forKey: DefaultsKey.targetLanguage)
            .flatMap(TargetLanguage.init(rawValue:)) ?? .english
        self.targetLanguage = savedTarget

        let savedTheme = UserDefaults.standard.string(forKey: DefaultsKey.appTheme)
            .flatMap(AppTheme.init(rawValue:)) ?? .system
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

    func setTranslatorEnabled(_ enabled: Bool) {
        guard translatorEnabled != enabled else {
            return
        }

        translatorEnabled = enabled
        if enabled {
            statusMessage = "跨应用选区翻译已开启。"
            startSelectionMonitoring()
            if unifiedBarEnabled {
                unifiedBarController.start()
            }
        } else {
            statusMessage = "翻译器已暂停。"
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
            unifiedBarController.stop()
            clearResponseTranslation()
            hidePanel()
        }
    }

    func revealEdgeBar() {
        guard translatorEnabled else {
            statusMessage = "无感翻译已暂停，请从菜单栏重新开启。"
            return
        }
        let wasEnabled = unifiedBarEnabled
        unifiedBarEnabled = true
        statusMessage = "AI 兼容边缘栏已就绪。"
        if !wasEnabled || !unifiedBarController.isRunning {
            unifiedBarController.start()
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

        guard !panelController.isVisible else {
            return
        }

        if hasResponseTranslationActivity {
            panelPresentation = .compact
        }
        panelController.showPassive()
    }

    func hidePanel() {
        panelController.hide()
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
        panelController.isVisible
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
        selectionMonitor.refreshPrivacyPolicy()
        inputTranslationGeneration &+= 1
        inputTranslationTask?.cancel()
        inputTranslationTask = nil
        selectionCaptureTask?.cancel()
        selectionTranslationTask?.cancel()
        selectionReplacementTask?.cancel()
        hoverCaptureTask?.cancel()
        screenOCRTask?.cancel()
        screenOCRTask = nil
        screenRegionSelectionController.cancel()
        if lastInputTarget?.app.processIdentifier == app.processIdentifier {
            lastInputTarget = nil
            targetAppName = ""
        }
        purgeSensitiveTranslationState(for: blockedProcessIdentifier)
        stopSubtitleTranslation()
        Task { await subtitleTranslationCache.removeAll() }
        clearRecentResponseSelection(for: blockedProcessIdentifier)
        unifiedBarController.refresh()
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
            selectionMonitor.refreshPrivacyPolicy()
            unifiedBarController.refresh()
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
        guard translatorEnabled else {
            selectionMonitor.stop()
            hoverMonitor.stop()
            return
        }
        if selectionDetectionEnabled {
            selectionMonitor.start()
        } else {
            selectionMonitor.stop()
        }
        if hoverTranslationEnabled {
            hoverMonitor.start()
        } else {
            hoverMonitor.stop()
        }
    }

    func stopSelectionMonitoring() {
        selectionMonitor.stop()
        hoverMonitor.stop()
        selectionCaptureTask?.cancel()
        selectionTranslationTask?.cancel()
        selectionReplacementTask?.cancel()
        hoverCaptureTask?.cancel()
        screenOCRTask?.cancel()
        subtitleTask?.cancel()
        screenRegionSelectionController.cancel()
        selectionCaptureTask = nil
        selectionTranslationTask = nil
        selectionReplacementTask = nil
        hoverCaptureTask = nil
        screenOCRTask = nil
        subtitleTask = nil
        subtitleTranslationActive = false
        responseSelectionExpiryTask?.cancel()
        responseSelectionExpiryTask = nil
        recentResponseSelectionSnapshot = nil
        subtitleOverlayController.hide()
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
        subtitleStatus = "请框选视频中的字幕区域"
        let suggestedRegion = ScreenRegionSelection.frontmostWindow(of: sourceApp)
        subtitleTask = Task { [weak self] in
            guard let self else { return }
            guard let region = await screenRegionSelectionController.selectRegion(
                suggestedRegion: suggestedRegion
            ),
                  !Task.isCancelled else {
                subtitleStatus = "已取消"
                return
            }
            guard isCaptureAllowed(in: sourceApp) else {
                subtitleStatus = privacyBlockedMessage(for: sourceApp)
                return
            }

            sourceApp.activate()
            subtitleTranslationActive = true
            subtitleSourceText = ""
            subtitleTranslationText = ""
            subtitleStatus = "本机 OCR 监听中"
            subtitleOverlayController.show(region: region)

            var cueProcessor = SubtitleCueProcessor()
            while !Task.isCancelled,
                  subtitleTranslationActive,
                  isCaptureAllowed(in: sourceApp) {
                do {
                    guard isCaptureAllowed(in: sourceApp) else { break }
                    let result = try await screenRegionOCRService.recognize(
                        region: region,
                        sourceApplication: sourceApp,
                        authorizationCheck: { [weak self] in
                            self?.isCaptureAllowed(in: sourceApp) == true
                        }
                    )
                    guard !Task.isCancelled, isCaptureAllowed(in: sourceApp) else { break }
                    if let cue = cueProcessor.observe(result.text) {
                        subtitleSourceText = cue
                        let route = languageRoute(for: cue)
                        subtitleTargetLanguageName = route.targetLanguage.displayName
                        subtitleStatus = "正在翻译…"
                        subtitleOverlayController.refresh()

                        let output: TranslationProviderOutput
                        if let cached = await subtitleTranslationCache.value(
                            for: cue,
                            target: route.targetLanguage
                        ) {
                            output = cached
                        } else {
                            output = try await translator.translate(cue, to: route.targetLanguage)
                            await subtitleTranslationCache.insert(
                                output,
                                for: cue,
                                target: route.targetLanguage
                            )
                        }
                        guard !Task.isCancelled,
                              subtitleTranslationActive,
                              isCaptureAllowed(in: sourceApp) else { break }
                        subtitleTranslationText = output.text
                        subtitleStatus = "\(output.providerName) · 区域 OCR"
                        subtitleOverlayController.refresh()
                    }
                } catch is CancellationError {
                    break
                } catch ScreenTextOCRError.noTextRecognized {
                    subtitleStatus = subtitleSourceText.isEmpty ? "等待字幕出现…" : "等待下一条字幕…"
                    subtitleOverlayController.refresh()
                } catch {
                    subtitleStatus = error.localizedDescription
                    subtitleOverlayController.refresh()
                }
                try? await Task.sleep(nanoseconds: 480_000_000)
            }
        }
    }

    func stopSubtitleTranslation() {
        subtitleTask?.cancel()
        subtitleTask = nil
        subtitleTranslationActive = false
        screenRegionSelectionController.cancel()
        subtitleOverlayController.hide()
        subtitleSourceText = ""
        subtitleTranslationText = ""
        Task { await subtitleTranslationCache.removeAll() }
        if subtitleStatus != "未启动" {
            subtitleStatus = "已停止"
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
        selectionOverlayController.hide()
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
                   selectionOverlayController.isVisible {
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
                let output = try await translator.translate(
                    selection.text,
                    to: route.targetLanguage
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
        unifiedBarController.clearResponseTranslation()
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
        guard panelController.isVisible else {
            return
        }
        panelController.applyPresentation(animated: animated)
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
