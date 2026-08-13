import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import CryptoKit
import NaturalLanguage
import OSLog

enum SelectionDiagnostics {
    private static let logger = Logger(
        subsystem: "local.codex.ClaudePromptTranslator",
        category: "Selection"
    )

    static var isEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func record(_ message: String) {
        guard isEnabled else { return }
        logger.debug("CPTSelection event=\(message, privacy: .private(mask: .hash))")
    }
}

enum SelectionCaptureMethod: String, Equatable, Sendable {
    case accessibility
    case menuCopyFallback
    case clipboardFallback
    case hoverAccessibility
    case screenOCR
    case subtitleOCR
}

struct SelectionCaptureHints {
    let sourceElement: AXUIElement?
    let pointerQuartzPoint: CGPoint?
    let dragStartQuartzPoint: CGPoint?
    let dragEndQuartzPoint: CGPoint?

    init(
        sourceElement: AXUIElement? = nil,
        pointerQuartzPoint: CGPoint? = nil,
        dragStartQuartzPoint: CGPoint? = nil,
        dragEndQuartzPoint: CGPoint? = nil
    ) {
        self.sourceElement = sourceElement
        self.pointerQuartzPoint = pointerQuartzPoint
        self.dragStartQuartzPoint = dragStartQuartzPoint
        self.dragEndQuartzPoint = dragEndQuartzPoint
    }
}

enum SelectionDragTextEstimator {
    static func estimatedUTF16Range(
        text: String,
        elementMinX: CGFloat,
        elementWidth: CGFloat,
        dragStartX: CGFloat,
        dragEndX: CGFloat
    ) -> NSRange? {
        let value = text as NSString
        guard value.length > 0,
              value.length <= 8_000,
              !text.contains("\n"),
              elementWidth.isFinite,
              elementWidth >= 12,
              abs(dragEndX - dragStartX) >= 4 else {
            return nil
        }

        let tolerance: CGFloat = 8
        let minX = elementMinX - tolerance
        let maxX = elementMinX + elementWidth + tolerance
        guard minX...maxX ~= dragStartX,
              minX...maxX ~= dragEndX else {
            return nil
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13)
        ]
        let measuredWidth = max(value.size(withAttributes: attributes).width, 1)

        func nearestIndex(for x: CGFloat) -> Int {
            let fraction = min(max((x - elementMinX) / elementWidth, 0), 1)
            let targetWidth = measuredWidth * fraction
            var lower = 0
            var upper = value.length
            while lower < upper {
                let middle = (lower + upper) / 2
                let width = value.substring(to: middle)
                    .size(withAttributes: attributes).width
                if width < targetWidth {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            let candidate = min(max(lower, 0), value.length)
            guard candidate > 0 else { return 0 }
            let previous = candidate - 1
            let candidateWidth = value.substring(to: candidate)
                .size(withAttributes: attributes).width
            let previousWidth = value.substring(to: previous)
                .size(withAttributes: attributes).width
            return abs(previousWidth - targetWidth) <= abs(candidateWidth - targetWidth)
                ? previous
                : candidate
        }

        let start = nearestIndex(for: dragStartX)
        let end = nearestIndex(for: dragEndX)
        let location = min(start, end)
        let length = abs(end - start)
        guard length > 0 else { return nil }
        return NSRange(location: location, length: length)
    }
}

/// Reads both the public selected-text attribute and the text-marker attributes
/// exposed by WebKit/Chromium accessibility trees. Chat clients built on web
/// views often expose a real selection only through `AXSelectedTextMarkerRange`.
enum AXSelectionTextReader {
    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let stringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"
    private static let attributedStringForTextMarkerRangeAttribute =
        "AXAttributedStringForTextMarkerRange"

    static func selectedText(from element: AXUIElement) -> String? {
        if let text = stringAttribute(kAXSelectedTextAttribute, from: element),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            selectedTextMarkerRangeAttribute as CFString,
            &markerRange
        ) == .success,
        let markerRange else {
            return nil
        }

        for attribute in [
            stringForTextMarkerRangeAttribute,
            attributedStringForTextMarkerRangeAttribute
        ] {
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                attribute as CFString,
                markerRange,
                &value
            ) == .success,
            let value else {
                continue
            }
            let text: String?
            if let plainText = value as? String {
                text = plainText
            } else if let attributedText = value as? NSAttributedString {
                text = attributedText.string
            } else {
                text = nil
            }
            if let text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }
}

enum SelectionScanPolicy: Equatable, Sendable {
    /// Used after a mouse or keyboard selection event. This path checks the
    /// notification element, the element under the released pointer, the focused
    /// hierarchy, and small bounded descendant neighborhoods.
    case focusedPath

    /// Used by an explicit shortcut. A bounded window-tree walk is allowed before
    /// falling back to Command+C.
    case boundedTree
}

enum SelectionCaptureRetryPolicy {
    static func delaysAfterEmptyResult(for scanPolicy: SelectionScanPolicy) -> [UInt64] {
        switch scanPolicy {
        case .focusedPath:
            return [120_000_000, 260_000_000]
        case .boundedTree:
            return [150_000_000]
        }
    }
}

@MainActor
enum AccessibilityMessagingPolicy {
    private static var configured = false
    private static let timeout: Float = 0.22

    static func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        let result = AXUIElementSetMessagingTimeout(
            AXUIElementCreateSystemWide(),
            timeout
        )
        SelectionDiagnostics.record(
            "ax messaging timeout configured result=\(result.rawValue) milliseconds=220"
        )
    }
}

enum CopyMenuItemMatcher {
    private static let exactLocalizedTitles: Set<String> = [
        "copy", "复制", "拷贝", "コピー", "복사"
    ]

    static func matches(
        role: String?,
        title: String?,
        identifier: String?,
        commandCharacter: String?,
        commandModifiers: UInt32?,
        isEnabled: Bool
    ) -> Bool {
        guard isEnabled,
              role == (kAXMenuItemRole as String),
              commandModifiers ?? 0 == 0 else {
            return false
        }
        let normalizedTitle = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedIdentifier = identifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedCommand = commandCharacter?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasExactIdentity = normalizedTitle.map(exactLocalizedTitles.contains) == true
            || normalizedIdentifier == "copy"
            || normalizedIdentifier == "copy:"
        return hasExactIdentity && (normalizedCommand == nil || normalizedCommand == "c")
    }
}

enum UniversalSelectionError: LocalizedError {
    case accessibilityPermissionRequired
    case sourceApplicationChanged
    case selectionIsProtected
    case selectionChanged
    case selectionIsReadOnly
    case replacementCouldNotBeVerified

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "请先授予辅助功能权限。"
        case .sourceApplicationChanged:
            return "原应用已不在前台，没有替换任何文字。"
        case .selectionIsProtected:
            return "密码或受保护内容不会被读取或翻译。"
        case .selectionChanged:
            return "原选区已经变化，没有替换任何文字。"
        case .selectionIsReadOnly:
            return "这个选区来自只读内容，可复制译文但不能原位替换。"
        case .replacementCouldNotBeVerified:
            return "应用没有确认替换结果，为避免覆盖内容已停止。"
        }
    }
}

enum SelectionProtectionClassifier {
    static func isProtected(
        role: String?,
        subrole: String?,
        containsProtectedContent: Bool
    ) -> Bool {
        guard !containsProtectedContent else {
            return true
        }
        let normalizedRole = role?.lowercased() ?? ""
        let normalizedSubrole = subrole?.lowercased() ?? ""
        return normalizedRole.contains("secure")
            || normalizedRole.contains("password")
            || normalizedSubrole.contains("secure")
            || normalizedSubrole.contains("password")
    }
}

enum SelectionReplacementVerification {
    static func originalSelectionMatches(current: String?, expected: String) -> Bool {
        current == expected
    }

    static func writeWasVerified(
        expectedValue: String?,
        currentValue: String?,
        selectedTextAfterWrite: String?,
        renderedReplacement: String
    ) -> Bool {
        if let expectedValue, currentValue == expectedValue {
            return true
        }
        return selectedTextAfterWrite == renderedReplacement
    }
}

enum SelectionFingerprint {
    static func make(
        processIdentifier: pid_t,
        text: String,
        elementIdentity: Int?,
        selectedRange: NSRange?
    ) -> String {
        let elementComponent = elementIdentity.map(String.init) ?? "none"
        let rangeComponent = selectedRange
            .map { "\($0.location):\($0.length)" }
            ?? "none"
        let textDigest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(processIdentifier)|\(elementComponent)|\(rangeComponent)|\(textDigest)"
    }
}

enum SelectionReplacementContextSafety {
    static func canProceed(
        capturedRange: NSRange?,
        currentRange: NSRange?,
        capturedElementIsFocused: Bool,
        containsProtectedContent: Bool
    ) -> Bool {
        guard capturedElementIsFocused,
              !containsProtectedContent,
              let capturedRange,
              capturedRange.length > 0 else {
            return false
        }
        return currentRange == capturedRange
    }
}

enum ClipboardFallbackSafety {
    static func canAcceptCopy(
        baselineChangeCount: Int,
        observedChangeCount: Int,
        quietChangeCount: Int,
        initialInputEpoch: UInt64,
        currentInputEpoch: UInt64,
        contextIsCurrent: Bool,
        selectionRangeMatches: Bool
    ) -> Bool {
        contextIsCurrent
            && selectionRangeMatches
            && initialInputEpoch == currentInputEpoch
            && observedChangeCount == baselineChangeCount + 1
            && quietChangeCount == observedChangeCount
    }

    static func canRestore(
        acceptedChangeCount: Int,
        currentChangeCount: Int,
        initialInputEpoch: UInt64,
        currentInputEpoch: UInt64,
        contextIsCurrent: Bool,
        copiedValueStillMatches: Bool
    ) -> Bool {
        contextIsCurrent
            && copiedValueStillMatches
            && initialInputEpoch == currentInputEpoch
            && currentChangeCount == acceptedChangeCount
    }
}

/// A short-lived guard used only while an explicit clipboard fallback is in
/// progress. It records that physical input occurred, without retaining key
/// codes, characters, mouse positions, or any other event payload.
final class ClipboardFallbackInputGuard: @unchecked Sendable {
    static let syntheticCopyEventTag: Int64 = 0x435054434F5059 // "CPTCOPY"

    private let lock = NSLock()
    private var epochValue: UInt64 = 0
    private var monitor: Any?

    init() {
        let mask: NSEvent.EventTypeMask = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                == Self.syntheticCopyEventTag {
                return
            }
            self?.recordPhysicalInput()
        }
    }

    var isMonitoring: Bool {
        monitor != nil
    }

    var epoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return epochValue
    }

    @MainActor
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func recordPhysicalInput() {
        lock.lock()
        epochValue &+= 1
        lock.unlock()
    }
}

struct SelectionLanguageRoute: Equatable, Sendable {
    let sourceIdentifier: String
    let sourceDisplayName: String
    let targetLanguage: TargetLanguage
}

enum SelectionLanguageRouter {
    static func route(
        for text: String,
        manualTarget: TargetLanguage? = nil
    ) -> SelectionLanguageRoute {
        let sourceIdentifier = detectedLanguageIdentifier(in: text)
        let target = manualTarget ?? (isChinese(sourceIdentifier) ? .english : .simplifiedChinese)
        return SelectionLanguageRoute(
            sourceIdentifier: sourceIdentifier,
            sourceDisplayName: displayName(for: sourceIdentifier),
            targetLanguage: target
        )
    }

    static func detectedLanguageIdentifier(in text: String) -> String {
        let projectedText = TranslationChunker.languageDetectionProjection(for: text)
        let languageSample = projectedText.isEmpty ? text : projectedText
        let profile = scriptProfile(in: languageSample)

        // Kana is a stronger signal than Han because Japanese routinely mixes
        // the scripts. Han-only short selections are more often Chinese in the
        // user's bilingual workflow and should not be routed back to Chinese.
        if profile.kana > 0 {
            return "ja"
        }
        if profile.hangul > 0 {
            return "ko"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(languageSample)
        let naturalLanguage = recognizer.dominantLanguage?.rawValue

        if let naturalLanguage, isChinese(naturalLanguage) {
            return naturalLanguage
        }
        if profile.han >= 2,
           Double(profile.han) / Double(max(profile.letters, 1)) >= 0.18 {
            return "zh-Hans"
        }
        return naturalLanguage ?? "und"
    }

    private static func scriptProfile(in text: String) -> (han: Int, kana: Int, hangul: Int, letters: Int) {
        var han = 0
        var kana = 0
        var hangul = 0
        var letters = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
            switch scalar.value {
            case 0x3040...0x30FF, 0xFF66...0xFF9F:
                kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                han += 1
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
                hangul += 1
            default:
                break
            }
        }
        return (han, kana, hangul, letters)
    }

    private static func isChinese(_ identifier: String) -> Bool {
        identifier.lowercased().hasPrefix("zh")
    }

    private static func displayName(for identifier: String) -> String {
        if isChinese(identifier) {
            return "中文"
        }
        switch identifier {
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西班牙语"
        case "ru": return "俄语"
        case "und": return "自动识别"
        default:
            return Locale.current.localizedString(forLanguageCode: identifier) ?? identifier
        }
    }
}

enum SelectionTextNormalizer {
    static func normalizedText(
        from rawText: String,
        maximumCharacters: Int = TranslationLimits.maxInputCharacters
    ) -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count <= maximumCharacters,
              text.unicodeScalars.contains(where: {
                  CharacterSet.alphanumerics.contains($0)
                      || CharacterSet.letters.contains($0)
              }) else {
            return nil
        }
        return text
    }
}

@MainActor
final class UniversalTextSelection {
    let app: NSRunningApplication
    let appName: String
    let rawText: String
    let text: String
    let captureMethod: SelectionCaptureMethod
    let anchorRect: NSRect?
    let canReplace: Bool

    private let element: AXUIElement?
    private let selectedRange: NSRange?

    init(
        app: NSRunningApplication,
        rawText: String,
        text: String,
        captureMethod: SelectionCaptureMethod,
        anchorRect: NSRect?,
        element: AXUIElement?,
        selectedRange: NSRange?
    ) {
        self.app = app
        self.appName = app.localizedName ?? "当前应用"
        self.rawText = rawText
        self.text = text
        self.captureMethod = captureMethod
        self.anchorRect = anchorRect
        self.element = element
        self.selectedRange = selectedRange
        self.canReplace = element.map {
            Self.supportsVerifiedReplacement(
                in: $0,
                app: app,
                rawText: rawText,
                selectedRange: selectedRange
            )
        } ?? false
    }

    var fingerprint: String {
        SelectionFingerprint.make(
            processIdentifier: app.processIdentifier,
            text: text,
            elementIdentity: element.map { Int(CFHash($0)) },
            selectedRange: selectedRange
        )
    }

    /// Returns a non-replaceable projection for local relevance filtering.
    /// Filtering is intentionally applied only to read-only captures so a
    /// translated subset can never overwrite a larger editable selection.
    func readOnlyProjection(text projectedText: String) -> UniversalTextSelection {
        UniversalTextSelection(
            app: app,
            rawText: projectedText,
            text: projectedText,
            captureMethod: captureMethod,
            anchorRect: anchorRect,
            element: nil,
            selectedRange: nil
        )
    }

    func replace(
        with replacement: String,
        authorizationCheck: @MainActor () -> Bool = { true }
    ) async throws {
        guard AccessibilityPermission.isTrusted else {
            throw UniversalSelectionError.accessibilityPermissionRequired
        }
        guard authorizationCheck() else { throw CancellationError() }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              !app.isTerminated else {
            throw UniversalSelectionError.sourceApplicationChanged
        }
        guard canReplace, let element else {
            throw UniversalSelectionError.selectionIsReadOnly
        }
        guard SelectionReplacementContextSafety.canProceed(
            capturedRange: selectedRange,
            currentRange: Self.rangeAttribute(kAXSelectedTextRangeAttribute, from: element),
            capturedElementIsFocused: Self.isCurrentFocusedElement(element, in: app),
            containsProtectedContent: Self.isProtectedElementOrAncestor(element)
        ) else {
            throw UniversalSelectionError.selectionChanged
        }
        let renderedReplacement = Self.replacementPreservingOuterWhitespace(
            replacement,
            selectedText: rawText
        )

        let currentSelectedText = Self.stringAttribute(kAXSelectedTextAttribute, from: element)
        guard SelectionReplacementVerification.originalSelectionMatches(
            current: currentSelectedText,
            expected: rawText
        ) else {
            throw UniversalSelectionError.selectionChanged
        }

        let valueBefore = Self.stringAttribute(kAXValueAttribute, from: element)
        let expectedValue = Self.expectedValueAfterReplacement(
            valueBefore: valueBefore,
            selectedRange: selectedRange,
            rawText: rawText,
            replacement: renderedReplacement
        )

        if authorizationCheck(),
           Self.isSettable(kAXSelectedTextAttribute, on: element),
           AXUIElementSetAttributeValue(
               element,
               kAXSelectedTextAttribute as CFString,
               renderedReplacement as CFString
           ) == .success {
            try await Task.sleep(nanoseconds: 80_000_000)
            try Task.checkCancellation()

            let currentValue = Self.stringAttribute(kAXValueAttribute, from: element)
            let selectedAfter = Self.stringAttribute(kAXSelectedTextAttribute, from: element)
            if SelectionReplacementVerification.writeWasVerified(
                expectedValue: expectedValue,
                currentValue: currentValue,
                selectedTextAfterWrite: selectedAfter,
                renderedReplacement: renderedReplacement
            ) {
                return
            }
        }

        if let expectedValue,
           authorizationCheck(),
           Self.isSettable(kAXValueAttribute, on: element),
           AXUIElementSetAttributeValue(
               element,
               kAXValueAttribute as CFString,
               expectedValue as CFString
           ) == .success {
            try await Task.sleep(nanoseconds: 80_000_000)
            try Task.checkCancellation()
            if Self.stringAttribute(kAXValueAttribute, from: element) == expectedValue {
                return
            }
        }

        throw UniversalSelectionError.replacementCouldNotBeVerified
    }

    private static func supportsVerifiedReplacement(
        in element: AXUIElement,
        app: NSRunningApplication,
        rawText: String,
        selectedRange: NSRange?
    ) -> Bool {
        guard !isProtectedElementOrAncestor(element),
              isCurrentFocusedElement(element, in: app),
              let selectedRange,
              selectedRange.location != NSNotFound,
              selectedRange.length > 0 else {
            return false
        }
        if isSettable(kAXSelectedTextAttribute, on: element) {
            return true
        }
        guard isSettable(kAXValueAttribute, on: element),
              let value = stringAttribute(kAXValueAttribute, from: element),
              selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              NSMaxRange(selectedRange) <= (value as NSString).length else {
            return false
        }
        return (value as NSString).substring(with: selectedRange) == rawText
    }

    private static func expectedValueAfterReplacement(
        valueBefore: String?,
        selectedRange: NSRange?,
        rawText: String,
        replacement: String
    ) -> String? {
        guard let valueBefore,
              let selectedRange,
              selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              NSMaxRange(selectedRange) <= (valueBefore as NSString).length,
              (valueBefore as NSString).substring(with: selectedRange) == rawText else {
            return nil
        }
        return (valueBefore as NSString).replacingCharacters(in: selectedRange, with: replacement)
    }

    private static func replacementPreservingOuterWhitespace(
        _ replacement: String,
        selectedText: String
    ) -> String {
        guard let firstContent = selectedText.firstIndex(where: { !$0.isWhitespace }),
              let lastContent = selectedText.lastIndex(where: { !$0.isWhitespace }) else {
            return replacement
        }
        let leading = String(selectedText[..<firstContent])
        let trailingStart = selectedText.index(after: lastContent)
        let trailing = String(selectedText[trailingStart...])
        return leading + replacement + trailing
    }

    private static func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func rangeAttribute(_ attribute: String, from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0,
              range.length > 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func isCurrentFocusedElement(
        _ element: AXUIElement,
        in app: NSRunningApplication
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: applicationElement
        ) else {
            return false
        }
        return CFEqual(element, focusedElement)
    }

    private static func isProtectedElementOrAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return false }
            if isProtectedElement(candidate) {
                return true
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }
        return false
    }

    private static func isProtectedElement(_ element: AXUIElement) -> Bool {
        SelectionProtectionClassifier.isProtected(
            role: stringAttribute(kAXRoleAttribute, from: element),
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            containsProtectedContent: booleanAttribute("AXContainsProtectedContent", from: element)
        )
    }

    private static func booleanAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}

@MainActor
struct UniversalSelectionReader {
    func captureUsingCopyMenuOnly(
        from app: NSRunningApplication?,
        authorizationCheck: @MainActor () -> Bool = { true }
    ) async throws -> UniversalTextSelection? {
        guard let app,
              !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        guard AccessibilityPermission.isTrusted else {
            throw UniversalSelectionError.accessibilityPermissionRequired
        }
        guard authorizationCheck() else { throw CancellationError() }
        AccessibilityMessagingPolicy.configureIfNeeded()
        return try await clipboardSelection(
            in: app,
            allowKeyboardCopyFallback: false,
            allowMenuFocusChangeAfterCopy: true,
            authorizationCheck: authorizationCheck
        )
    }

    func capture(
        from app: NSRunningApplication?,
        scanPolicy: SelectionScanPolicy,
        allowClipboardFallback: Bool,
        allowKeyboardCopyFallback: Bool = true,
        hints: SelectionCaptureHints = SelectionCaptureHints(),
        authorizationCheck: @MainActor () -> Bool = { true }
    ) async throws -> UniversalTextSelection? {
        guard let app,
              !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        guard AccessibilityPermission.isTrusted else {
            SelectionDiagnostics.record("capture rejected: accessibility permission missing")
            throw UniversalSelectionError.accessibilityPermissionRequired
        }
        guard authorizationCheck() else { throw CancellationError() }
        AccessibilityMessagingPolicy.configureIfNeeded()

        let retryDelays = [UInt64(0)]
            + SelectionCaptureRetryPolicy.delaysAfterEmptyResult(for: scanPolicy)
        for (attempt, delay) in retryDelays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            try Task.checkCancellation()
            guard authorizationCheck() else { throw CancellationError() }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == app.processIdentifier || app.isActive else {
                SelectionDiagnostics.record("capture stopped: source app changed")
                return nil
            }
            guard authorizationCheck() else { throw CancellationError() }
            if let accessibilitySelection = accessibilitySelection(
                in: app,
                scanPolicy: scanPolicy,
                hints: hints
            ) {
                SelectionDiagnostics.record(
                    "capture success method=ax app=\(app.bundleIdentifier ?? "unknown") attempt=\(attempt + 1) count=\(accessibilitySelection.text.count)"
                )
                return accessibilitySelection
            }
            SelectionDiagnostics.record(
                "capture empty method=ax app=\(app.bundleIdentifier ?? "unknown") attempt=\(attempt + 1)"
            )
        }

        guard allowClipboardFallback else {
            SelectionDiagnostics.record(
                "capture empty method=ax app=\(app.bundleIdentifier ?? "unknown") policy=\(String(describing: scanPolicy))"
            )
            return nil
        }
        guard authorizationCheck() else { throw CancellationError() }
        if focusedPathContainsProtectedContent(in: app) {
            SelectionDiagnostics.record(
                "capture rejected method=clipboard app=\(app.bundleIdentifier ?? "unknown") reason=protected"
            )
            throw UniversalSelectionError.selectionIsProtected
        }
        let clipboardResult = try await clipboardSelection(
            in: app,
            allowKeyboardCopyFallback: allowKeyboardCopyFallback,
            allowMenuFocusChangeAfterCopy: false,
            authorizationCheck: authorizationCheck
        )
        SelectionDiagnostics.record(
            "capture \(clipboardResult == nil ? "empty" : "success") method=clipboard app=\(app.bundleIdentifier ?? "unknown") count=\(clipboardResult?.text.count ?? 0)"
        )
        return clipboardResult
    }

    private func accessibilitySelection(
        in app: NSRunningApplication,
        scanPolicy: SelectionScanPolicy,
        hints: SelectionCaptureHints
    ) -> UniversalTextSelection? {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedElement = elementAttribute(kAXFocusedUIElementAttribute, from: applicationElement)
        let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement)
            ?? elementAttribute(kAXMainWindowAttribute, from: applicationElement)
        let notificationElement = validatedElement(
            hints.sourceElement,
            processIdentifier: app.processIdentifier
        )
        let pointerElement = hints.pointerQuartzPoint.flatMap {
            element(at: $0, in: applicationElement, processIdentifier: app.processIdentifier)
        }

        var candidates: [AXUIElement] = []
        var seen = Set<Int>()

        func append(_ element: AXUIElement?) {
            guard let element else { return }
            let identity = Int(CFHash(element))
            if seen.insert(identity).inserted {
                candidates.append(element)
            }
        }

        func appendHierarchy(from element: AXUIElement?, maximumAncestors: Int) {
            append(element)
            var ancestor = element
            for _ in 0..<maximumAncestors {
                ancestor = ancestor.flatMap { elementAttribute(kAXParentAttribute, from: $0) }
                append(ancestor)
            }
        }

        appendHierarchy(from: notificationElement, maximumAncestors: 10)
        appendHierarchy(from: pointerElement, maximumAncestors: 10)
        appendHierarchy(from: focusedElement, maximumAncestors: 10)
        append(focusedWindow)
        append(applicationElement)

        for element in candidates {
            if let selection = selection(from: element, app: app) {
                return selection
            }
        }

        let localRoots = [notificationElement, pointerElement, focusedElement]
            .compactMap { $0 }
        for root in localRoots where !isApplicationOrWindow(root) {
            if let selection = descendantSelection(
                from: root,
                app: app,
                maximumNodes: 120,
                maximumDepth: 6,
                seen: &seen
            ) {
                return selection
            }
        }

        if let selection = dragGeometrySelection(
            in: app,
            applicationElement: applicationElement,
            hints: hints
        ) {
            SelectionDiagnostics.record("capture geometry fallback success")
            return selection
        }

        guard scanPolicy == .boundedTree, let root = focusedWindow else {
            return nil
        }

        var queue: [(AXUIElement, Int)] = children(of: root).map { ($0, 1) }
        var cursor = 0
        var visited = 0
        var fullScanSeen = Set<Int>()
        while cursor < queue.count, visited < 450 {
            let (element, depth) = queue[cursor]
            cursor += 1
            visited += 1
            let identity = Int(CFHash(element))
            guard fullScanSeen.insert(identity).inserted else {
                continue
            }

            if let selection = selection(from: element, app: app) {
                return selection
            }
            if depth < 12 {
                queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func dragGeometrySelection(
        in app: NSRunningApplication,
        applicationElement: AXUIElement,
        hints: SelectionCaptureHints
    ) -> UniversalTextSelection? {
        guard let dragStart = hints.dragStartQuartzPoint,
              let dragEnd = hints.dragEndQuartzPoint else {
            SelectionDiagnostics.record("capture geometry empty: drag hints missing")
            return nil
        }
        let dragDistance = hypot(dragEnd.x - dragStart.x, dragEnd.y - dragStart.y)
        guard dragDistance >= 4 else {
            SelectionDiagnostics.record("capture geometry empty: drag too short")
            return nil
        }
        SelectionDiagnostics.record("capture geometry started distance=\(Int(dragDistance))")

        guard let startHit = element(
            at: dragStart,
            in: applicationElement,
            processIdentifier: app.processIdentifier
        ), let endHit = element(
            at: dragEnd,
            in: applicationElement,
            processIdentifier: app.processIdentifier
        ) else {
            SelectionDiagnostics.record("capture geometry empty: point hit failed")
            return nil
        }
        guard let startElement = staticTextElement(at: dragStart, from: startHit),
              let endElement = staticTextElement(at: dragEnd, from: endHit) else {
            SelectionDiagnostics.record("capture geometry empty: static text unresolved")
            return nil
        }
        guard !isProtectedElementOrAncestor(startElement) else {
            SelectionDiagnostics.record("capture geometry rejected: protected")
            return nil
        }
        guard let fullText = stringAttribute(kAXValueAttribute, from: startElement)
                ?? stringAttribute(kAXTitleAttribute, from: startElement),
              let endText = stringAttribute(kAXValueAttribute, from: endElement)
                ?? stringAttribute(kAXTitleAttribute, from: endElement),
              fullText == endText,
              !fullText.contains("\n") else {
            SelectionDiagnostics.record("capture geometry empty: text mismatch or multiline")
            return nil
        }
        guard let axRect = rawAXRectAttribute(from: startElement),
              let endRect = rawAXRectAttribute(from: endElement),
              abs(axRect.minX - endRect.minX) <= 1,
              abs(axRect.minY - endRect.minY) <= 1,
              abs(axRect.width - endRect.width) <= 1,
              abs(axRect.height - endRect.height) <= 1,
              axRect.height <= 80,
              abs(dragStart.y - dragEnd.y) <= max(axRect.height, 18) else {
            SelectionDiagnostics.record("capture geometry empty: bounds mismatch")
            return nil
        }
        guard let selectedRange = SelectionDragTextEstimator.estimatedUTF16Range(
            text: fullText,
            elementMinX: axRect.minX,
            elementWidth: axRect.width,
            dragStartX: dragStart.x,
            dragEndX: dragEnd.x
        ), NSMaxRange(selectedRange) <= (fullText as NSString).length else {
            SelectionDiagnostics.record("capture geometry empty: range estimation failed")
            return nil
        }

        let rawText = (fullText as NSString).substring(with: selectedRange)
        guard let text = SelectionTextNormalizer.normalizedText(from: rawText) else {
            return nil
        }

        let lowerFraction = CGFloat(selectedRange.location)
            / CGFloat(max((fullText as NSString).length, 1))
        let upperFraction = CGFloat(NSMaxRange(selectedRange))
            / CGFloat(max((fullText as NSString).length, 1))
        let estimatedSelectionRect = CGRect(
            x: axRect.minX + axRect.width * lowerFraction,
            y: axRect.minY,
            width: max(axRect.width * (upperFraction - lowerFraction), 1),
            height: axRect.height
        )

        return UniversalTextSelection(
            app: app,
            rawText: rawText,
            text: text,
            captureMethod: .accessibility,
            anchorRect: appKitRect(fromAXRect: estimatedSelectionRect),
            element: startElement,
            selectedRange: selectedRange
        )
    }

    private func staticTextElement(
        at point: CGPoint,
        from element: AXUIElement
    ) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { break }
            if stringAttribute(kAXRoleAttribute, from: candidate)
                == (kAXStaticTextRole as String) {
                return candidate
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }

        var queue: [(AXUIElement, Int)] = children(of: element).map { ($0, 1) }
        var cursor = 0
        var visited = 0
        var best: (element: AXUIElement, area: CGFloat)?
        while cursor < queue.count, visited < 180 {
            let (candidate, depth) = queue[cursor]
            cursor += 1
            visited += 1
            if stringAttribute(kAXRoleAttribute, from: candidate)
                    == (kAXStaticTextRole as String),
               let rect = rawAXRectAttribute(from: candidate),
               rect.insetBy(dx: -4, dy: -4).contains(point) {
                let area = rect.width * rect.height
                if best.map({ area < $0.area }) ?? true {
                    best = (candidate, area)
                }
            }
            if depth < 10 {
                queue.append(contentsOf: children(of: candidate).map { ($0, depth + 1) })
            }
        }
        return best?.element
    }

    private func descendantSelection(
        from root: AXUIElement,
        app: NSRunningApplication,
        maximumNodes: Int,
        maximumDepth: Int,
        seen: inout Set<Int>
    ) -> UniversalTextSelection? {
        var queue: [(AXUIElement, Int)] = children(of: root).map { ($0, 1) }
        var cursor = 0
        var visited = 0
        while cursor < queue.count, visited < maximumNodes {
            let (element, depth) = queue[cursor]
            cursor += 1
            visited += 1
            let identity = Int(CFHash(element))
            guard seen.insert(identity).inserted else { continue }

            if let selection = selection(from: element, app: app) {
                SelectionDiagnostics.record(
                    "capture local descendant success depth=\(depth) visited=\(visited)"
                )
                return selection
            }
            if depth < maximumDepth {
                queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
            }
        }
        SelectionDiagnostics.record("capture local descendant empty visited=\(visited)")
        return nil
    }

    private func selection(
        from element: AXUIElement,
        app: NSRunningApplication
    ) -> UniversalTextSelection? {
        guard !isProtectedElementOrAncestor(element),
              let rawText = AXSelectionTextReader.selectedText(from: element),
              let text = SelectionTextNormalizer.normalizedText(from: rawText) else {
            return nil
        }
        let range = rangeAttribute(kAXSelectedTextRangeAttribute, from: element)
        let anchor = boundsForSelection(in: element)
            ?? rectAttribute(from: element)

        return UniversalTextSelection(
            app: app,
            rawText: rawText,
            text: text,
            captureMethod: .accessibility,
            anchorRect: anchor,
            element: element,
            selectedRange: range
        )
    }

    private func clipboardSelection(
        in app: NSRunningApplication,
        allowKeyboardCopyFallback: Bool,
        allowMenuFocusChangeAfterCopy: Bool,
        authorizationCheck: @MainActor () -> Bool
    ) async throws -> UniversalTextSelection? {
        guard authorizationCheck() else { throw CancellationError() }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                || app.isActive else {
            throw UniversalSelectionError.sourceApplicationChanged
        }

        guard !IsSecureEventInputEnabled() else {
            throw UniversalSelectionError.selectionIsProtected
        }
        guard let injectionContext = KeyboardInjectionContext.capture(for: app) else {
            return nil
        }
        guard injectionContext.isCurrent(for: app) else {
            throw UniversalSelectionError.sourceApplicationChanged
        }
        guard !isProtectedElementOrAncestor(injectionContext.focusedElement) else {
            throw UniversalSelectionError.selectionIsProtected
        }

        let initialSelectedRange = rangeAttribute(
            kAXSelectedTextRangeAttribute,
            from: injectionContext.focusedElement
        )
        let inputGuard = ClipboardFallbackInputGuard()
        guard inputGuard.isMonitoring else {
            return nil
        }
        defer { inputGuard.stop() }
        let initialInputEpoch = inputGuard.epoch

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture()
        let baselineChangeCount = snapshot.changeCountAtCapture
        let menuCopyItem = enabledCopyMenuItem(in: app)
        guard authorizationCheck(),
              pasteboard.changeCount == baselineChangeCount,
              selectionCopyContextIsCurrent(
                  injectionContext,
                  initialSelectedRange: initialSelectedRange,
                  in: app
              ),
              inputGuard.epoch == initialInputEpoch,
              let captureMethod = triggerCopy(
                  menuItem: menuCopyItem,
                  processIdentifier: app.processIdentifier,
                  allowKeyboardFallback: allowKeyboardCopyFallback,
                  authorizationCheck: authorizationCheck
              ) else {
            return nil
        }
        let permitsMenuFocusChange = allowMenuFocusChangeAfterCopy
            && captureMethod == .menuCopyFallback

        var observedChangeCount: Int?
        for _ in 0..<24 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 25_000_000)
            guard authorizationCheck() else { throw CancellationError() }
            guard inputGuard.epoch == initialInputEpoch else {
                // The current pasteboard may now be a deliberate user copy.
                // Preserve it and discard the fallback result.
                return nil
            }
            if !permitsMenuFocusChange,
               !selectionCopyContextIsCurrent(
                   injectionContext,
                   initialSelectedRange: initialSelectedRange,
                   in: app
               ) {
                return nil
            }
            let currentChangeCount = pasteboard.changeCount
            guard currentChangeCount != baselineChangeCount else {
                continue
            }
            observedChangeCount = currentChangeCount
            break
        }

        guard let observedChangeCount else {
            return nil
        }
        let copiedValue = pasteboard.string(forType: .string)

        // Allow a short quiet period for a late second writer (for example a
        // user copy or clipboard manager). Any extra change makes ownership
        // ambiguous, so the result is discarded and the clipboard is left as-is.
        try await Task.sleep(nanoseconds: 90_000_000)
        guard authorizationCheck() else { throw CancellationError() }
        let appRemainsActive = NSWorkspace.shared.frontmostApplication?.processIdentifier
                == app.processIdentifier || app.isActive
        let contextIsCurrent = selectionCopyContextIsCurrent(
            injectionContext,
            initialSelectedRange: initialSelectedRange,
            in: app
        ) || (permitsMenuFocusChange && appRemainsActive)
        let currentSelectedRange = rangeAttribute(
            kAXSelectedTextRangeAttribute,
            from: injectionContext.focusedElement
        )
        guard ClipboardFallbackSafety.canAcceptCopy(
            baselineChangeCount: baselineChangeCount,
            observedChangeCount: observedChangeCount,
            quietChangeCount: pasteboard.changeCount,
            initialInputEpoch: initialInputEpoch,
            currentInputEpoch: inputGuard.epoch,
            contextIsCurrent: contextIsCurrent,
            selectionRangeMatches: currentSelectedRange == initialSelectedRange
                || permitsMenuFocusChange
        ) else {
            return nil
        }

        guard authorizationCheck(),
              ClipboardFallbackSafety.canRestore(
            acceptedChangeCount: observedChangeCount,
            currentChangeCount: pasteboard.changeCount,
            initialInputEpoch: initialInputEpoch,
            currentInputEpoch: inputGuard.epoch,
            contextIsCurrent: selectionCopyContextIsCurrent(
                    injectionContext,
                    initialSelectedRange: initialSelectedRange,
                    in: app
                ) || (permitsMenuFocusChange && appRemainsActive),
            copiedValueStillMatches: pasteboard.string(forType: .string) == copiedValue
        ) else {
            return nil
        }

        guard authorizationCheck() else { throw CancellationError() }
        snapshot.restoreIfChangeCount(is: observedChangeCount)
        guard let rawText = copiedValue,
              let text = SelectionTextNormalizer.normalizedText(from: rawText) else {
            return nil
        }
        SelectionDiagnostics.record("capture success method=copy-menu count=\(text.count)")
        return UniversalTextSelection(
            app: app,
            rawText: rawText,
            text: text,
            captureMethod: captureMethod,
            anchorRect: nil,
            element: nil,
            selectedRange: nil
        )
    }

    private func triggerCopy(
        menuItem: AXUIElement?,
        processIdentifier: pid_t,
        allowKeyboardFallback: Bool,
        authorizationCheck: @MainActor () -> Bool
    ) -> SelectionCaptureMethod? {
        guard authorizationCheck() else { return nil }
        if let menuItem {
            guard authorizationCheck() else { return nil }
            let result = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
            SelectionDiagnostics.record("copy trigger method=menu result=\(result.rawValue)")
            if result == .success {
                return .menuCopyFallback
            }
        }
        guard authorizationCheck(),
              allowKeyboardFallback,
              postCopyCommand(to: processIdentifier) else {
            return nil
        }
        SelectionDiagnostics.record("copy trigger method=keyboard result=0")
        return .clipboardFallback
    }

    private func enabledCopyMenuItem(in app: NSRunningApplication) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = elementAttribute(kAXMenuBarAttribute, from: applicationElement) else {
            return nil
        }

        var queue: [(AXUIElement, Int)] = [(menuBar, 0)]
        var cursor = 0
        var visited = 0
        var seen = Set<Int>()
        while cursor < queue.count, visited < 320 {
            let (element, depth) = queue[cursor]
            cursor += 1
            visited += 1
            let identity = Int(CFHash(element))
            guard seen.insert(identity).inserted else { continue }

            if CopyMenuItemMatcher.matches(
                role: stringAttribute(kAXRoleAttribute, from: element),
                title: stringAttribute(kAXTitleAttribute, from: element),
                identifier: stringAttribute(kAXIdentifierAttribute, from: element),
                commandCharacter: stringAttribute(kAXMenuItemCmdCharAttribute, from: element),
                commandModifiers: unsignedIntegerAttribute(
                    kAXMenuItemCmdModifiersAttribute,
                    from: element
                ),
                isEnabled: booleanAttribute(kAXEnabledAttribute, from: element)
            ) {
                SelectionDiagnostics.record("copy menu item found visited=\(visited)")
                return element
            }
            if depth < 8 {
                queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
            }
        }
        SelectionDiagnostics.record("copy menu item unavailable visited=\(visited)")
        return nil
    }

    private func selectionCopyContextIsCurrent(
        _ context: KeyboardInjectionContext,
        initialSelectedRange: NSRange?,
        in app: NSRunningApplication
    ) -> Bool {
        guard context.isCurrent(for: app),
              !IsSecureEventInputEnabled(),
              !isProtectedElementOrAncestor(context.focusedElement) else {
            return false
        }
        return rangeAttribute(
            kAXSelectedTextRangeAttribute,
            from: context.focusedElement
        ) == initialSelectedRange
    }

    private func focusedPathContainsProtectedContent(in app: NSRunningApplication) -> Bool {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: applicationElement
        ) else {
            return false
        }
        return isProtectedElementOrAncestor(focusedElement)
    }

    private func postCopyCommand(to processIdentifier: pid_t) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard
            let commandDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 55,
                keyDown: true
            ),
            let copyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 8,
                keyDown: true
            ),
            let copyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 8,
                keyDown: false
            ),
            let commandUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 55,
                keyDown: false
            )
        else {
            return false
        }

        let events = [commandDown, copyDown, copyUp, commandUp]
        for event in events {
            event.setIntegerValueField(
                .eventSourceUserData,
                value: ClipboardFallbackInputGuard.syntheticCopyEventTag
            )
        }
        commandDown.flags = .maskCommand
        copyDown.flags = .maskCommand
        copyUp.flags = .maskCommand
        commandUp.flags = []

        for event in events {
            event.postToPid(processIdentifier)
        }
        return true
    }

    private func validatedElement(
        _ element: AXUIElement?,
        processIdentifier: pid_t
    ) -> AXUIElement? {
        guard let element else { return nil }
        var elementProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &elementProcessIdentifier) == .success,
              elementProcessIdentifier == processIdentifier else {
            return nil
        }
        return element
    }

    private func element(
        at quartzPoint: CGPoint,
        in applicationElement: AXUIElement,
        processIdentifier: pid_t
    ) -> AXUIElement? {
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            applicationElement,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &hitElement
        ) == .success else {
            return nil
        }
        return validatedElement(hitElement, processIdentifier: processIdentifier)
    }

    private func isApplicationOrWindow(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else {
            return false
        }
        return role == (kAXApplicationRole as String)
            || role == (kAXWindowRole as String)
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func unsignedIntegerAttribute(_ attribute: String, from element: AXUIElement) -> UInt32? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func rangeAttribute(_ attribute: String, from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0,
              range.length > 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func boundsForSelection(in element: AXUIElement) -> NSRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return nil
        }
        return appKitRect(fromAXRect: rect)
    }

    private func rectAttribute(from element: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return appKitRect(fromAXRect: CGRect(origin: point, size: size))
    }

    private func rawAXRectAttribute(from element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              point.x.isFinite,
              point.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func appKitRect(fromAXRect rect: CGRect) -> NSRect {
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        let primaryTop = primaryScreen?.frame.maxY ?? rect.maxY
        return NSRect(
            x: rect.minX,
            y: primaryTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func isProtectedElementOrAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { return false }
            if isProtectedElement(candidate) {
                return true
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }
        return false
    }

    private func isProtectedElement(_ element: AXUIElement) -> Bool {
        SelectionProtectionClassifier.isProtected(
            role: stringAttribute(kAXRoleAttribute, from: element),
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            containsProtectedContent: booleanAttribute("AXContainsProtectedContent", from: element)
        )
    }

    private func booleanAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }
}
