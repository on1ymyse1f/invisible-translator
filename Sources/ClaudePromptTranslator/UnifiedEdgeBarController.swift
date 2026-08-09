import AppKit
import ApplicationServices
import CryptoKit
import QuartzCore

enum ResponseCaptureTrigger {
    case automatic
    case manualAccessibilityRead
    case explicitOCRRetry
}

enum ResponseCapturePrivacyPolicy {
    static func allowsOCR(
        trigger: ResponseCaptureTrigger,
        screenRecordingPermissionGranted: Bool
    ) -> Bool {
        switch trigger {
        case .automatic, .manualAccessibilityRead:
            return false
        case .explicitOCRRetry:
            return screenRecordingPermissionGranted
        }
    }

    /// Reply capture must remain Accessibility-only. Clipboard compatibility is
    /// reserved for explicit input/selection workflows that have their own
    /// privacy acknowledgement and must never be inherited by “译回复”.
    static func allowsClipboard(trigger: ResponseCaptureTrigger) -> Bool {
        false
    }
}

enum ResponseTranslationFreshness {
    static func shouldInvalidate(
        translatingSource: String,
        incomingSource: String?
    ) -> Bool {
        !translatingSource.isEmpty && translatingSource != incomingSource
    }
}

enum ResponseTranslationIdentity {
    static func value(for response: DetectedForeignResponse) -> String {
        let normalizedText = response.text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let identityMaterial = [
            response.turnIdentifier ?? "no-turn",
            response.captureSource.rawValue,
            normalizedText
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identityMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum ManualResponsePresentationPolicy {
    static let retention: TimeInterval = 12

    static func suppressesAutomaticScan(until: Date, now: Date = Date()) -> Bool {
        now < until
    }
}

// MARK: - UnifiedEdgeBarController

/// Single controller replacing FloatingTriggerController, OutputTranslateButtonController,
/// and ResponseTranslationController. Manages a liquid-glass bar attached to the right
/// outside edge of AI application windows.
@MainActor
final class UnifiedEdgeBarController: NSObject {
    fileprivate let model: AppModel
    private let translator = AutomaticTranslationClient()

    // MARK: - Panels

    private lazy var barPanel = makeBarPanel()
    private var barContentView: UnifiedBarContentView?
    private let responseScanner = AIResponseScanWorker()

    // MARK: - State (fileprivate so UnifiedBarContentView can read)

    private var timer: Timer?
    private var currentApp: NSRunningApplication?

    var responseTargetApplication: NSRunningApplication? {
        guard let currentApp,
              !currentApp.isTerminated,
              model.isCaptureAllowed(in: currentApp),
              model.detector.isAIContext(currentApp) else {
            return nil
        }
        return currentApp
    }

    private var currentWindowRect: NSRect?
    private var currentWindowIdentity: InputWindowIdentity?
    private var currentInputTarget: InputTarget?
    private var inputAccessibilityObserver: InputAccessibilityObserver?
    private var lastBarFrame: NSRect?
    private var lastWindowRect: NSRect?
    private var lastWindowGeometryChangeAt = Date.distantPast
    private var renderedTheme: AppTheme?
    private var lastObservedAIProcessIdentifier: pid_t?
    private var isBarVisible = false
    private var forceVisibleUntil: Date?
    private var keepExpandedUntil: Date?
    private var lastInputScan = Date.distantPast
    private var lastFullInputTargetScan = Date.distantPast
    private var cachedHasTranslatableInput = false
    private var cachedCanAttemptInputTranslation = false
    private var cachedInputIsInferred = false
    private var cachedUsesSelectedInput = false
    fileprivate var isExpanded = false
    fileprivate var isTranslatingInput = false
    fileprivate var isTranslatingResponse: Bool {
        get { model.isResponseTranslating }
        set { model.isResponseTranslating = newValue }
    }
    fileprivate var inputStatusOverride = ""
    fileprivate var inputStatusOverrideExpiresAt: Date?

    // Response translation state
    private var responseScanTask: Task<Void, Never>?
    private var manualResponseTask: Task<Void, Never>?
    private var autoResponseTranslationTask: Task<Void, Never>?
    private var inputTranslationTask: Task<Void, Never>?
    private var pendingResponse: DetectedForeignResponse?
    private var pendingSince: Date?
    private var lastTranslatedResponseIdentity = ""
    private var translatingResponseIdentity = ""
    private var responseTranslationGeneration: UInt64 = 0
    private var responseTranslationCache = ResponseTranslationCache(capacity: 32)
    fileprivate var manualOCRRetryAvailable = false
    private let selectedResponseSnapshotLifetime = ResponseSelectionSnapshotPolicy.maximumRetention
    fileprivate var latestResponseSource: String {
        get { model.responseSourceText }
        set { model.responseSourceText = newValue }
    }
    fileprivate var latestResponseTranslation: String {
        get { model.responseTranslationText }
        set { model.responseTranslationText = newValue }
    }
    fileprivate var latestResponseLanguageName: String {
        get { model.responseSourceLanguageName }
        set { model.responseSourceLanguageName = newValue }
    }
    fileprivate var responseStatus: String {
        get { model.responseTranslationStatus }
        set { model.responseTranslationStatus = newValue }
    }
    private var lastAutoScan = Date.distantPast
    private var manualResponsePresentationUntil = Date.distantPast
    private let inputScanInterval: TimeInterval = 0.35
    private let autoScanInterval: TimeInterval = 2.0
    private let stableDelay: TimeInterval = 1.0
    private let dragSettleDelay: TimeInterval = 0.9

    // MARK: - Dimensions

    private static let collapsedSize = NSSize(width: 320, height: 82)
    private static let expandedSize = NSSize(width: 340, height: 440)
    private static let edgeMargin: CGFloat = 8

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    var isRunning: Bool {
        timer != nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inputAccessibilityObserver?.stop()
        inputAccessibilityObserver = nil
        forceVisibleUntil = nil
        keepExpandedUntil = nil
        resetResponseContext(clearDisplayedContent: true)
        inputTranslationTask?.cancel()
        inputTranslationTask = nil
        isTranslatingInput = false
        cachedHasTranslatableInput = false
        cachedCanAttemptInputTranslation = false
        cachedInputIsInferred = false
        cachedUsesSelectedInput = false
        hideBar()
    }

    func clearResponseTranslation() {
        resetResponseContext(clearDisplayedContent: true)
        barContentView?.updateState()
    }

    private func resetResponseContext(clearDisplayedContent: Bool) {
        responseScanTask?.cancel()
        responseScanTask = nil
        manualResponseTask?.cancel()
        manualResponseTask = nil
        autoResponseTranslationTask?.cancel()
        autoResponseTranslationTask = nil
        responseTranslationGeneration &+= 1
        pendingResponse = nil
        pendingSince = nil
        translatingResponseIdentity = ""
        manualOCRRetryAvailable = false
        manualResponsePresentationUntil = .distantPast
        isTranslatingResponse = false

        if clearDisplayedContent {
            responseTranslationCache.removeAll()
            latestResponseSource = ""
            latestResponseTranslation = ""
            latestResponseLanguageName = ""
            responseStatus = ""
            lastTranslatedResponseIdentity = ""
        }
    }

    func revealTemporarily(duration: TimeInterval = 8.0) {
        if timer == nil {
            start()
        }
        forceVisibleUntil = Date().addingTimeInterval(duration)
        refresh()
    }

    // MARK: - Main Refresh

    func refresh() {
        guard model.translatorEnabled else {
            hideBar()
            return
        }

        applyThemeIfNeeded()

        guard AccessibilityPermission.isTrusted else {
            hideBar()
            return
        }

        guard let app = candidateAIApplication() else {
            if currentApp != nil {
                resetResponseContext(clearDisplayedContent: true)
                inputTranslationTask?.cancel()
                inputTranslationTask = nil
                isTranslatingInput = false
            }
            currentApp = nil
            currentWindowRect = nil
            currentWindowIdentity = nil
            currentInputTarget = nil
            inputAccessibilityObserver?.stop()
            inputAccessibilityObserver = nil
            lastObservedAIProcessIdentifier = nil
            lastWindowRect = nil
            cachedHasTranslatableInput = false
            cachedCanAttemptInputTranslation = false
            cachedInputIsInferred = false
            cachedUsesSelectedInput = false
            hideBar()
            return
        }

        let applicationChanged = currentApp?.processIdentifier != app.processIdentifier
        let observedWindowIdentity = InputTarget.currentWindowIdentity(for: app)
        let windowChanged = !applicationChanged
            && currentWindowIdentity != nil
            && observedWindowIdentity != nil
            && currentWindowIdentity != observedWindowIdentity
        currentApp = app
        if applicationChanged {
            installInputAccessibilityObserver(for: app)
            currentWindowIdentity = observedWindowIdentity
        } else if let observedWindowIdentity {
            currentWindowIdentity = observedWindowIdentity
        }
        if applicationChanged || windowChanged {
            resetResponseContext(clearDisplayedContent: true)
            inputTranslationTask?.cancel()
            inputTranslationTask = nil
            isTranslatingInput = false
            currentInputTarget = nil
            cachedHasTranslatableInput = false
            cachedCanAttemptInputTranslation = false
            cachedInputIsInferred = false
            cachedUsesSelectedInput = false
            lastInputScan = .distantPast
            lastFullInputTargetScan = .distantPast
            pendingResponse = nil
            pendingSince = nil
        }

        guard let windowRect = windowRect(in: app),
              windowRect.width > 320, windowRect.height > 260 else {
            resetResponseContext(clearDisplayedContent: true)
            inputTranslationTask?.cancel()
            inputTranslationTask = nil
            isTranslatingInput = false
            currentWindowRect = nil
            currentWindowIdentity = nil
            currentInputTarget = nil
            lastObservedAIProcessIdentifier = nil
            lastWindowRect = nil
            cachedHasTranslatableInput = false
            cachedCanAttemptInputTranslation = false
            cachedInputIsInferred = false
            cachedUsesSelectedInput = false
            hideBar()
            return
        }

        currentWindowRect = windowRect
        let windowIsMoving = updateWindowMotion(with: windowRect)
        if model.autoShowWhenClaudeIsActive,
           lastObservedAIProcessIdentifier != app.processIdentifier {
            lastObservedAIProcessIdentifier = app.processIdentifier
            forceVisibleUntil = Date().addingTimeInterval(8.0)
        }

        refreshInputState(in: app, windowIsMoving: windowIsMoving)
        scheduleResponseScan(in: app, windowIsMoving: windowIsMoving)

        let now = Date()
        if isMouseOverBar {
            forceVisibleUntil = now.addingTimeInterval(1.4)
            if isExpanded {
                keepExpandedUntil = now.addingTimeInterval(1.4)
            }
        }
        let isForcedVisible = forceVisibleUntil.map { now < $0 } ?? false
        if forceVisibleUntil != nil, !isForcedVisible {
            forceVisibleUntil = nil
        }
        let isExpansionHeld = keepExpandedUntil.map { now < $0 } ?? false
        if keepExpandedUntil != nil, !isExpansionHeld {
            keepExpandedUntil = nil
        }

        let shouldShow = isForcedVisible || EdgeOverlayGeometry.isMouseNearWindowEdge(
            windowRect: windowRect,
            activeFrames: isBarVisible ? [barPanel.frame] : [],
            edgeThickness: 90
        ) || isTranslatingInput || isTranslatingResponse || isExpansionHeld

        if shouldShow {
            let targetExpanded = isTranslatingInput || isTranslatingResponse || isExpansionHeld
            if targetExpanded != isExpanded {
                isExpanded = targetExpanded
                rebuildContentView()
            }
            barContentView?.updateState()
            showBar(at: windowRect, windowIsMoving: windowIsMoving)
        } else if !isTranslatingInput, !isTranslatingResponse {
            if isExpanded {
                isExpanded = false
                rebuildContentView()
            }
            hideBar()
        }
    }

    // MARK: - Input State

    private func refreshInputState(in app: NSRunningApplication, windowIsMoving: Bool) {
        guard !windowIsMoving,
              Date().timeIntervalSince(lastInputScan) >= inputScanInterval else {
            return
        }
        lastInputScan = Date()

        let isAIContext = model.detector.isAIContext(app)
        if let focusedTarget = InputTarget.captureFocusedTextTarget(from: app) {
            currentInputTarget = focusedTarget
            updateCachedInputState(from: focusedTarget)
            return
        }

        if let target = currentInputTarget,
           target.app.processIdentifier == app.processIdentifier,
           target.matchesCurrentWindow,
           target.hasConcreteTextInput,
           Date().timeIntervalSince(lastFullInputTargetScan) < 5 {
            updateCachedInputState(from: target)
            return
        }

        lastFullInputTargetScan = Date()
        if let target = InputTarget.captureTextTarget(from: app) {
            self.currentInputTarget = target
            updateCachedInputState(from: target)
        } else if isAIContext,
                  let target = InputTarget.capture(from: app, inferAIInputArea: true) {
            self.currentInputTarget = target
            self.cachedHasTranslatableInput = false
            self.cachedUsesSelectedInput = false
            self.cachedCanAttemptInputTranslation = false
            self.cachedInputIsInferred = !target.hasConcreteTextInput
        } else {
            self.currentInputTarget = nil
            self.cachedHasTranslatableInput = false
            self.cachedCanAttemptInputTranslation = false
            self.cachedUsesSelectedInput = false
            self.cachedInputIsInferred = false
        }
    }

    private func updateCachedInputState(from target: InputTarget) {
        let source = target.currentTranslationSource()
        cachedHasTranslatableInput = source
            .map { InputTarget.isTranslatableInputText($0.text, to: model.targetLanguage) } ?? false
        cachedUsesSelectedInput = source?.usesSelection ?? false
        cachedCanAttemptInputTranslation = true
        cachedInputIsInferred = false
    }

    private func installInputAccessibilityObserver(for app: NSRunningApplication) {
        if inputAccessibilityObserver?.processIdentifier == app.processIdentifier {
            return
        }

        inputAccessibilityObserver?.stop()
        inputAccessibilityObserver = InputAccessibilityObserver(
            processIdentifier: app.processIdentifier
        ) { [weak self] in
            guard let self else { return }
            lastInputScan = .distantPast
            lastFullInputTargetScan = .distantPast
            refresh()
        }
    }

    private func candidateAIApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            if model.isCaptureAllowed(in: frontmost) {
                return model.detector.isAIContext(frontmost) ? frontmost : nil
            }
        }

        if let currentApp,
           !currentApp.isTerminated,
           model.isCaptureAllowed(in: currentApp),
           model.detector.isAIContext(currentApp),
           EdgeOverlayGeometry.mainWindowRect(for: currentApp) != nil {
            return currentApp
        }

        // Do not guess a background AI application by window size. When the
        // helper owns focus, currentApp is the only context explicitly carried
        // over from the user's foreground window.
        return nil
    }

    fileprivate var hasTranslatableInput: Bool {
        cachedHasTranslatableInput
    }

    fileprivate var canAttemptInputTranslation: Bool {
        cachedCanAttemptInputTranslation && currentInputTarget != nil
    }

    fileprivate var usesSelectedInput: Bool {
        cachedUsesSelectedInput
    }

    fileprivate var inputTargetIsInferred: Bool {
        cachedInputIsInferred
    }

    fileprivate var currentAIAppName: String {
        currentApp?.localizedName ?? "AI"
    }

    var isManualResponseOCRRetryAvailable: Bool {
        manualOCRRetryAvailable
    }

    // MARK: - Response State

    private func scheduleResponseScan(in app: NSRunningApplication, windowIsMoving: Bool) {
        guard model.responseTranslationEnabled, model.isCaptureAllowed(in: app) else {
            responseScanTask?.cancel()
            responseScanTask = nil
            pendingResponse = nil
            pendingSince = nil

            // Disabling automatic scanning must not cancel a user-initiated
            // manual translation. Manual “译回复” is intentionally available
            // while the privacy-sensitive background feature remains off.
            if autoResponseTranslationTask != nil {
                responseTranslationGeneration &+= 1
                autoResponseTranslationTask?.cancel()
                autoResponseTranslationTask = nil
                translatingResponseIdentity = ""
                isTranslatingResponse = false
            }
            return
        }
        guard !windowIsMoving,
              !ManualResponsePresentationPolicy.suppressesAutomaticScan(
                  until: manualResponsePresentationUntil
              ),
              Date().timeIntervalSince(lastWindowGeometryChangeAt) >= dragSettleDelay,
              responseScanTask == nil else {
            return
        }
        guard Date().timeIntervalSince(lastAutoScan) >= autoScanInterval else { return }
        lastAutoScan = Date()

        let processIdentifier = app.processIdentifier
        // Automatic reply detection is Accessibility-only. OCR can capture the
        // visible chat window, so it is reserved for an explicit button click.
        let shouldAllowOCR = ResponseCapturePrivacyPolicy.allowsOCR(
            trigger: .automatic,
            screenRecordingPermissionGranted: false
        )

        responseScanTask = Task { [weak self] in
            guard let self else { return }
            let response = await self.responseScanner.latestForeignResponse(
                processIdentifier: processIdentifier,
                allowOCR: shouldAllowOCR
            )
            guard !Task.isCancelled,
                  currentApp?.processIdentifier == processIdentifier,
                  model.isCaptureAllowed(in: app) else { return }
            self.responseScanTask = nil
            self.applyScannedResponse(response, processIdentifier: processIdentifier)
        }
    }

    private func applyScannedResponse(_ response: DetectedForeignResponse?, processIdentifier: pid_t) {
        guard currentApp?.processIdentifier == processIdentifier,
              let app = currentApp,
              model.isCaptureAllowed(in: app) else {
            return
        }

        invalidateAutomaticResponseTranslationIfSourceChanged(
            to: response.map(ResponseTranslationIdentity.value)
        )

        guard let response else {
            pendingResponse = nil
            pendingSince = nil
            if !isTranslatingResponse, latestResponseTranslation.isEmpty {
                responseStatus = ""
                latestResponseSource = ""
                latestResponseLanguageName = ""
            }
            return
        }

        if response == pendingResponse {
            guard let pendingSince,
                  Date().timeIntervalSince(pendingSince) >= stableDelay else {
                responseStatus = "已检测到 \(response.language.displayName) 回复，等待输出稳定…"
                return
            }
        } else {
            let sourceTextChanged = pendingResponse.map(ResponseTranslationIdentity.value)
                != ResponseTranslationIdentity.value(for: response)
            pendingResponse = response
            pendingSince = Date()
            latestResponseSource = response.text
            latestResponseLanguageName = response.language.displayName
            if sourceTextChanged {
                latestResponseTranslation = ""
            }
            if !isTranslatingResponse {
                responseStatus = "\(response.captureSource.displayName) · 等待回复完成…"
                barContentView?.updateState()
            }
            return
        }

        let responseIdentity = ResponseTranslationIdentity.value(for: response)
        guard responseIdentity != lastTranslatedResponseIdentity,
              responseIdentity != translatingResponseIdentity else { return }

        autoTranslate(response, processIdentifier: processIdentifier)
    }

    private func invalidateAutomaticResponseTranslationIfSourceChanged(to incomingSource: String?) {
        guard ResponseTranslationFreshness.shouldInvalidate(
            translatingSource: translatingResponseIdentity,
            incomingSource: incomingSource
        ) else {
            return
        }

        responseTranslationGeneration &+= 1
        autoResponseTranslationTask?.cancel()
        autoResponseTranslationTask = nil
        translatingResponseIdentity = ""
        if manualResponseTask == nil {
            isTranslatingResponse = false
        }
    }

    private func autoTranslate(_ response: DetectedForeignResponse, processIdentifier: pid_t) {
        guard currentApp?.processIdentifier == processIdentifier,
              let app = currentApp,
              model.isCaptureAllowed(in: app) else {
            return
        }
        let responseIdentity = ResponseTranslationIdentity.value(for: response)
        if let cachedTranslation = responseTranslationCache.translation(for: response) {
            lastTranslatedResponseIdentity = responseIdentity
            latestResponseSource = response.text
            latestResponseTranslation = cachedTranslation
            latestResponseLanguageName = response.language.displayName
            responseStatus = "\(response.captureSource.displayName) · 缓存 · \(response.language.displayName) → 中文"
            holdExpanded(for: 14)
            barContentView?.updateState()
            return
        }

        responseTranslationGeneration &+= 1
        let generation = responseTranslationGeneration
        translatingResponseIdentity = responseIdentity
        latestResponseSource = response.text
        latestResponseTranslation = ""
        latestResponseLanguageName = response.language.displayName
        responseStatus = "Translating \(response.language.displayName)..."
        isTranslatingResponse = true
        holdExpanded(for: 4)
        isExpanded = true
        rebuildContentView()

        autoResponseTranslationTask?.cancel()
        autoResponseTranslationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == responseTranslationGeneration {
                    autoResponseTranslationTask = nil
                }
            }
            do {
                let output = try await translator.translateToChinese(response.text)
                guard generation == responseTranslationGeneration,
                      translatingResponseIdentity == responseIdentity,
                      currentApp?.processIdentifier == processIdentifier,
                      let app = currentApp,
                      model.isCaptureAllowed(in: app) else { return }
                translatingResponseIdentity = ""
                lastTranslatedResponseIdentity = responseIdentity
                responseTranslationCache.insert(output.text, for: response)
                latestResponseTranslation = output.text
                responseStatus = "\(response.captureSource.displayName) · \(output.providerName) · \(response.language.displayName) → 中文"
                isTranslatingResponse = false
                holdExpanded(for: 18)
                barContentView?.updateState()
            } catch {
                guard generation == responseTranslationGeneration,
                      translatingResponseIdentity == responseIdentity,
                      currentApp?.processIdentifier == processIdentifier else { return }
                translatingResponseIdentity = ""
                latestResponseTranslation = ""
                responseStatus = "Auto-translate failed: \(error.localizedDescription)"
                isTranslatingResponse = false
                holdExpanded(for: 8)
                barContentView?.updateState()
            }
        }
    }

    // MARK: - Input Translation

    @objc func translateInput() {
        guard !isTranslatingInput else { return }
        let freshlyCapturedTarget = currentApp.flatMap({
            InputTarget.captureTextTarget(from: $0)
        })
        guard let target = freshlyCapturedTarget ?? currentInputTarget,
              target.hasConcreteTextInput else {
            model.statusMessage = "Focus the Claude or ChatGPT input field, then try again."
            inputStatusOverride = "请先点进 AI 输入框"
            inputStatusOverrideExpiresAt = Date().addingTimeInterval(5)
            barContentView?.updateState()
            return
        }

        model.rememberTarget(target)
        inputStatusOverride = ""
        inputStatusOverrideExpiresAt = nil
        isTranslatingInput = true
        barContentView?.updateState()
        let processIdentifier = target.app.processIdentifier

        inputTranslationTask?.cancel()
        inputTranslationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if currentApp?.processIdentifier == processIdentifier {
                    inputTranslationTask = nil
                }
            }
            do {
                guard let source = await TextDeliveryService().readCurrentInput(
                    from: target,
                    allowClipboardFallback: model.clipboardCompatibilityEnabled,
                    authorizationCheck: { [weak self] in
                        guard let self else { return false }
                        return model.isCaptureAllowed(in: target.app)
                            && currentApp?.processIdentifier == processIdentifier
                    }
                ) else {
                    throw DeliveryError.emptyInput
                }
                guard InputTarget.isTranslatableInputText(source.text, to: model.targetLanguage) else {
                    throw DeliveryError.nonTranslatableInput
                }

                let segmentCount = TranslationChunker.chunks(for: source.text)
                    .filter(\.shouldTranslate)
                    .count
                if segmentCount > 1 {
                    inputStatusOverride = "长文本分段翻译中（\(segmentCount) 段）"
                    inputStatusOverrideExpiresAt = nil
                    barContentView?.updateState()
                }

                let output = try await translator.translate(source.text, to: model.targetLanguage)
                try Task.checkCancellation()
                guard currentApp?.processIdentifier == processIdentifier else {
                    throw CancellationError()
                }
                model.lastTranslation = output.text
                try await TextDeliveryService().replaceCurrentInput(
                    with: output.text,
                    in: target,
                    scope: source.replacementScope,
                    allowClipboardFallback: model.clipboardCompatibilityEnabled,
                    authorizationCheck: { [weak self] in
                        guard let self else { return false }
                        return model.isCaptureAllowed(in: target.app)
                            && currentApp?.processIdentifier == processIdentifier
                    }
                )
                isTranslatingInput = false
                model.statusMessage = source.usesSelection
                    ? "Selected text translated."
                    : "Translated. Review, then press Enter."
                inputStatusOverride = source.usesSelection
                    ? "已翻译选中文字"
                    : "已替换为\(model.targetLanguage.shortChineseName)"
                inputStatusOverrideExpiresAt = Date().addingTimeInterval(4)
                holdExpanded(for: 4)
                barContentView?.updateState()
            } catch is CancellationError {
                guard currentApp?.processIdentifier == processIdentifier else { return }
                isTranslatingInput = false
                inputStatusOverride = "已取消输入翻译"
                inputStatusOverrideExpiresAt = Date().addingTimeInterval(3)
                barContentView?.updateState()
            } catch {
                guard currentApp?.processIdentifier == processIdentifier else { return }
                isTranslatingInput = false
                model.statusMessage = "Translation failed: \(error.localizedDescription)"
                inputStatusOverride = inputTranslationErrorMessage(for: error)
                inputStatusOverrideExpiresAt = Date().addingTimeInterval(5)
                forceVisibleUntil = Date().addingTimeInterval(5)
                barContentView?.updateState()
            }
        }
    }

    private func inputTranslationErrorMessage(for error: Error) -> String {
        if let translationError = error as? TranslationError,
           case .inputTooLong(let limit) = translationError {
            return "文本超过 \(limit) 字符，请分段处理"
        }

        if let deliveryError = error as? DeliveryError {
            switch deliveryError {
            case .accessibilityPermissionRequired:
                return "需要开启辅助功能权限"
            case .targetInputUnavailable:
                return "请先点进 AI 输入框"
            case .emptyInput:
                return "未读到输入内容"
            case .nonTranslatableInput:
                return "请输入中文或日文"
            case .inputChanged:
                return "输入已变化，未执行替换"
            case .inputWriteVerificationFailed:
                return "输入框写入校验失败，请重新聚焦后再试"
            case .targetAppChanged:
                return "目标应用已切换，未执行替换"
            case .clipboardCompatibilityDisabled:
                return "此输入框需手动开启剪贴板兼容模式"
            case .privacyBlocked:
                return "App 隐私名单已取消本次操作"
            }
        }
        return "翻译失败，请稍后重试"
    }

    // MARK: - Response Translation (Manual)

    @objc func translateLatestResponse() {
        SelectionDiagnostics.record("manual response translation requested")
        if isTranslatingResponse {
            cancelResponseTranslation()
            return
        }
        guard let app = currentApp else {
            responseStatus = "未找到当前 AI 窗口"
            barContentView?.updateState()
            return
        }
        guard model.isCaptureAllowed(in: app) else {
            responseStatus = "隐私名单已禁止读取此应用"
            barContentView?.updateState()
            return
        }

        responseScanTask?.cancel()
        responseScanTask = nil
        responseTranslationGeneration &+= 1
        let generation = responseTranslationGeneration
        let processIdentifier = app.processIdentifier
        let monitoredSelectionAtAction = model.recentResponseSelection(
            for: processIdentifier,
            maximumAge: selectedResponseSnapshotLifetime
        )
        let shouldAttemptOCR = manualOCRRetryAvailable
        manualOCRRetryAvailable = false
        isTranslatingResponse = true
        latestResponseTranslation = ""
        responseStatus = shouldAttemptOCR
            ? "正在重试辅助功能读取，必要时使用 OCR…"
            : "正在读取选中文字…"
        holdExpanded(for: 5)
        isExpanded = true
        rebuildContentView()

        manualResponseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == responseTranslationGeneration {
                    isTranslatingResponse = false
                    manualResponseTask = nil
                    barContentView?.updateState()
                }
            }

            // A fresh worker prevents a slow automatic OCR scan from blocking a
            // user-triggered read on the shared scan actor.
            let manualScanner = AIResponseScanWorker()
            // Read the live selection directly through Accessibility. Do not
            // press the target app's Copy menu and do not snapshot, read, or
            // write the system pasteboard from the reply workflow.
            let directlySelectedResponse = await manualScanner.selectedForeignResponse(
                processIdentifier: processIdentifier
            )
            guard !Task.isCancelled,
                  generation == responseTranslationGeneration,
                  model.isCaptureAllowed(in: app),
                  currentApp?.processIdentifier == processIdentifier else { return }

            if directlySelectedResponse == nil,
               monitoredSelectionAtAction == nil {
                // The passive selection monitor is intentionally debounced so
                // web views can publish their final text-marker range. Give it
                // one short turn before falling back to the latest reply.
                try? await Task.sleep(nanoseconds: 240_000_000)
            }
            guard !Task.isCancelled,
                  generation == responseTranslationGeneration,
                  model.isCaptureAllowed(in: app),
                  currentApp?.processIdentifier == processIdentifier else { return }
            let monitoredSelectionAfterRead = model.recentResponseSelection(
                for: processIdentifier,
                maximumAge: selectedResponseSnapshotLifetime
            )
            let selectedResponse = directlySelectedResponse
                ?? monitoredSelectionAfterRead?.response
                ?? monitoredSelectionAtAction?.response
            let usedSelection = selectedResponse != nil
            if usedSelection {
                manualResponsePresentationUntil = Date().addingTimeInterval(
                    ManualResponsePresentationPolicy.retention
                )
            }
            let response: DetectedForeignResponse?
            if let selectedResponse {
                response = selectedResponse
            } else {
                responseStatus = "正在通过辅助功能读取最新回复…"
                barContentView?.updateState()
                let accessibilityResponse = await manualScanner.latestForeignResponse(
                    processIdentifier: processIdentifier,
                    allowOCR: false
                )
                guard !Task.isCancelled,
                      generation == responseTranslationGeneration,
                      model.isCaptureAllowed(in: app) else { return }
                if let accessibilityResponse {
                    response = accessibilityResponse
                } else if !shouldAttemptOCR {
                    latestResponseSource = ""
                    latestResponseTranslation = ""
                    latestResponseLanguageName = ""
                    manualOCRRetryAvailable = true
                    responseStatus = "辅助功能未读到回复；如需截屏识别，请再次点击“使用 OCR 重试”"
                    holdExpanded(for: 14)
                    barContentView?.updateState()
                    return
                } else {
                    let screenRecordingGranted = ScreenRecordingPermission.requestIfNeeded()
                    guard ResponseCapturePrivacyPolicy.allowsOCR(
                        trigger: .explicitOCRRetry,
                        screenRecordingPermissionGranted: screenRecordingGranted
                    ) else {
                        latestResponseSource = ""
                        latestResponseTranslation = ""
                        latestResponseLanguageName = ""
                        manualOCRRetryAvailable = true
                        responseStatus = "OCR 需要屏幕录制权限；允许后再次点击“使用 OCR 重试”"
                        holdExpanded(for: 10)
                        barContentView?.updateState()
                        return
                    }
                    responseStatus = "未读到回复正文，正在进行 OCR…"
                    barContentView?.updateState()
                    guard model.isCaptureAllowed(in: app) else { return }
                    response = await manualScanner.latestForeignResponse(
                        processIdentifier: processIdentifier,
                        allowOCR: true
                    )
                }
            }
            guard !Task.isCancelled,
                  generation == responseTranslationGeneration,
                  model.isCaptureAllowed(in: app),
                  currentApp?.processIdentifier == processIdentifier else { return }
            guard let response else {
                latestResponseSource = ""
                latestResponseTranslation = ""
                latestResponseLanguageName = ""
                manualOCRRetryAvailable = shouldAttemptOCR
                responseStatus = shouldAttemptOCR
                    ? "OCR 未识别到可翻译回复；可重新选中文字后再试"
                    : "未找到可翻译的选中文字或最新回复"
                holdExpanded(for: 7)
                barContentView?.updateState()
                return
            }

            do {
                latestResponseSource = response.text
                latestResponseLanguageName = response.language.displayName
                if let cachedTranslation = responseTranslationCache.translation(for: response) {
                    latestResponseTranslation = cachedTranslation
                    lastTranslatedResponseIdentity = ResponseTranslationIdentity.value(for: response)
                    responseStatus = usedSelection
                        ? "选中文字 · 缓存 · \(response.language.displayName) → 中文"
                        : "缓存 · \(response.language.displayName) → 中文"
                    holdExpanded(for: 18)
                    barContentView?.updateState()
                    return
                }

                responseStatus = "正在把 \(response.language.displayName) 翻译为中文…"
                barContentView?.updateState()
                let output = try await translator.translateToChinese(response.text)
                guard generation == responseTranslationGeneration,
                      model.isCaptureAllowed(in: app),
                      currentApp?.processIdentifier == processIdentifier else { return }
                latestResponseTranslation = output.text
                lastTranslatedResponseIdentity = ResponseTranslationIdentity.value(for: response)
                responseTranslationCache.insert(output.text, for: response)
                responseStatus = usedSelection
                    ? "选中文字 · \(output.providerName) · \(response.language.displayName) → 中文"
                    : "\(response.captureSource.displayName) · \(output.providerName) · \(response.language.displayName) → 中文"
                holdExpanded(for: 20)
                barContentView?.updateState()
            } catch {
                guard generation == responseTranslationGeneration else { return }
                latestResponseTranslation = ""
                responseStatus = "回复翻译失败：\(error.localizedDescription)"
                holdExpanded(for: 8)
                barContentView?.updateState()
            }
        }
    }

    private func cancelResponseTranslation() {
        responseTranslationGeneration &+= 1
        manualResponseTask?.cancel()
        manualResponseTask = nil
        autoResponseTranslationTask?.cancel()
        autoResponseTranslationTask = nil
        translatingResponseIdentity = ""
        isTranslatingResponse = false
        manualOCRRetryAvailable = false
        responseStatus = "已取消回复读取"
        holdExpanded(for: 5)
        barContentView?.updateState()
    }

    @objc func copyResponseTranslation() {
        guard !latestResponseTranslation.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestResponseTranslation, forType: .string)
        responseStatus = "回复译文已复制。"
        barContentView?.updateState()
    }

    @objc func switchToEnglish() {
        model.targetLanguage = .english
        barContentView?.updateState()
    }

    @objc func switchToSimplifiedChinese() {
        model.targetLanguage = .simplifiedChinese
        barContentView?.updateState()
    }

    @objc func switchToJapanese() {
        model.targetLanguage = .japanese
        barContentView?.updateState()
    }

    // MARK: - Expand / Collapse

    private var isMouseOverBar: Bool {
        let mouse = NSEvent.mouseLocation
        return barPanel.frame.insetBy(dx: -12, dy: -12).contains(mouse)
    }

    // MARK: - Bar Visibility & Positioning

    private func showBar(at windowRect: NSRect, windowIsMoving: Bool) {
        let size = isExpanded ? Self.expandedSize : Self.collapsedSize
        let origin = barOrigin(for: size, windowRect: windowRect)
        let frame = NSRect(origin: origin, size: size).roundedForOverlayPlacement()

        if !isBarVisible {
            barPanel.setFrame(frame, display: false)
            barPanel.alphaValue = 0
            barPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                barPanel.animator().alphaValue = 1
            }
            isBarVisible = true
            lastBarFrame = frame
        } else if lastBarFrame?.distance(to: frame) ?? .greatestFiniteMagnitude > 2 {
            lastBarFrame = frame
            barPanel.setFrame(frame, display: !windowIsMoving)
        }
    }

    private func hideBar() {
        guard isBarVisible else { return }
        isBarVisible = false
        lastBarFrame = nil
        barPanel.orderOut(nil)
    }

    private func barOrigin(for size: NSSize, windowRect: NSRect) -> NSPoint {
        let visibleFrame = EdgeOverlayGeometry.visibleFrame(around: windowRect)
        let margin = Self.edgeMargin
        let preferredY = windowRect.minY + windowRect.height * 0.42

        let rightSpace = visibleFrame.maxX - windowRect.maxX - margin
        let leftSpace = windowRect.minX - visibleFrame.minX - margin

        let x: CGFloat
        if rightSpace >= size.width + 4 {
            x = windowRect.maxX + margin
        } else if leftSpace >= size.width + 4 {
            x = windowRect.minX - size.width - margin
        } else {
            x = windowRect.maxX - size.width - margin - 4
        }

        let y = min(
            max(preferredY - size.height / 2, visibleFrame.minY + 16),
            visibleFrame.maxY - size.height - 16
        )
        return NSPoint(x: x, y: y)
    }

    // MARK: - Content View Management

    private func rebuildContentView() {
        let size = isExpanded ? Self.expandedSize : Self.collapsedSize
        let frame = NSRect(origin: .zero, size: size)
        let content = UnifiedBarContentView(frame: frame, controller: self, model: model)
        content.autoresizingMask = [.width, .height]
        barPanel.contentView = content
        barContentView = content
        barContentView?.updateState()
    }

    private func applyThemeIfNeeded() {
        guard renderedTheme != model.appTheme else { return }
        renderedTheme = model.appTheme
        barPanel.appearance = model.appTheme.nsAppearance
        rebuildContentView()
    }

    private func holdExpanded(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        if keepExpandedUntil.map({ $0 < deadline }) ?? true {
            keepExpandedUntil = deadline
        }
        if forceVisibleUntil.map({ $0 < deadline }) ?? true {
            forceVisibleUntil = deadline
        }
    }

    // MARK: - Panel Construction

    private func makeBarPanel() -> NSPanel {
        let panel = UnifiedEdgeBarPanel(
            contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = UnifiedBarContentView(
            frame: NSRect(origin: .zero, size: Self.collapsedSize),
            controller: self, model: model
        )
        barContentView = panel.contentView as? UnifiedBarContentView
        return panel
    }

    // MARK: - Window Rect Helpers

    private func windowRect(in app: NSRunningApplication) -> NSRect? {
        if AccessibilityPermission.isTrusted,
           let root = rootElement(for: app),
           let rect = rect(for: root),
           rect.width > 320, rect.height > 260 {
            return rect
        }

        return EdgeOverlayGeometry.mainWindowRect(for: app)
    }

    private func updateWindowMotion(with windowRect: NSRect) -> Bool {
        defer {
            lastWindowRect = windowRect
        }

        guard let lastWindowRect else {
            return false
        }

        let changed = lastWindowRect.distance(to: windowRect) > 4
        if changed {
            lastWindowGeometryChangeAt = Date()
            return true
        }

        return Date().timeIntervalSince(lastWindowGeometryChangeAt) < dragSettleDelay
            || NSEvent.pressedMouseButtons != 0
    }

    private func rootElement(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let w = elementAttribute(kAXFocusedWindowAttribute, from: appElement) { return w }
        if let w = elementAttribute(kAXMainWindowAttribute, from: appElement) { return w }
        return nil
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &reference)
        guard result == .success, let reference,
              CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
        return (reference as! AXUIElement)
    }

    private func rect(for element: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        let posVal = posRef as! AXValue
        let sizeVal = sizeRef as! AXValue
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &pos)
        AXValueGetValue(sizeVal, .cgSize, &size)
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? pos.y + size.height
        return NSRect(x: pos.x, y: maxY - pos.y - size.height, width: size.width, height: size.height)
    }

}

// MARK: - Accessibility Focus Observer

/// Invalidates the cheap input cache as soon as the target application changes
/// its focused field or focused window. The periodic timer remains as a safety
/// net for applications that do not publish every AX notification.
@MainActor
private final class InputAccessibilityObserver {
    let processIdentifier: pid_t

    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private let onChange: @MainActor () -> Void

    init?(
        processIdentifier: pid_t,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.processIdentifier = processIdentifier
        self.onChange = onChange

        var createdObserver: AXObserver?
        guard AXObserverCreate(
            processIdentifier,
            inputAccessibilityObserverCallback,
            &createdObserver
        ) == .success,
              let createdObserver else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        self.observer = createdObserver
        self.applicationElement = applicationElement

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let notifications = [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification
        ]
        for notification in notifications {
            _ = AXObserverAddNotification(
                createdObserver,
                applicationElement,
                notification as CFString,
                context
            )
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )
    }

    func stop() {
        guard let observer else { return }

        if let applicationElement {
            for notification in [
                kAXFocusedUIElementChangedNotification,
                kAXFocusedWindowChangedNotification,
                kAXWindowCreatedNotification
            ] {
                _ = AXObserverRemoveNotification(
                    observer,
                    applicationElement,
                    notification as CFString
                )
            }
        }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        self.observer = nil
        applicationElement = nil
    }

    fileprivate func accessibilityContextChanged() {
        onChange()
    }
}

private let inputAccessibilityObserverCallback: AXObserverCallback = {
    _, _, _, context in
    guard let context else { return }
    let observer = Unmanaged<InputAccessibilityObserver>
        .fromOpaque(context)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        observer.accessibilityContextChanged()
    }
}

// MARK: - UnifiedEdgeBarPanel

final class UnifiedEdgeBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSRect {
    func distance(to other: NSRect) -> CGFloat {
        abs(minX - other.minX)
            + abs(minY - other.minY)
            + abs(width - other.width)
            + abs(height - other.height)
    }

    func roundedForOverlayPlacement() -> NSRect {
        NSRect(
            x: minX.rounded(),
            y: minY.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }
}

// MARK: - UnifiedBarContentView

/// The visual content of the unified edge bar — a layered liquid-glass view
/// with two sections: input translation (top) and response translation (bottom).
final class UnifiedBarContentView: NSView {
    private unowned let controller: UnifiedEdgeBarController
    private unowned let model: AppModel
    private var isExpanded: Bool

    // Subviews
    private var outerGlass: NSVisualEffectView!
    private var innerCard: NSVisualEffectView!
    private var headerLabel: NSTextField!
    private var inputStatusLabel: NSTextField!
    private var translateInputButton: NSButton!
    private var langZhButton: NSButton!
    private var langEnButton: NSButton!
    private var langJaButton: NSButton!

    // Response translation controls (the primary action also remains visible while collapsed)
    private var dividerView: NSBox?
    private var responseHeaderLabel: NSTextField?
    private var responseStatusLabel: NSTextField?
    private var responseScrollView: NSScrollView?
    private var responseTextView: NSTextView?
    private var translateResponseButton: NSButton?
    private var copyResponseButton: NSButton?

    private var palette: EdgeBarPalette {
        EdgeBarPalette(theme: model.appTheme)
    }

    init(frame: NSRect, controller: UnifiedEdgeBarController, model: AppModel) {
        self.controller = controller
        self.model = model
        self.isExpanded = frame.height > 200
        super.init(frame: frame)
        wantsLayer = true
        buildUI()
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Build UI

    private func buildUI() {
        // Remove old subviews
        subviews.forEach { $0.removeFromSuperview() }

        let pad: CGFloat = isExpanded ? 14 : 12

        // Outer glass — denser material for the "liquid glass" look
        outerGlass = NSVisualEffectView(frame: bounds)
        outerGlass.autoresizingMask = [.width, .height]
        outerGlass.material = palette.outerMaterial
        outerGlass.blendingMode = .behindWindow
        outerGlass.state = .active
        outerGlass.wantsLayer = true
        outerGlass.layer?.cornerRadius = 20
        outerGlass.layer?.masksToBounds = true
        outerGlass.layer?.borderWidth = 1
        outerGlass.layer?.borderColor = palette.border.cgColor
        addSubview(outerGlass)

        // Inner card — lighter material for text readability
        innerCard = NSVisualEffectView(frame: bounds.insetBy(dx: 6, dy: 6))
        innerCard.autoresizingMask = [.width, .height]
        innerCard.material = .sidebar
        innerCard.blendingMode = .withinWindow
        innerCard.state = .active
        innerCard.wantsLayer = true
        innerCard.layer?.cornerRadius = 16
        innerCard.layer?.masksToBounds = true
        innerCard.layer?.backgroundColor = palette.surfaceTint.cgColor
        outerGlass.addSubview(innerCard)

        let cardWidth = innerCard.bounds.width
        let cardHeight = innerCard.bounds.height
        let contentWidth = cardWidth - pad * 2
        let collapsedResponseWidth: CGFloat = 86
        let collapsedInputWidth: CGFloat = 86
        let collapsedButtonGap: CGFloat = 6
        let collapsedResponseX = cardWidth - pad - collapsedResponseWidth
        let collapsedInputX = collapsedResponseX - collapsedButtonGap - collapsedInputWidth

        // Header
        headerLabel = NSTextField(labelWithString: "无感翻译 · AI 兼容")
        headerLabel.frame = NSRect(
            x: pad,
            y: cardHeight - 24,
            width: contentWidth - 94,
            height: 18
        )
        headerLabel.font = .systemFont(ofSize: isExpanded ? 12 : 11.5, weight: .semibold)
        headerLabel.textColor = palette.secondaryText
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setAccessibilityIdentifier("cpt.edge.header")
        innerCard.addSubview(headerLabel)

        // Language switcher pills
        langZhButton = makePillButton(
            title: "中",
            x: cardWidth - pad - 104,
            y: cardHeight - 24,
            width: 32,
            action: #selector(controller.switchToSimplifiedChinese)
        )
        langEnButton = makePillButton(
            title: "EN",
            x: cardWidth - pad - 68,
            y: cardHeight - 24,
            width: 32,
            action: #selector(controller.switchToEnglish)
        )
        langJaButton = makePillButton(
            title: "JP",
            x: cardWidth - pad - 32,
            y: cardHeight - 24,
            width: 32,
            action: #selector(controller.switchToJapanese)
        )
        innerCard.addSubview(langZhButton)
        innerCard.addSubview(langEnButton)
        innerCard.addSubview(langJaButton)
        langZhButton.setAccessibilityLabel("目标语言：简体中文")
        langEnButton.setAccessibilityLabel("目标语言：英语")
        langJaButton.setAccessibilityLabel("目标语言：日语")
        langZhButton.toolTip = "把 AI 输入草稿翻译为简体中文"
        langEnButton.toolTip = "把 AI 输入草稿翻译为英语"
        langJaButton.toolTip = "把 AI 输入草稿翻译为日语"

        // Input status
        inputStatusLabel = NSTextField(labelWithString: "")
        inputStatusLabel.frame = isExpanded
            ? NSRect(x: pad, y: cardHeight - 48, width: contentWidth, height: 16)
            : NSRect(x: pad, y: 13, width: collapsedInputX - pad - 6, height: 22)
        inputStatusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        inputStatusLabel.textColor = palette.subtleText
        inputStatusLabel.lineBreakMode = .byTruncatingTail
        inputStatusLabel.setAccessibilityIdentifier("cpt.edge.input-status")
        innerCard.addSubview(inputStatusLabel)

        // Translate input button
        translateInputButton = NSButton(title: "翻译输入", target: controller, action: #selector(controller.translateInput))
        translateInputButton.frame = isExpanded
            ? NSRect(x: pad, y: cardHeight - 72, width: contentWidth, height: 28)
            : NSRect(x: collapsedInputX, y: 9, width: collapsedInputWidth, height: 28)
        translateInputButton.bezelStyle = .rounded
        translateInputButton.font = .systemFont(ofSize: 12, weight: .medium)
        translateInputButton.controlSize = .small
        translateInputButton.bezelColor = palette.accent
        translateInputButton.contentTintColor = .white
        translateInputButton.isEnabled = false
        translateInputButton.toolTip = "只翻译并替换 AI 输入草稿，不会发送消息"
        translateInputButton.setAccessibilityLabel("翻译 AI 输入草稿，不会发送")
        translateInputButton.setAccessibilityIdentifier("cpt.edge.translate-input")
        innerCard.addSubview(translateInputButton)

        if isExpanded {
            buildExpandedSection(pad: pad, contentWidth: contentWidth, contentHeight: cardHeight)
        } else {
            let responseButton = NSButton(
                title: "译回复",
                target: controller,
                action: #selector(controller.translateLatestResponse)
            )
            responseButton.frame = NSRect(
                x: collapsedResponseX,
                y: 9,
                width: collapsedResponseWidth,
                height: 28
            )
            responseButton.bezelStyle = .rounded
            responseButton.font = .systemFont(ofSize: 11.5, weight: .medium)
            responseButton.controlSize = .small
            responseButton.bezelColor = palette.accent
            responseButton.contentTintColor = .white
            responseButton.toolTip = "优先翻译选中的回复，否则读取最新回复；第一次不会启用 OCR"
            responseButton.setAccessibilityLabel("翻译已选或最新 AI 回复")
            responseButton.setAccessibilityIdentifier("cpt.edge.translate-response")
            innerCard.addSubview(responseButton)
            translateResponseButton = responseButton
        }

        // Clean up non-expanded subviews
        dividerView = isExpanded ? dividerView : nil
        responseHeaderLabel = isExpanded ? responseHeaderLabel : nil
        responseStatusLabel = isExpanded ? responseStatusLabel : nil
        responseScrollView = isExpanded ? responseScrollView : nil
        responseTextView = isExpanded ? responseTextView : nil
        copyResponseButton = isExpanded ? copyResponseButton : nil
    }

    private func buildExpandedSection(pad: CGFloat, contentWidth: CGFloat, contentHeight: CGFloat) {
        // Divider
        let div = NSBox(frame: NSRect(x: pad, y: contentHeight - 84, width: contentWidth, height: 1))
        div.boxType = .separator
        innerCard.addSubview(div)
        dividerView = div

        // Response header
        let respHeader = NSTextField(labelWithString: "回复翻译 · 选区优先")
        respHeader.frame = NSRect(x: pad, y: contentHeight - 104, width: contentWidth, height: 16)
        respHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        respHeader.textColor = palette.primaryText
        innerCard.addSubview(respHeader)
        responseHeaderLabel = respHeader

        // Response status
        let respStatus = NSTextField(labelWithString: "等待 AI 输出...")
        respStatus.frame = NSRect(x: pad, y: contentHeight - 138, width: contentWidth, height: 30)
        respStatus.font = .systemFont(ofSize: 10, weight: .regular)
        respStatus.textColor = palette.subtleText
        respStatus.lineBreakMode = .byWordWrapping
        respStatus.maximumNumberOfLines = 2
        respStatus.usesSingleLineMode = false
        respStatus.setAccessibilityIdentifier("cpt.edge.response-status")
        innerCard.addSubview(respStatus)
        responseStatusLabel = respStatus

        // Scrollable text view for translation output
        let scrollFrame = NSRect(x: pad, y: 54, width: contentWidth, height: contentHeight - 202)
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = palette.responseSurface
        textView.textColor = palette.primaryText
        textView.font = .systemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.wantsLayer = true
        textView.layer?.cornerRadius = 12
        textView.layer?.masksToBounds = true
        textView.string = "AI 输出的英文/日文回复翻译将显示在这里。"
        textView.setAccessibilityIdentifier("cpt.edge.response-result")
        scroll.documentView = textView
        innerCard.addSubview(scroll)
        responseScrollView = scroll
        responseTextView = textView

        // Translate response button
        let transBtn = NSButton(title: "翻译已选/最新回复", target: controller, action: #selector(controller.translateLatestResponse))
        transBtn.frame = NSRect(x: pad, y: 18, width: 132, height: 28)
        transBtn.bezelStyle = .rounded
        transBtn.font = .systemFont(ofSize: 12, weight: .medium)
        transBtn.bezelColor = palette.accent
        transBtn.contentTintColor = .white
        transBtn.toolTip = "第一次只读取选中文字和 Accessibility；失败后才提供显式 OCR 重试"
        transBtn.setAccessibilityLabel("翻译已选或最新 AI 回复")
        transBtn.setAccessibilityIdentifier("cpt.edge.translate-response")
        innerCard.addSubview(transBtn)
        translateResponseButton = transBtn

        // Copy translation button
        let copyBtn = NSButton(title: "复制译文", target: controller, action: #selector(controller.copyResponseTranslation))
        copyBtn.frame = NSRect(x: pad + 140, y: 18, width: 100, height: 28)
        copyBtn.bezelStyle = .rounded
        copyBtn.font = .systemFont(ofSize: 12, weight: .regular)
        copyBtn.contentTintColor = palette.secondaryText
        copyBtn.isEnabled = false
        copyBtn.setAccessibilityIdentifier("cpt.edge.copy-response")
        innerCard.addSubview(copyBtn)
        copyResponseButton = copyBtn
    }

    // MARK: - Update State

    func updateState() {
        // Language pills
        langZhButton?.state = model.targetLanguage == .simplifiedChinese ? .on : .off
        langEnButton?.state = model.targetLanguage == .english ? .on : .off
        langJaButton?.state = model.targetLanguage == .japanese ? .on : .off
        updateLanguageButtonColors()

        // Input section
        var hasFreshInputOverride = false
        if let expiresAt = controller.inputStatusOverrideExpiresAt {
            if Date() < expiresAt, !controller.inputStatusOverride.isEmpty {
                hasFreshInputOverride = true
            } else {
                controller.inputStatusOverride = ""
                controller.inputStatusOverrideExpiresAt = nil
            }
        }

        if controller.isTranslatingInput {
            inputStatusLabel?.stringValue = "正在翻译..."
            translateInputButton?.isEnabled = false
            translateInputButton?.title = "翻译中..."
        } else if hasFreshInputOverride {
            inputStatusLabel?.stringValue = controller.inputStatusOverride
            translateInputButton?.isEnabled = controller.canAttemptInputTranslation
            translateInputButton?.title = isExpanded ? "重新读取" : "重试"
        } else if controller.hasTranslatableInput {
            inputStatusLabel?.stringValue = controller.usesSelectedInput
                ? (isExpanded ? "检测到选中文字 · 目标: \(model.targetLanguage.displayName)" : "已选中文字")
                : (isExpanded ? "检测到中文输入 · 目标: \(model.targetLanguage.displayName)" : "检测到中文")
            translateInputButton?.isEnabled = true
            translateInputButton?.title = controller.usesSelectedInput
                ? (isExpanded ? "翻译选中 → \(model.targetLanguage.shortChineseName)" : "翻译选中")
                : (isExpanded ? "翻译输入 → \(model.targetLanguage.shortChineseName)" : "译为\(model.targetLanguage.shortChineseName)")
        } else if controller.inputTargetIsInferred {
            inputStatusLabel?.stringValue = isExpanded
                ? "尚未确认聊天输入框 · 请先点进消息输入区"
                : "未确认输入框"
            translateInputButton?.isEnabled = false
            translateInputButton?.title = isExpanded ? "请先聚焦输入框" : "请先聚焦"
        } else if controller.canAttemptInputTranslation {
            inputStatusLabel?.stringValue = isExpanded
                ? "\(controller.currentAIAppName) 消息输入框就绪"
                : "输入框就绪"
            translateInputButton?.isEnabled = true
            translateInputButton?.title = isExpanded ? "读取并翻译" : "读取翻译"
        } else {
            inputStatusLabel?.stringValue = isExpanded ? "点击 AI 输入框后再试" : "未聚焦输入框"
            translateInputButton?.isEnabled = false
            translateInputButton?.title = isExpanded ? "翻译输入" : "待输入"
        }

        if let button = translateResponseButton {
            button.isEnabled = true
            if controller.isTranslatingResponse {
                button.title = isExpanded ? "取消读取" : "取消"
            } else if controller.manualOCRRetryAvailable {
                button.title = isExpanded ? "使用 OCR 重试" : "OCR 重试"
                button.setAccessibilityLabel("使用 OCR 重试，需要屏幕录制权限")
            } else {
                button.title = isExpanded ? "翻译已选/最新回复" : "译回复"
                button.setAccessibilityLabel("翻译已选或最新 AI 回复")
            }
        }

        guard isExpanded else { return }

        // Response section
        responseStatusLabel?.stringValue = controller.responseStatus.isEmpty
            ? "等待 AI 输出可翻译的外语内容..."
            : controller.responseStatus
        responseStatusLabel?.toolTip = responseStatusLabel?.stringValue

        if !controller.latestResponseTranslation.isEmpty {
            let display = BilingualResponseFormatter.display(
                source: controller.latestResponseSource,
                translation: controller.latestResponseTranslation
            )
            if responseTextView?.string != display {
                responseTextView?.textStorage?.setAttributedString(
                    bilingualAttributedText(
                        source: controller.latestResponseSource,
                        translation: controller.latestResponseTranslation
                    )
                )
            }
            copyResponseButton?.isEnabled = true
        } else {
            responseTextView?.string = controller.responseStatus.isEmpty
                ? "AI 输出的外语回复翻译将显示在这里。"
                : controller.responseStatus
            copyResponseButton?.isEnabled = false
        }

    }

    // MARK: - Helpers

    private func makePillButton(title: String, x: CGFloat, y: CGFloat, width: CGFloat, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: controller, action: action)
        btn.frame = NSRect(x: x, y: y, width: width, height: 20)
        btn.bezelStyle = .roundRect
        btn.font = .systemFont(ofSize: 10, weight: .semibold)
        btn.setButtonType(.toggle)
        btn.setAccessibilityIdentifier("cpt.edge.language.\(title.lowercased())")
        return btn
    }

    private func updateLanguageButtonColors() {
        for button in [langZhButton, langEnButton, langJaButton].compactMap({ $0 }) {
            let isSelected = button.state == .on
            button.contentTintColor = isSelected ? palette.accent : palette.secondaryText
            button.bezelColor = isSelected
                ? palette.accent.withAlphaComponent(0.30)
                : palette.responseSurface.withAlphaComponent(0.42)
        }
    }

    private func bilingualAttributedText(source: String, translation: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.paragraphSpacing = 5
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 2.5
        bodyParagraph.paragraphSpacing = 12

        result.append(NSAttributedString(
            string: "原文\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: palette.accent,
                .paragraphStyle: headingParagraph
            ]
        ))
        result.append(NSAttributedString(
            string: BilingualResponseFormatter.sourcePreview(source),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: palette.secondaryText,
                .paragraphStyle: bodyParagraph
            ]
        ))
        result.append(NSAttributedString(
            string: "\n\n译文\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: palette.accent,
                .paragraphStyle: headingParagraph
            ]
        ))
        result.append(NSAttributedString(
            string: translation,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
                .foregroundColor: palette.primaryText,
                .paragraphStyle: bodyParagraph
            ]
        ))
        return result
    }
}
